/**
 * LobbyManager
 * -------------
 * Owns the set of rooms in the process. A room is a `RoundEngine` plus
 * connection bookkeeping (which WebSocket belongs to which playerId, who is
 * the host, what is the room code).
 *
 * Side-effect-light: `LobbyManager` returns `EngineAction`s and the caller
 * (index.ts) translates those into `ServerMessage`s and sends them out. This
 * keeps networking out of the lobby/round logic and makes the integration
 * test simpler to write.
 */
import { randomUUID } from "node:crypto";
import { RoundEngine, type Mode } from "./RoundEngine.js";
import type { ServerMessage } from "./protocol.js";

export interface ConnectionLike {
  /** Stable id of this socket. */
  sessionId: string;
  /** Send a server message; returns whether the send was attempted. */
  send(msg: ServerMessage): boolean;
}

interface PlayerSeat {
  playerId: string;
  displayName: string;
  capabilities: Array<"ble" | "bump" | "uwb" | "audio" | "qr">;
  connection: ConnectionLike | null;
}

interface Room {
  roomCode: string;
  hostPlayerId: string;
  engine: RoundEngine;
  seats: Map<string, PlayerSeat>; // by playerId
  bySession: Map<string, string>; // sessionId -> playerId
}

const ROOM_CODE_ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";

export class LobbyManager {
  private rooms = new Map<string, Room>(); // by roomCode

  createRoom(host: { sessionId: string; displayName: string; capabilities: PlayerSeat["capabilities"] }, mode: Mode, roundSeconds: number): { roomCode: string; playerId: string } {
    const roomCode = this.uniqueRoomCode();
    const playerId = randomUUID();
    const engine = new RoundEngine({ mode, roundSeconds });
    engine.addPlayer({ playerId, displayName: host.displayName });
    const room: Room = {
      roomCode,
      hostPlayerId: playerId,
      engine,
      seats: new Map(),
      bySession: new Map(),
    };
    room.seats.set(playerId, {
      playerId,
      displayName: host.displayName,
      capabilities: host.capabilities,
      connection: { sessionId: host.sessionId, send: () => false }, // patched by caller
    });
    room.bySession.set(host.sessionId, playerId);
    this.rooms.set(roomCode, room);
    return { roomCode, playerId };
  }

  joinRoom(roomCode: string, joiner: { sessionId: string; displayName: string; capabilities: PlayerSeat["capabilities"] }): { ok: true; playerId: string; room: Room } | { ok: false; code: "bad_room_code" | "room_full" } {
    const room = this.rooms.get(roomCode);
    if (!room) return { ok: false, code: "bad_room_code" };
    if (room.seats.size >= 16) return { ok: false, code: "room_full" };
    const playerId = randomUUID();
    room.seats.set(playerId, {
      playerId,
      displayName: joiner.displayName,
      capabilities: joiner.capabilities,
      connection: { sessionId: joiner.sessionId, send: () => false },
    });
    room.bySession.set(joiner.sessionId, playerId);
    room.engine.addPlayer({ playerId, displayName: joiner.displayName });
    return { ok: true, playerId, room };
  }

  attachConnection(roomCode: string, sessionId: string, connection: ConnectionLike): void {
    const room = this.rooms.get(roomCode);
    if (!room) return;
    const playerId = room.bySession.get(sessionId);
    if (!playerId) return;
    const seat = room.seats.get(playerId);
    if (seat) seat.connection = connection;
  }

  leaveRoom(sessionId: string): { roomCode: string; wasHost: boolean } | null {
    for (const [roomCode, room] of this.rooms) {
      const playerId = room.bySession.get(sessionId);
      if (!playerId) continue;
      const wasHost = room.hostPlayerId === playerId;
      room.bySession.delete(sessionId);
      room.seats.delete(playerId);
      room.engine.removePlayer(playerId);
      if (room.seats.size === 0) {
        this.rooms.delete(roomCode);
      } else if (wasHost) {
        room.hostPlayerId = [...room.seats.keys()][0]!;
      }
      return { roomCode, wasHost };
    }
    return null;
  }

  roomFor(sessionId: string): { room: Room; playerId: string } | null {
    for (const room of this.rooms.values()) {
      const playerId = room.bySession.get(sessionId);
      if (playerId) return { room, playerId };
    }
    return null;
  }

  roomByCode(roomCode: string): Room | undefined {
    return this.rooms.get(roomCode);
  }

  allRooms(): Room[] {
    return [...this.rooms.values()];
  }

  private uniqueRoomCode(): string {
    for (let attempt = 0; attempt < 50; attempt++) {
      const code = randomCode();
      if (!this.rooms.has(code)) return code;
    }
    throw new Error("Unable to allocate a room code");
  }
}

function randomCode(): string {
  const buf = new Uint8Array(4);
  // Math.random is fine for room codes; collisions are checked by caller.
  for (let i = 0; i < 4; i++) buf[i] = Math.floor(Math.random() * ROOM_CODE_ALPHABET.length);
  return Array.from(buf, (b) => ROOM_CODE_ALPHABET[b % ROOM_CODE_ALPHABET.length]).join("");
}

export interface RoomSnapshot {
  roomCode: string;
  hostPlayerId: string;
  phase: RoundEngine["phase"];
  players: Array<{
    playerId: string;
    displayName: string;
    ready: boolean;
    alive: boolean;
    score: number;
    connected: boolean;
    capabilities: PlayerSeat["capabilities"];
  }>;
  currentRoundId: number;
  mode: Mode;
  settings: { roundSeconds: number; maxPlayers: number };
}

export function snapshot(room: Room): RoomSnapshot {
  const players = [...room.seats.values()].map((seat) => {
    const p = room.engine.allPlayers().find((x) => x.playerId === seat.playerId)!;
    return {
      playerId: seat.playerId,
      displayName: seat.displayName,
      ready: p.ready,
      alive: p.alive,
      score: p.score,
      connected: seat.connection !== null,
      capabilities: seat.capabilities,
    };
  });
  return {
    roomCode: room.roomCode,
    hostPlayerId: room.hostPlayerId,
    phase: room.engine.phase,
    players,
    currentRoundId: room.engine.currentRoundId,
    mode: room.engine.mode,
    settings: { roundSeconds: room.engine.roundSeconds, maxPlayers: 16 },
  };
}
