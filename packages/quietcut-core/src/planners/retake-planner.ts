import { detectRetakes } from "../retake/detect-repeats.js";
import { snapMatches } from "../retake/snap.js";
import type { RetakeMatch, Segment, Token } from "../types.js";

export type RetakePlanResult = {
  matches: RetakeMatch[];
  cuts: Segment[]; // the cut regions to remove (snapped)
};

/**
 * Given tokens from transcription and silence segments for boundary snapping,
 * detect retakes and return the cut regions.
 *
 * @param tokens - word tokens from transcribeFromAudio or transcribe
 * @param snapSilences - silence segments used only for boundary snapping (can be [])
 * @param minWords - minimum matching words to count as a retake
 * @param maxGapSeconds - max seconds between end of first take and start of second
 */
export function planRetakeCuts(
  tokens: Token[],
  snapSilences: Segment[],
  minWords: number,
  maxGapSeconds: number,
): RetakePlanResult {
  const rawMatches = detectRetakes(tokens, minWords, maxGapSeconds);
  const matches = snapMatches(rawMatches, snapSilences);
  const cuts = matches.map((m) => m.cutRegion);
  return { matches, cuts };
}
