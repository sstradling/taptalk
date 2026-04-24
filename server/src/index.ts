/**
 * TapPair WebSocket server entrypoint.
 *
 * Responsibilities:
 *   - Accept WebSocket connections.
 *   - Validate every inbound message against `protocol.ts` (which mirrors
 *     `spec/PROTOCOL.md`).
 *   - Translate inbound messages into `LobbyManager` / `RoundEngine` calls.
 *   - Translate `EngineAction`s back into `ServerMessage`s and send them.
 *
 * This module is intentionally thin: all game logic lives in `RoundEngine`
 * and `EvidenceMatcher`.
 */
import { WebSocketServer, type WebSocket } from "ws";
import { randomUUID } from "node:crypto";
import {
  ClientMessageSchema,
  PROTOCOL_VERSION,
  type ServerMessage,
  type ClientMessage,
} from "./protocol.js";
import { LobbyManager, snapshot, type ConnectionLike } from "./LobbyManager.js";
import type { EngineAction } from "./RoundEngine.js";
import { log } from "./log.js";

const PORT = Number(process.env.PORT ?? 8080);
const TICK_MS = 250;

interface SessionState {
  sessionId: string;
  ws: WebSocket;
  helloed: boolean;
  displayName: string;
  capabilities: Array<"ble" | "bump" | "uwb" | "audio" | "qr">;
}

