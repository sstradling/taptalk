/**
 * Table-driven tests for the evidence-matching algorithm.
 *
 * Each case asserts that the score crosses (or doesn't cross) the threshold
 * for a particular combination of channels. These are the boundary conditions
 * called out in spec/PROTOCOL.md §7.
 */
import { describe, it } from "node:test";
import assert from "node:assert/strict";
import {
  scorePair,
  resolveTouches,
  MATCHER_DEFAULTS,
  type DeviceEvidence,
} from "../src/EvidenceMatcher.js";

const tA = "tokA";
const tB = "tokB";

function devA(channels: DeviceEvidence["channels"]): DeviceEvidence {
  return { playerId: "A", selfToken: tA, receivedAtMs: 1000, channels };
}
function devB(channels: DeviceEvidence["channels"]): DeviceEvidence {
  return { playerId: "B", selfToken: tB, receivedAtMs: 1000, channels };
}

describe("scorePair", () => {
  it("UWB alone (within distance) crosses the threshold by itself", () => {
    const a = devA([{ kind: "uwb", peerToken: tB, distanceM: 0.05, observedAtMs: 1000 }]);
    const b = devB([]);
    const { score } = scorePair(a, b);
    assert.ok(score >= MATCHER_DEFAULTS.scoreThreshold, `score=${score}`);
  });

  it("UWB just-too-far does NOT cross the threshold", () => {
    const a = devA([{ kind: "uwb", peerToken: tB, distanceM: 0.30, observedAtMs: 1000 }]);
    const b = devB([]);
    const { score } = scorePair(a, b);
    assert.ok(score < MATCHER_DEFAULTS.scoreThreshold);
  });

  it("BLE alone is not enough", () => {
    const a = devA([{ kind: "ble", peerToken: tB, rssiDbm: -40, observedAtMs: 1000 }]);
    const b = devB([{ kind: "ble", peerToken: tA, rssiDbm: -42, observedAtMs: 1000 }]);
    const { score } = scorePair(a, b);
    assert.ok(score < MATCHER_DEFAULTS.scoreThreshold);
  });

  it("Bump alone is not enough", () => {
    const a = devA([{ kind: "bump", observedAtMs: 1000, magnitudeG: 8 }]);
    const b = devB([{ kind: "bump", observedAtMs: 1050, magnitudeG: 9 }]);
    const { score } = scorePair(a, b);
    assert.ok(score < MATCHER_DEFAULTS.scoreThreshold);
  });

  it("BLE + bump together cross the threshold (the SE-2 happy path)", () => {
    const a = devA([
      { kind: "ble", peerToken: tB, rssiDbm: -40, observedAtMs: 1000 },
      { kind: "bump", observedAtMs: 1000, magnitudeG: 8 },
    ]);
    const b = devB([
      { kind: "ble", peerToken: tA, rssiDbm: -42, observedAtMs: 1000 },
      { kind: "bump", observedAtMs: 1050, magnitudeG: 9 },
    ]);
    const { score, contributing } = scorePair(a, b);
    assert.ok(score >= MATCHER_DEFAULTS.scoreThreshold, `score=${score}`);
    assert.deepEqual(contributing.sort(), ["ble", "bump"]);
  });

  it("Bumps spaced > 200ms apart do NOT count as paired bumps", () => {
    const a = devA([{ kind: "bump", observedAtMs: 1000, magnitudeG: 8 }]);
    const b = devB([{ kind: "bump", observedAtMs: 1500, magnitudeG: 8 }]);
    const { score } = scorePair(a, b);
    assert.equal(score, 0);
  });

  it("Weak BLE (RSSI below threshold) does not count", () => {
    const a = devA([{ kind: "ble", peerToken: tB, rssiDbm: -80, observedAtMs: 1000 }]);
    const b = devB([{ kind: "ble", peerToken: tA, rssiDbm: -78, observedAtMs: 1000 }]);
    const { score } = scorePair(a, b);
    assert.equal(score, 0);
  });

  it("Audio chirp + BLE together cross the threshold", () => {
    const a = devA([
      { kind: "audio", peerToken: tB, snrDb: 15, observedAtMs: 1000 },
      { kind: "ble", peerToken: tB, rssiDbm: -40, observedAtMs: 1000 },
    ]);
    const b = devB([]);
    const { score } = scorePair(a, b);
    assert.ok(score >= MATCHER_DEFAULTS.scoreThreshold);
  });
});

describe("resolveTouches greedy assignment", () => {
  it("picks the highest-scoring claim and locks both players out of further claims", () => {
    // A and B touch with UWB + BLE + bump (score 9.0).
    // A and C have a weaker BLE-only claim (score 2.0, below threshold).
    const a = devA([
      { kind: "uwb", peerToken: tB, distanceM: 0.05, observedAtMs: 1000 },
      { kind: "ble", peerToken: tB, rssiDbm: -40, observedAtMs: 1000 },
      { kind: "bump", observedAtMs: 1000, magnitudeG: 8 },
      { kind: "ble", peerToken: "tokC", rssiDbm: -40, observedAtMs: 1000 },
    ]);
    const b: DeviceEvidence = {
      playerId: "B",
      selfToken: tB,
      receivedAtMs: 1000,
      channels: [
        { kind: "ble", peerToken: tA, rssiDbm: -40, observedAtMs: 1000 },
        { kind: "bump", observedAtMs: 1000, magnitudeG: 8 },
      ],
    };
    const c: DeviceEvidence = {
      playerId: "C",
      selfToken: "tokC",
      receivedAtMs: 1000,
      channels: [{ kind: "ble", peerToken: tA, rssiDbm: -40, observedAtMs: 1000 }],
    };
    const touches = resolveTouches([a, b, c]);
    assert.equal(touches.length, 1);
    const t = touches[0]!;
    assert.deepEqual([t.a, t.b].sort(), ["A", "B"]);
  });
});
