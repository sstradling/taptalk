/**
 * RoundEngine state-machine tests.
 *
 * We deliberately drive the engine with a deterministic RNG so tests are
 * stable; the inputs and expected outputs map 1:1 to the behaviors that the
 * client UI (and any future Android client) depends on.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import { RoundEngine, type EngineAction } from "../src/RoundEngine.js";
import type { RngLike } from "../src/CueDispatcher.js";

class SeededRng implements RngLike {
  private state: number;
  constructor(seed: number) { this.state = seed; }
  next(): number {
    this.state = (this.state * 1664525 + 1013904223) >>> 0;
    return this.state / 0x1_0000_0000;
  }
}

function newEngine(mode: "musical_chairs" | "poison_apple" | "scavenger_hunt" = "musical_chairs"): RoundEngine {
  return new RoundEngine({ mode, roundSeconds: 30, rng: new SeededRng(1) });
}

function uwbHit(peerToken: string) {
  return [{ kind: "uwb" as const, peerToken, distanceM: 0.05, observedAtMs: 1000 }];
}

describe("RoundEngine", () => {
  it("startRound emits round_started and one pair_assigned per player", () => {
    const e = newEngine();
    e.addPlayer({ playerId: "p1", displayName: "Alice" });
    e.addPlayer({ playerId: "p2", displayName: "Bob" });

    const actions = e.startRound(1000);

    const started = actions.find((a) => a.kind === "broadcast_round_started");
    assert.ok(started, "should broadcast round_started");
    const assigns = actions.filter((a) => a.kind === "private_pair_assigned");
    assert.equal(assigns.length, 2);
    assert.equal(e.phase, "registering");
  });

  it("two players touching the assigned partner produces pair_confirmed and resolves the round", () => {
    const e = newEngine();
    e.addPlayer({ playerId: "p1", displayName: "Alice" });
    e.addPlayer({ playerId: "p2", displayName: "Bob" });
    e.startRound(1000);

    const a1 = e.submitEvidence("p1", "tA", uwbHit("tB"), 2000);
    e.setSelfToken("p2", "tB");
    e.setSelfToken("p1", "tA");

    const a2 = e.submitEvidence("p2", "tB", [], 2050);
    const all = [...a1, ...a2];

    const confirmed = all.find((a) => a.kind === "broadcast_pair_confirmed") as Extract<EngineAction, { kind: "broadcast_pair_confirmed" }> | undefined;
    assert.ok(confirmed, "should confirm the pair");
    assert.deepEqual([confirmed.a, confirmed.b].sort(), ["p1", "p2"]);

    const resolved = all.find((a) => a.kind === "broadcast_round_resolved") as Extract<EngineAction, { kind: "broadcast_round_resolved" }> | undefined;
    assert.ok(resolved, "round should resolve when last pair is found");
    // Both players found their pair; nobody is eliminated; both alive => game continues.
    assert.equal(resolved.nextPhase, "between_rounds");
    assert.equal(resolved.results.length, 2);
    assert.ok(resolved.results.every((r) => r.outcome === "found"));
  });

  it("touching the WRONG partner emits pair_rejected, not pair_confirmed", () => {
    const e = newEngine();
    e.addPlayer({ playerId: "p1", displayName: "A" });
    e.addPlayer({ playerId: "p2", displayName: "B" });
    e.addPlayer({ playerId: "p3", displayName: "C" });
    e.addPlayer({ playerId: "p4", displayName: "D" });
    const start = e.startRound(1000);

    // Find p1's assigned partner
    const a1 = start.find((a) => a.kind === "private_pair_assigned" && a.assignment.playerId === "p1") as Extract<EngineAction, { kind: "private_pair_assigned" }>;
    const partner = a1.assignment.partnerPlayerId!;
    // Pick a non-partner from the remaining players
    const wrong = ["p2", "p3", "p4"].find((x) => x !== partner)!;
    const wrongTok = `t_${wrong}`;
    e.setSelfToken(wrong, wrongTok);
    e.setSelfToken("p1", "t_p1");

    const actions = e.submitEvidence("p1", "t_p1", uwbHit(wrongTok), 2000);
    const rejected = actions.filter((a) => a.kind === "private_pair_rejected");
    assert.ok(rejected.length >= 1, "should produce at least one pair_rejected");
    const confirmed = actions.find((a) => a.kind === "broadcast_pair_confirmed");
    assert.equal(confirmed, undefined);
  });

  it("evidence outside a valid phase is rejected with phase_mismatch", () => {
    const e = newEngine();
    e.addPlayer({ playerId: "p1", displayName: "A" });
    e.addPlayer({ playerId: "p2", displayName: "B" });
    // No startRound: phase is still "lobby".
    const actions = e.submitEvidence("p1", "tA", uwbHit("tB"), 2000);
    assert.equal(actions.length, 1);
    assert.equal(actions[0]!.kind, "private_pair_rejected");
  });

  it("tick advances registering -> finding after the register deadline", () => {
    const e = newEngine();
    e.addPlayer({ playerId: "p1", displayName: "A" });
    e.addPlayer({ playerId: "p2", displayName: "B" });
    e.startRound(1000);
    assert.equal(e.phase, "registering");
    e.tick(20_000);
    assert.equal(e.phase, "finding");
  });
});
