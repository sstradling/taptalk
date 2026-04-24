/**
 * RoundEngine
 * -----------
 * Per-room round state machine. Owns:
 *   - phase transitions (lobby/registering/finding/resolving/between/ended)
 *   - assignments for the current round
 *   - evidence buffer + match attempts
 *   - per-player scores and "alive" status across rounds
 *
 * Side-effect-free at construction: callers (LobbyManager / index.ts) drive
 * it with `tick(now)` and `submitEvidence(...)` and read back actions to
 * dispatch over the network. This keeps the engine fully unit-testable.
 */
import {
  resolveTouches,
  type DeviceEvidence,
  type MatcherTunables,
  MATCHER_DEFAULTS,
  type TouchClaim,
} from "./EvidenceMatcher.js";
import { assignRound, type Assignment, type RngLike, defaultRng } from "./CueDispatcher.js";

export type Phase =
  | "lobby"
  | "registering"
  | "finding"
  | "resolving"
  | "between_rounds"
  | "ended";

export type Mode = "musical_chairs" | "poison_apple" | "scavenger_hunt";

export interface PlayerInfo {
  playerId: string;
  displayName: string;
  alive: boolean;
  score: number;
  ready: boolean;
}

export interface RoundEngineConfig {
  mode: Mode;
  roundSeconds: number;
  rng?: RngLike;
  matcher?: MatcherTunables;
}

/** Discriminated union of side-effect requests the engine emits. */
export type EngineAction =
  | { kind: "broadcast_round_started"; roundId: number; registerDeadlineMs: number }
  | { kind: "private_pair_assigned"; assignment: Assignment; findDeadlineMs: number }
  | {
      kind: "broadcast_pair_confirmed";
      a: string;
      b: string;
      roundId: number;
      elapsedMs: number;
      aDisplayName: string;
      bDisplayName: string;
    }
  | { kind: "private_pair_rejected"; playerId: string; roundId: number; reason: "wrong_partner" | "stale_evidence" | "phase_mismatch" }
  | {
      kind: "broadcast_round_resolved";
      roundId: number;
      results: Array<{
        playerId: string;
        outcome: "found" | "eliminated" | "poison_won" | "poison_lost";
        rankInRound: number;
        scoreDelta: number;
        totalScore: number;
      }>;
      nextPhase: "between_rounds" | "ended";
    };

export class RoundEngine {
  readonly mode: Mode;
  readonly roundSeconds: number;
  private rng: RngLike;
  private matcher: MatcherTunables;

  private players = new Map<string, PlayerInfo>();
  phase: Phase = "lobby";
  /** Visible for snapshots / tests. */
  currentRoundId = 0;
  private assignments = new Map<string, Assignment>();
  private foundOrder: string[] = []; // playerIds in confirm order (for ranking)
  private confirmedPairs = new Set<string>(); // "a|b" lex-sorted
  private roundStartedAtMs = 0;
  private registerDeadlineMs = 0;
  private findDeadlineMs = 0;
  private evidenceBuffer: DeviceEvidence[] = [];
  /** Self-tokens advertised by each player this round. */
  private selfTokens = new Map<string, string>();

  constructor(cfg: RoundEngineConfig) {
    this.mode = cfg.mode;
    this.roundSeconds = cfg.roundSeconds;
    this.rng = cfg.rng ?? defaultRng;
    this.matcher = cfg.matcher ?? MATCHER_DEFAULTS;
  }

  // ---- player roster ------------------------------------------------------

  addPlayer(p: Omit<PlayerInfo, "alive" | "score" | "ready">): void {
    if (this.players.has(p.playerId)) return;
    this.players.set(p.playerId, { ...p, alive: true, score: 0, ready: false });
  }

  removePlayer(playerId: string): void {
    this.players.delete(playerId);
    this.assignments.delete(playerId);
    this.selfTokens.delete(playerId);
  }

  setReady(playerId: string, ready: boolean): void {
    const p = this.players.get(playerId);
    if (p) p.ready = ready;
  }

  alivePlayers(): PlayerInfo[] {
    return [...this.players.values()].filter((p) => p.alive);
  }

  allPlayers(): PlayerInfo[] {
    return [...this.players.values()];
  }

  // ---- round lifecycle ---------------------------------------------------

