/**
 * CueDispatcher
 * --------------
 * Picks pair assignments and cue content for a round.
 *
 * Inputs: list of player ids and the chosen game mode.
 * Outputs: a list of `Assignment`s, one per player, that the round engine
 * forwards privately to each player.
 *
 * Pure / deterministic given an injected RNG, which keeps tests stable.
 */
import { CUE_BANK, type CuePair } from "./cueBank.js";

export type Role = "pair" | "poison_apple";

export interface Assignment {
  playerId: string;
  role: Role;
  /** Stable for the round; null when role === "poison_apple" (no real partner). */
  partnerPlayerId: string | null;
  cueId: string;
  cueText: string;
  cueHint: string;
}

export interface RngLike {
  /** Returns a float in [0, 1). */
  next(): number;
}

export const defaultRng: RngLike = { next: () => Math.random() };

/**
 * Assign pairs (and optionally a poison-apple role for odd counts).
 *
 * - Players are shuffled, then walked two-at-a-time to form pairs.
 * - If `mode === "poison_apple"` AND the count is odd, the leftover player
 *   gets a real cue (from a random pair) but `role: "poison_apple"`.
 * - For other modes with odd counts, the leftover player sits out the round
 *   (caller is responsible for that — we simply emit no Assignment for them).
 */
export function assignRound(
  playerIds: string[],
  mode: "musical_chairs" | "poison_apple" | "scavenger_hunt",
  rng: RngLike = defaultRng
): Assignment[] {
  if (playerIds.length < 2) return [];
  const shuffled = shuffle(playerIds, rng);
  const assignments: Assignment[] = [];

  let i = 0;
  while (i + 1 < shuffled.length) {
    const a = shuffled[i]!;
    const b = shuffled[i + 1]!;
    const cue = pickCue(rng);
    assignments.push({
      playerId: a,
      role: "pair",
      partnerPlayerId: b,
      cueId: cue.cueId,
      cueText: cue.a.text,
      cueHint: cue.a.hint,
    });
    assignments.push({
      playerId: b,
      role: "pair",
      partnerPlayerId: a,
      cueId: cue.cueId,
      cueText: cue.b.text,
      cueHint: cue.b.hint,
    });
    i += 2;
  }

  const leftover = shuffled[i];
  if (leftover !== undefined) {
    if (mode === "poison_apple") {
      const cue = pickCue(rng);
      // Poison apple gets one side of a random cue and tries to convince a
      // real pair that they belong together.
      assignments.push({
        playerId: leftover,
        role: "poison_apple",
        partnerPlayerId: null,
        cueId: cue.cueId,
        cueText: cue.a.text,
        cueHint: "You're the poison apple. Convince someone you're their pair.",
      });
    }
    // For other modes, leftover sits out: caller handles UI for that.
  }

  return assignments;
}

function pickCue(rng: RngLike): CuePair {
  const idx = Math.floor(rng.next() * CUE_BANK.length);
  return CUE_BANK[idx] ?? CUE_BANK[0]!;
}

function shuffle<T>(arr: T[], rng: RngLike): T[] {
  const out = arr.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(rng.next() * (i + 1));
    const tmp = out[i]!;
    out[i] = out[j]!;
    out[j] = tmp;
  }
  return out;
}