export function createServer(port: number = PORT): { wss: WebSocketServer; lobby: LobbyManager; stop: () => Promise<void> } {
  const wss = new WebSocketServer({ port });
  const lobby = new LobbyManager();
  const sessions = new Map<string, SessionState>();

  function send(ws: WebSocket, msg: ServerMessage): boolean {
    if (ws.readyState !== ws.OPEN) return false;
    ws.send(JSON.stringify(msg));
    return true;
  }

  function broadcastRoomState(roomCode: string): void {
    const room = lobby.roomByCode(roomCode);
    if (!room) return;
    const snap = snapshot(room);
    const msg: ServerMessage = {
      type: "room_state",
      v: 1,
      roomCode: snap.roomCode,
      mode: snap.mode,
      phase: snap.phase,
      hostPlayerId: snap.hostPlayerId,
      players: snap.players,
      currentRoundId: snap.currentRoundId,
      settings: snap.settings,
    };
    for (const seat of room.seats.values()) {
      const session = sessions.get(seat.connection?.sessionId ?? "");
      if (session) send(session.ws, msg);
    }
    log.info("room_state broadcast", {
      roomCode,
      phase: snap.phase,
      players: snap.players.length,
      roundId: snap.currentRoundId,
    });
  }

  function dispatchActions(roomCode: string, actions: EngineAction[]): void {
    const room = lobby.roomByCode(roomCode);
    if (!room) return;
    const sessionFor = (playerId: string): SessionState | undefined => {
      const seat = room.seats.get(playerId);
      const sid = seat?.connection?.sessionId;
      return sid ? sessions.get(sid) : undefined;
    };

    for (const action of actions) {
      switch (action.kind) {
        case "broadcast_round_started": {
          const msg: ServerMessage = {
            type: "round_started",
            v: 1,
            roundId: action.roundId,
            phase: "registering",
            registerDeadlineMs: action.registerDeadlineMs,
          };
          for (const seat of room.seats.values()) {
            const s = sessions.get(seat.connection?.sessionId ?? "");
            if (s) send(s.ws, msg);
          }
          break;
        }
        case "private_pair_assigned": {
          const s = sessionFor(action.assignment.playerId);
          if (!s) break;
          const a = action.assignment;
          const msg: ServerMessage = {
            type: "pair_assigned",
            v: 1,
            roundId: room.engine.currentRoundId,
            role: a.role,
            cue: {
              cueId: a.cueId,
              kind: "text",
              modality: ["text", "audio"],
              payload: { text: a.cueText },
              complementHint: a.cueHint,
            },
            findDeadlineMs: action.findDeadlineMs,
          };
          send(s.ws, msg);
          break;
        }
        case "broadcast_pair_confirmed": {
          const sa = sessionFor(action.a);
          const sb = sessionFor(action.b);
          if (sa) {
            send(sa.ws, {
              type: "pair_confirmed",
              v: 1,
              roundId: action.roundId,
              partnerPlayerId: action.b,
              partnerDisplayName: action.bDisplayName,
              elapsedMs: action.elapsedMs,
            });
          }
          if (sb) {
            send(sb.ws, {
              type: "pair_confirmed",
              v: 1,
              roundId: action.roundId,
              partnerPlayerId: action.a,
              partnerDisplayName: action.aDisplayName,
              elapsedMs: action.elapsedMs,
            });
          }
          break;
        }
        case "private_pair_rejected": {
          const s = sessionFor(action.playerId);
          if (s) {
            send(s.ws, {
              type: "pair_rejected",
              v: 1,
              roundId: action.roundId,
              reason: action.reason,
            });
          }
          break;
        }
        case "broadcast_round_resolved": {
          const msg: ServerMessage = {
            type: "round_resolved",
            v: 1,
            roundId: action.roundId,
            results: action.results,
            nextPhase: action.nextPhase,
          };
          for (const seat of room.seats.values()) {
            const s = sessions.get(seat.connection?.sessionId ?? "");
            if (s) send(s.ws, msg);
          }
          break;
        }
      }
    }
    broadcastRoomState(roomCode);
  }

  function handle(session: SessionState, raw: string): void {
    let parsed: ClientMessage;
    try {
      const json = JSON.parse(raw);
      parsed = ClientMessageSchema.parse(json);
    } catch (err) {
      log.warn("invalid client message", { sessionId: session.sessionId, error: (err as Error).message });
      send(session.ws, {
        type: "error",
        v: 1,
        code: "internal",
        message: `Invalid message: ${(err as Error).message}`,
      });
      return;
    }

    log.info("client message", {
      sessionId: session.sessionId,
      type: parsed.type,
      displayName: session.displayName || undefined,
    });

    if (!session.helloed && parsed.type !== "hello") {
      log.warn("message before hello", { sessionId: session.sessionId, type: parsed.type });
      send(session.ws, { type: "error", v: 1, code: "internal", message: "must hello first" });
      return;
    }

    switch (parsed.type) {
      case "hello": {
        if (parsed.v !== PROTOCOL_VERSION) {
          send(session.ws, { type: "error", v: 1, code: "protocol_version", message: "protocol mismatch" });
          session.ws.close();
          return;
        }
        session.helloed = true;
        session.displayName = parsed.displayName;
        session.capabilities = parsed.capabilities;
        log.info("client hello", {
          sessionId: session.sessionId,
          displayName: parsed.displayName,
          platform: parsed.platform,
          capabilities: parsed.capabilities,
        });
        send(session.ws, {
          type: "hello_ack",
          v: 1,
          sessionId: session.sessionId,
          serverTimeMs: Date.now(),
        });
        return;
      }
      case "ping": {
        send(session.ws, { type: "pong", v: 1 });
        return;
      }
      case "create_room": {
        const { roomCode } = lobby.createRoom(
          { sessionId: session.sessionId, displayName: session.displayName, capabilities: session.capabilities },
          parsed.mode,
          parsed.settings.roundSeconds
        );
        const conn: ConnectionLike = { sessionId: session.sessionId, send: (m) => send(session.ws, m) };
        lobby.attachConnection(roomCode, session.sessionId, conn);
        log.info("room created", { sessionId: session.sessionId, roomCode, mode: parsed.mode });
        broadcastRoomState(roomCode);
        return;
      }
      case "join_room": {
        const result = lobby.joinRoom(parsed.roomCode, {
          sessionId: session.sessionId,
          displayName: session.displayName,
          capabilities: session.capabilities,
        });
        if (!result.ok) {
          log.warn("join room failed", {
            sessionId: session.sessionId,
            roomCode: parsed.roomCode,
            code: result.code,
          });
          send(session.ws, { type: "error", v: 1, code: result.code, message: result.code });
          return;
        }
        const conn: ConnectionLike = { sessionId: session.sessionId, send: (m) => send(session.ws, m) };
        lobby.attachConnection(parsed.roomCode, session.sessionId, conn);
        log.info("room joined", {
          sessionId: session.sessionId,
          roomCode: parsed.roomCode,
          playerId: result.playerId,
        });
        broadcastRoomState(parsed.roomCode);
        return;
      }
      case "leave_room": {
        const left = lobby.leaveRoom(session.sessionId);
        if (left) broadcastRoomState(left.roomCode);
        return;
      }
      case "ready": {
        const where = lobby.roomFor(session.sessionId);
        if (!where) return;
        where.room.engine.setReady(where.playerId, parsed.ready);
        broadcastRoomState(where.room.roomCode);
        return;
      }
      case "start_round": {
        const where = lobby.roomFor(session.sessionId);
        if (!where) return;
        if (where.room.hostPlayerId !== where.playerId) {
          log.warn("non-host start_round rejected", {
            sessionId: session.sessionId,
            roomCode: where.room.roomCode,
            playerId: where.playerId,
          });
          send(session.ws, { type: "error", v: 1, code: "not_host", message: "host only" });
          return;
        }
        const actions = where.room.engine.startRound(Date.now());
        log.info("round start requested", {
          sessionId: session.sessionId,
          roomCode: where.room.roomCode,
          playerId: where.playerId,
          actions: actions.length,
        });
        dispatchActions(where.room.roomCode, actions);
        return;
      }
      case "pair_evidence": {
        const where = lobby.roomFor(session.sessionId);
        if (!where) return;
        const actions = where.room.engine.submitEvidence(
          where.playerId,
          parsed.roundId,
          parsed.phase,
          parsed.selfToken,
          parsed.channels,
          Date.now()
        );
        dispatchActions(where.room.roomCode, actions);
        return;
      }
      case "cue_ack":
        return;
    }
  }

  wss.on("connection", (ws) => {
    const sessionId = randomUUID();
    const session: SessionState = {
      sessionId,
      ws,
      helloed: false,
      displayName: "",
      capabilities: [],
    };
    sessions.set(sessionId, session);
    log.info("websocket connected", { sessionId });

    ws.on("message", (data) => {
      try {
        handle(session, data.toString("utf-8"));
      } catch (err) {
        log.error("handler crash", { err: (err as Error).message });
      }
    });
    ws.on("close", () => {
      log.info("websocket closed", { sessionId });
      sessions.delete(sessionId);
      const left = lobby.leaveRoom(sessionId);
      if (left) broadcastRoomState(left.roomCode);
    });
  });

  const tick = setInterval(() => {
    const now = Date.now();
    for (const room of lobby.allRooms()) {
      const actions = room.engine.tick(now);
      if (actions.length > 0) dispatchActions(room.roomCode, actions);
    }
  }, TICK_MS);

  log.info("server listening", { port });

  return {
    wss,
    lobby,
    stop: async () => {
      clearInterval(tick);
      await new Promise<void>((resolve) => wss.close(() => resolve()));
    },
  };
}

const isMain = import.meta.url === `file://${process.argv[1]}`;
if (isMain) {
  createServer();
}