  /**
   * Start a new round. Returns the actions the caller must dispatch (broadcast
   * `round_started`; send a private `pair_assigned` to each assigned player).
   */
  startRound(now: number): EngineAction[] {
    if (this.phase !== "lobby" && this.phase !== "between_rounds") {
      return [];
    }
    this.currentRoundId += 1;
    this.assignments.clear();
    this.foundOrder = [];
    this.confirmedPairs.clear();
    this.evidenceBuffer = [];
    this.selfTokens.clear();
    this.roundStartedAtMs = now;
    this.registerDeadlineMs = now + 10_000; // 10s register window
    this.findDeadlineMs = now + this.roundSeconds * 1000;

    const aliveIds = this.alivePlayers().map((p) => p.playerId);
    const fresh = assignRound(aliveIds, this.mode, this.rng);
    for (const a of fresh) this.assignments.set(a.playerId, a);

    this.phase = "registering";

    const actions: EngineAction[] = [];
    actions.push({
      kind: "broadcast_round_started",
      roundId: this.currentRoundId,
      registerDeadlineMs: this.registerDeadlineMs,
    });
    for (const a of fresh) {
      actions.push({ kind: "private_pair_assigned", assignment: a, findDeadlineMs: this.findDeadlineMs });
    }
    return actions;
  }

  /**
   * Periodic tick. Drives phase transitions when deadlines pass and resolves
   * the round when all pairs are found.
   */
  tick(now: number): EngineAction[] {
    if (this.phase === "registering" && now >= this.registerDeadlineMs) {
      this.phase = "finding";
    }
    if (this.phase === "finding") {
      const allFound = this.allAssignedPairsFound();
      if (allFound || now >= this.findDeadlineMs) {
        return this.resolveRound();
      }
    }
    return [];
  }

  // ---- evidence ----------------------------------------------------------

  setSelfToken(playerId: string, token: string): void {
    this.selfTokens.set(playerId, token);
  }

  /**
   * Accept evidence from one device. The engine may immediately attempt a
   * match if the new evidence brings a pair past threshold.
   *
   * Returns actions to dispatch (typically zero or two `pair_confirmed`s).
   */
  submitEvidence(
    playerId: string,
    roundId: number,
    evidencePhase: "register" | "confirm",
    selfToken: string,
    channels: DeviceEvidence["channels"],
    now: number
  ): EngineAction[] {
    if (roundId !== this.currentRoundId || !this.acceptsEvidencePhase(evidencePhase)) {
      return [
        {
          kind: "private_pair_rejected",
          playerId,
          roundId: this.currentRoundId,
          reason: "phase_mismatch",
        },
      ];
    }
    this.selfTokens.set(playerId, selfToken);
    this.evidenceBuffer.push({ playerId, selfToken, receivedAtMs: now, channels });
    this.pruneOldEvidence(now);
    return this.tryMatch(now);
  }

  private acceptsEvidencePhase(evidencePhase: "register" | "confirm"): boolean {
    if (this.phase === "registering") {
      // The prototype deals cues at round start, so we allow confirm evidence
      // during the short registering window. A later registration UX can make
      // this stricter once the phases are visually distinct in the client.
      return evidencePhase === "register" || evidencePhase === "confirm";
    }
    return this.phase === "finding" && evidencePhase === "confirm";
  }

  // ---- internal ----------------------------------------------------------

  private pruneOldEvidence(now: number): void {
    const cutoff = now - this.matcher.windowMs;
    this.evidenceBuffer = this.evidenceBuffer.filter((e) => e.receivedAtMs >= cutoff);
  }

  private tryMatch(now: number): EngineAction[] {
    // Include synthetic empty-evidence entries for every known selfToken so
    // that a unilateral observation (e.g. "A's UWB sees B at 5cm" with B
    // having sent nothing) can still produce a match. This is important for
    // UWB / audio channels which are inherently one-sided observations.
    const present = new Set(this.evidenceBuffer.map((e) => e.playerId));
    const synthetic: DeviceEvidence[] = [];
    for (const [playerId, selfToken] of this.selfTokens) {
      if (!present.has(playerId)) {
        synthetic.push({ playerId, selfToken, receivedAtMs: now, channels: [] });
      }
    }
    const touches = resolveTouches([...this.evidenceBuffer, ...synthetic], this.matcher);
    if (touches.length === 0) return [];

    const out: EngineAction[] = [];
    for (const t of touches) {
      const expectedA = this.assignments.get(t.a)?.partnerPlayerId;
      const expectedB = this.assignments.get(t.b)?.partnerPlayerId;
      const isAssignedPair = expectedA === t.b && expectedB === t.a;

      if (isAssignedPair) {
        this.confirmTouch(t, now, out);
      } else {
        out.push({
          kind: "private_pair_rejected",
          playerId: t.a,
          roundId: this.currentRoundId,
          reason: "wrong_partner",
        });
        out.push({
          kind: "private_pair_rejected",
          playerId: t.b,
          roundId: this.currentRoundId,
          reason: "wrong_partner",
        });
      }
      this.dropEvidenceFor(t.a);
      this.dropEvidenceFor(t.b);
    }

    // Cascade: if the confirmation completed the round, resolve immediately.
    if (this.allAssignedPairsFound()) {
      out.push(...this.resolveRound());
    }
    return out;
  }

