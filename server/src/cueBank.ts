/**
 * Seed cue bank for the prototype. Real product would load curated content
 * from JSON / a CMS. Each entry is a complementary pair: when assigned, one
 * player gets `a`, the other gets `b`, and they have to find each other.
 */
export interface CuePair {
  cueId: string;
  a: { text: string; hint: string };
  b: { text: string; hint: string };
}

export const CUE_BANK: CuePair[] = [
  {
    cueId: "animal_dog_cat",
    a: { text: "Bark like a dog.", hint: "Find the cat." },
    b: { text: "Meow like a cat.", hint: "Find the dog." },
  },
  {
    cueId: "duet_peanut_butter",
    a: { text: "Shout: Peanut butter!", hint: "Find your jelly." },
    b: { text: "Shout: Jelly!", hint: "Find your peanut butter." },
  },
  {
    cueId: "duet_salt_pepper",
    a: { text: "Shout: Salt!", hint: "Find your pepper." },
    b: { text: "Shout: Pepper!", hint: "Find your salt." },
  },
  {
    cueId: "phrase_knock",
    a: { text: "Say: Knock knock.", hint: "Find who answers." },
    b: { text: "Say: Who's there?", hint: "Find who's knocking." },
  },
  {
    cueId: "gesture_wave",
    a: { text: "Wave with your left hand.", hint: "Find the right-hand waver." },
    b: { text: "Wave with your right hand.", hint: "Find the left-hand waver." },
  },
  {
    cueId: "color_red_blue",
    a: { text: "Shout: Red!", hint: "Find the blue." },
    b: { text: "Shout: Blue!", hint: "Find the red." },
  },
];
