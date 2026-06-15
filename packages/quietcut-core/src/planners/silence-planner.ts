import {
  applyPadding,
  invertToKeep,
  mergeOverlaps,
  summarize,
} from "../segments.js";
import type { Segment, Summary } from "../types.js";

export type SilencePlanResult = {
  keep: Segment[];
  silenceCuts: Segment[]; // the original silence segments (what was removed)
  summary: Summary;
};

/**
 * Given a list of detected silence segments and the video duration,
 * compute the keep segments and summary.
 *
 * @param silences - silence segments from detectSilences
 * @param duration - total video duration in seconds
 * @param leadInMs - padding before each kept segment (ms)
 * @param tailOutMs - padding after each kept segment (ms)
 */
export function planSilenceCuts(
  silences: Segment[],
  duration: number,
  leadInMs: number,
  tailOutMs: number,
): SilencePlanResult {
  const raw = invertToKeep(silences, duration);
  const padded = applyPadding(raw, leadInMs, tailOutMs, duration);
  const keep = mergeOverlaps(padded);
  const summary = summarize(keep, duration);

  return { keep, silenceCuts: silences, summary };
}
