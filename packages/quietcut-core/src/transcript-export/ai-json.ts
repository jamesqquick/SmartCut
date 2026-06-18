import type { TranscriptToken } from "../types.js";
import { groupIntoSegments, type TranscriptSegment } from "./group.js";

// ---------------------------------------------------------------------------
// Structured, machine-readable transcript for AI editing decisions (overlays,
// b-roll). Segments give clean anchor points; the word array preserves the
// sub-second timings an AI needs to pick exact in/out points. All timings are
// on the final edited timeline.
// ---------------------------------------------------------------------------

export type AiTranscript = {
  source: string;
  timeline: "edited";
  duration: number;
  segments: TranscriptSegment[];
  words: TranscriptToken[];
};

export type AiTranscriptMeta = {
  source: string;
  duration: number;
};

/** Build the structured AI transcript object from edited-timeline words. */
export function buildAiTranscript(
  words: TranscriptToken[],
  meta: AiTranscriptMeta,
): AiTranscript {
  return {
    source: meta.source,
    timeline: "edited",
    duration: meta.duration,
    segments: groupIntoSegments(words),
    words,
  };
}

/** Serialize the AI transcript as pretty-printed JSON with a trailing newline. */
export function formatAiJson(
  words: TranscriptToken[],
  meta: AiTranscriptMeta,
): string {
  return `${JSON.stringify(buildAiTranscript(words, meta), null, 2)}\n`;
}
