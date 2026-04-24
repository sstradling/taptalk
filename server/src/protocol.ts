/**
 * Wire-protocol message schemas. The single source of truth is `spec/PROTOCOL.md`;
 * these zod schemas validate that contract at the network boundary so no other
 * module in the server has to defensively re-check shapes.
 *
 * If you change a message here, also update `spec/PROTOCOL.md` and the iOS
 * `Protocol/` Codable models. Mismatches between the three are the most common
 * source of cross-platform drift.
 */
import { z } from "zod";

export const PROTOCOL_VERSION = 1 as const;

const envelope = {
  v: z.literal(PROTOCOL_VERSION),
  ts: z.number().int().nonnegative().optional(),
};

export const PlatformSchema = z.enum(["ios", "android", "web"]);
export const CapabilitySchema = z.enum(["ble", "bump", "uwb", "audio", "qr"]);
export const ModeSchema = z.enum(["musical_chairs", "poison_apple", "scavenger_hunt"]);
export const PhaseSchema = z.enum([
  "lobby",
  "registering",
  "finding",
  "resolving",
  "between_rounds",
  "ended",
]);
export const RoleSchema = z.enum(["pair", "poison_apple"]);
export const OutcomeSchema = z.enum(["found", "eliminated", "poison_won", "poison_lost"]);
export const ChannelKindSchema = z.enum(["bump", "ble", "uwb", "audio"]);

// ---- Client -> Server ------------------------------------------------------

export const HelloSchema = z.object({
  ...envelope,
  type: z.literal("hello"),
  deviceId: z.string().uuid(),
  displayName: z.string().min(1).max(24),
  appVersion: z.string(),
  platform: PlatformSchema,
  osVersion: z.string(),
  capabilities: z.array(CapabilitySchema),
});

export const CreateRoomSchema = z.object({
  ...envelope,
  type: z.literal("create_room"),
  mode: ModeSchema,
  settings: z
    .object({
      roundSeconds: z.number().int().min(15).max(300).default(60),
      maxPlayers: z.number().int().min(2).max(32).default(16),
    })
    .default({ roundSeconds: 60, maxPlayers: 16 }),
});

export const JoinRoomSchema = z.object({
  ...envelope,
  type: z.literal("join_room"),
  roomCode: z.string().regex(/^[A-HJ-NP-Z2-9]{4}$/),
});

export const LeaveRoomSchema = z.object({
  ...envelope,
  type: z.literal("leave_room"),
});

export const ReadySchema = z.object({
  ...envelope,
  type: z.literal("ready"),
  ready: z.boolean(),
});

export const StartRoundSchema = z.object({
  ...envelope,
  type: z.literal("start_round"),
});

export const EvidenceChannelSchema = z.object({
  kind: ChannelKindSchema,
  observedAtMs: z.number().int(),
  peerToken: z.string().optional(),
  rssiDbm: z.number().optional(),
  distanceM: z.number().nonnegative().optional(),
  magnitudeG: z.number().nonnegative().optional(),
  snrDb: z.number().optional(),
  confidence: z.number().min(0).max(1).optional(),
  tHitMs: z.number().int().optional(),
});

export const PairEvidenceSchema = z.object({
  ...envelope,
  type: z.literal("pair_evidence"),
  roundId: z.number().int().nonnegative(),
  phase: z.enum(["register", "confirm"]),
  selfToken: z.string(),
  channels: z.array(EvidenceChannelSchema).min(1),
});

export const CueAckSchema = z.object({
  ...envelope,
  type: z.literal("cue_ack"),
  roundId: z.number().int().nonnegative(),
  cueId: z.string(),
});

export const PingSchema = z.object({ ...envelope, type: z.literal("ping") });

export const ClientMessageSchema = z.discriminatedUnion("type", [
  HelloSchema,
  CreateRoomSchema,
  JoinRoomSchema,
  LeaveRoomSchema,
  ReadySchema,
  StartRoundSchema,
  PairEvidenceSchema,
  CueAckSchema,
  PingSchema,
]);

export type ClientMessage = z.infer<typeof ClientMessageSchema>;
export type Hello = z.infer<typeof HelloSchema>;
export type PairEvidence = z.infer<typeof PairEvidenceSchema>;
export type EvidenceChannel = z.infer<typeof EvidenceChannelSchema>;

// ---- Server -> Client (no schemas needed; only constructors) ---------------

export type ServerMessage =
  | { type: "hello_ack"; v: 1; sessionId: string; serverTimeMs: number }
  | { type: "pong"; v: 1 }
  | {
      type: "room_state";
      v: 1;
      roomCode: string;
      mode: z.infer<typeof ModeSchema>;
      phase: z.infer<typeof PhaseSchema>;
      hostPlayerId: string;
      players: Array<{
        playerId: string;
        displayName: string;
        ready: boolean;
        alive: boolean;
        score: number;
        connected: boolean;
        capabilities: Array<z.infer<typeof CapabilitySchema>>;
      }>;
      currentRoundId: number;
      settings: { roundSeconds: number; maxPlayers: number };
    }
  | {
      type: "round_started";
      v: 1;
      roundId: number;
      phase: "registering";
      registerDeadlineMs: number;
    }
  | {
      type: "pair_assigned";
      v: 1;
      roundId: number;
      role: z.infer<typeof RoleSchema>;
      cue: {
        cueId: string;
        kind: "audio" | "image" | "text" | "task";
        modality: Array<"audio" | "haptic" | "text" | "image">;
        payload: Record<string, unknown>;
        complementHint: string;
      };
      findDeadlineMs: number;
    }
  | {
      type: "pair_confirmed";
      v: 1;
      roundId: number;
      partnerPlayerId: string;
      partnerDisplayName: string;
      elapsedMs: number;
    }
  | {
      type: "pair_rejected";
      v: 1;
      roundId: number;
      reason: "wrong_partner" | "stale_evidence" | "phase_mismatch";
    }
  | {
      type: "round_resolved";
      v: 1;
      roundId: number;
      results: Array<{
        playerId: string;
        outcome: z.infer<typeof OutcomeSchema>;
        rankInRound: number;
        scoreDelta: number;
        totalScore: number;
      }>;
      nextPhase: "between_rounds" | "ended";
    }
  | {
      type: "error";
      v: 1;
      code:
        | "room_full"
        | "bad_room_code"
        | "not_host"
        | "phase_mismatch"
        | "rate_limited"
        | "protocol_version"
        | "internal";
      message: string;
    };
