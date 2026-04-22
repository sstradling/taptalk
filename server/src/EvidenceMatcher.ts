/**
 * EvidenceMatcher
 * ----------------
 * Pure-function module that turns a window of `pair_evidence` reports from
 * multiple devices into a list of "touched" device pairs.
 *
 * The algorithm is documented as normative in `spec/PROTOCOL.md` §7. This
 * module is the single implementation of that algorithm; `RoundEngine` calls
 * it and is the only place game-state transitions happen.
 *
 * Why a separate module: matching logic is dense and easy to get wrong; we
 * want it covered by table-driven tests independent of network or state.
 */
import type { EvidenceChannel } from "./protocol.js";

export interface DeviceEvidence {
  /** Stable per-round id of the reporting device. */
  playerId: string;
  /** The device's own round-scoped advertised token. */
  selfToken: string;
  /** Server-receive timestamp in ms (used for window bucketing). */
  receivedAtMs: number;
  channels: EvidenceChannel[];
}

export interface TouchClaim {
  a: string; // playerId
  b: string; // playerId
  score: number;
  /** Channels that contributed (for telemetry / debug). */
  contributingKinds: string[];
}

/** Default tunables; exported so tests can override. */
export const MATCHER_DEFAULTS = {
  /** Coalescing window for evidence (ms). */
  windowMs: 750,
  /** Minimum score to consider a touch real. */
  scoreThreshold: 4.0,
  /** Bump-pair maximum delta in ms. */
  bumpDeltaMs: 200,
  /** BLE RSSI must be stronger (less negative) than this dBm. */
  bleRssiDbm: -55,
  /** UWB distance must be tighter than this (m). */
  uwbDistanceM: 0.20,
  /** Audio chirp SNR must exceed this (dB). */
  audioSnrDb: 10.0,
  /** Channel weights (must match spec §7). */
  weight: {
    bumpPair: 3.0,
    bleSeen: 2.0,
    uwbClose: 4.0,
    audioHeard: 2.0,
  },
} as const;

export type MatcherTunables = typeof MATCHER_DEFAULTS;

/**
 * Compute the score of a candidate device pair (A, B) given their evidence.
 *
 * The score formula is symmetric in (A, B). We split the contribution per
 * channel so individual rules stay easy to reason about and to test.
 */
export function scorePair(
  a: DeviceEvidence,
  b: DeviceEvidence,
  cfg: MatcherTunables = MATCHER_DEFAULTS
): { score: number; contributing: string[] } {
  const contributing: string[] = [];
  let score = 0;

  if (bothBumpedTogether(a, b, cfg.bumpDeltaMs)) {
    score += cfg.weight.bumpPair;
    contributing.push("bump");
  }
  if (eitherSawOtherOnBle(a, b, cfg.bleRssiDbm)) {
    score += cfg.weight.bleSeen;
    contributing.push("ble");
  }
  if (eitherUwbClose(a, b, cfg.uwbDistanceM)) {
    score += cfg.weight.uwbClose;
    contributing.push("uwb");
  }
  if (eitherHeardOther(a, b, cfg.audioSnrDb)) {
    score += cfg.weight.audioHeard;
    contributing.push("audio");
  }

  return { score, contributing };
}

/**
 * Given the full set of evidence within a window, greedily resolve the
 * highest-scoring touch claims. Each player can appear in at most one touch
 * per call (a player who taps two phones at once produces an ambiguous claim;
 * we pick the strongest and discard the rest).
 */
export function resolveTouches(
  evidence: DeviceEvidence[],
  cfg: MatcherTunables = MATCHER_DEFAULTS
): TouchClaim[] {
  const candidates: TouchClaim[] = [];
  for (let i = 0; i < evidence.length; i++) {
    const ai = evidence[i];
    if (!ai) continue;
    for (let j = i + 1; j < evidence.length; j++) {
      const bj = evidence[j];
      if (!bj) continue;
      const { score, contributing } = scorePair(ai, bj, cfg);
      if (score >= cfg.scoreThreshold) {
        candidates.push({ a: ai.playerId, b: bj.playerId, score, contributingKinds: contributing });
      }
    }
  }
  candidates.sort((x, y) => y.score - x.score);
  const claimed = new Set<string>();
  const out: TouchClaim[] = [];
  for (const c of candidates) {
    if (claimed.has(c.a) || claimed.has(c.b)) continue;
    out.push(c);
    claimed.add(c.a);
    claimed.add(c.b);
  }
  return out;
}

// ---- helpers ---------------------------------------------------------------

function bothBumpedTogether(a: DeviceEvidence, b: DeviceEvidence, deltaMs: number): boolean {
  const ab = a.channels.find((c) => c.kind === "bump");
  const bb = b.channels.find((c) => c.kind === "bump");
  if (!ab || !bb) return false;
  const at = ab.tHitMs ?? ab.observedAtMs;
  const bt = bb.tHitMs ?? bb.observedAtMs;
  return Math.abs(at - bt) <= deltaMs;
}

function eitherSawOtherOnBle(a: DeviceEvidence, b: DeviceEvidence, rssiThreshold: number): boolean {
  const aSawB = a.channels.some(
    (c) => c.kind === "ble" && c.peerToken === b.selfToken && (c.rssiDbm ?? -127) > rssiThreshold
  );
  const bSawA = b.channels.some(
    (c) => c.kind === "ble" && c.peerToken === a.selfToken && (c.rssiDbm ?? -127) > rssiThreshold
  );
  return aSawB || bSawA;
}

function eitherUwbClose(a: DeviceEvidence, b: DeviceEvidence, distanceM: number): boolean {
  const aSawB = a.channels.some(
    (c) =>
      c.kind === "uwb" && c.peerToken === b.selfToken && (c.distanceM ?? Infinity) < distanceM
  );
  const bSawA = b.channels.some(
    (c) =>
      c.kind === "uwb" && c.peerToken === a.selfToken && (c.distanceM ?? Infinity) < distanceM
  );
  return aSawB || bSawA;
}

function eitherHeardOther(a: DeviceEvidence, b: DeviceEvidence, snrDb: number): boolean {
  const aHeardB = a.channels.some(
    (c) => c.kind === "audio" && c.peerToken === b.selfToken && (c.snrDb ?? -Infinity) > snrDb
  );
  const bHeardA = b.channels.some(
    (c) => c.kind === "audio" && c.peerToken === a.selfToken && (c.snrDb ?? -Infinity) > snrDb
  );
  return aHeardB || bHeardA;
}