  private confirmTouch(t: TouchClaim, now: number, out: EngineAction[]): void {
    const key = pairKey(t.a, t.b);
    if (this.confirmedPairs.has(key)) return;
    this.confirmedPairs.add(key);
    if (!this.foundOrder.includes(t.a)) this.foundOrder.push(t.a);
    if (!this.foundOrder.includes(t.b)) this.foundOrder.push(t.b);
    const pa = this.players.get(t.a);
    const pb = this.players.get(t.b);
    out.push({
      kind: "broadcast_pair_confirmed",
      a: t.a,
      b: t.b,
      roundId: this.currentRoundId,
      elapsedMs: now - this.roundStartedAtMs,
      aDisplayName: pa?.displayName ?? t.a,
      bDisplayName: pb?.displayName ?? t.b,
    });
  }

  private dropEvidenceFor(playerId: string): void {
    this.evidenceBuffer = this.evidenceBuffer.filter((e) => e.playerId !== playerId);
  }

  private allAssignedPairsFound(): boolean {
    const realPairs = [...this.assignments.values()].filter(
      (a) => a.role === "pair" && a.partnerPlayerId !== null
    );
    if (realPairs.length === 0) return false;
    const seen = new Set<string>();
    for (const a of realPairs) {
      if (a.partnerPlayerId == null) continue;
      const key = pairKey(a.playerId, a.partnerPlayerId);
      if (this.confirmedPairs.has(key)) seen.add(key);
    }
    // Number of unique real pairs:
    const totalUnique = new Set(realPairs.map((a) => pairKey(a.playerId, a.partnerPlayerId!))).size;
    return seen.size === totalUnique;
  }

  private resolveRound(): EngineAction[] {
    if (this.phase === "resolving" || this.phase === "ended") return [];
    this.phase = "resolving";

    const results = this.scoreRound();
    for (const r of results) {
      const p = this.players.get(r.playerId);
      if (!p) continue;
      p.score = r.totalScore;
      if (r.outcome === "eliminated") p.alive = false;
    }
    const aliveCount = this.alivePlayers().length;
    const nextPhase: "between_rounds" | "ended" = aliveCount <= 1 ? "ended" : "between_rounds";
    this.phase = nextPhase;

    return [
      {
        kind: "broadcast_round_resolved",
        roundId: this.currentRoundId,
        results,
        nextPhase,
      },
    ];
  }

  private scoreRound(): Array<{
    playerId: string;
    outcome: "found" | "eliminated" | "poison_won" | "poison_lost";
    rankInRound: number;
    scoreDelta: number;
    totalScore: number;
  }> {
    const rankedFound = this.foundOrder.slice();
    const findersSet = new Set(rankedFound);
    const out: Array<{
      playerId: string;
      outcome: "found" | "eliminated" | "poison_won" | "poison_lost";
      rankInRound: number;
      scoreDelta: number;
      totalScore: number;
    }> = [];

    for (const p of this.allPlayers()) {
      if (!p.alive) continue;
      const assigned = this.assignments.get(p.playerId);
      const rank = rankedFound.indexOf(p.playerId);
      if (assigned?.role === "poison_apple") {
        // Win condition: at least one real pair failed to find each other.
        const someFailed = [...this.assignments.values()].some(
          (a) =>
            a.role === "pair" &&
            a.partnerPlayerId !== null &&
            !this.confirmedPairs.has(pairKey(a.playerId, a.partnerPlayerId))
        );
        const delta = someFailed ? 200 : 0;
        out.push({
          playerId: p.playerId,
          outcome: someFailed ? "poison_won" : "poison_lost",
          rankInRound: 1,
          scoreDelta: delta,
          totalScore: p.score + delta,
        });
        continue;
      }
      if (findersSet.has(p.playerId)) {
        // Earlier rank => more points; cap at 100 for first.
        const delta = Math.max(20, 100 - rank * 10);
        out.push({
          playerId: p.playerId,
          outcome: "found",
          rankInRound: rank + 1,
          scoreDelta: delta,
          totalScore: p.score + delta,
        });
      } else {
        // Mode-specific elimination:
        // - musical_chairs: yes (didn't find pair => out next round)
        // - scavenger_hunt: no eliminations, just no points this round
        // - poison_apple: only the pair the apple "stole" gets eliminated
        //   (simplification for prototype: anyone who didn't confirm is out)
        const eliminate = this.mode !== "scavenger_hunt";
        out.push({
          playerId: p.playerId,
          outcome: eliminate ? "eliminated" : "found",
          rankInRound: rankedFound.length + 1,
          scoreDelta: 0,
          totalScore: p.score,
        });
      }
    }
    return out;
  }
}

function pairKey(a: string, b: string): string {
  return a < b ? `${a}|${b}` : `${b}|${a}`;
}
