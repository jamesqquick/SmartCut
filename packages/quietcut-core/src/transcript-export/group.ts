import { SENTENCE_END } from "../retake/transcript-text.js";
import type { TranscriptToken } from "../types.js";

// ---------------------------------------------------------------------------
// Group edited-timeline words into sentence-ish segments. Each segment gives an
// AI a clean anchor (start/end + text) for placing overlays or b-roll, while the
// underlying word array preserves sub-second precision.
// ---------------------------------------------------------------------------

export type TranscriptSegment = {
  id: number;
  start: number;
  end: number;
  text: string;
};

export type GroupOptions = {
  /** Split when the silent gap before the next word exceeds this (seconds). */
  maxGapSec: number;
  /** Hard cap on words per segment so run-on speech still breaks. */
  maxWords: number;
};

const DEFAULTS: GroupOptions = { maxGapSec: 0.6, maxWords: 18 };

/**
 * Group words into segments, breaking on sentence-ending punctuation, a pause
 * longer than `maxGapSec`, or after `maxWords` words — whichever comes first.
 * Input words are assumed to be on the edited timeline and in order.
 */
export function groupIntoSegments(
  words: TranscriptToken[],
  options: Partial<GroupOptions> = {},
): TranscriptSegment[] {
  const { maxGapSec, maxWords } = { ...DEFAULTS, ...options };
  const segments: TranscriptSegment[] = [];

  let current: TranscriptToken[] = [];
  let id = 0;

  const flush = () => {
    if (current.length === 0) return;
    segments.push({
      id: id++,
      start: current[0].start,
      end: current[current.length - 1].end,
      text: current
        .map((w) => w.word)
        .join(" ")
        .replace(/\s+/g, " ")
        .trim(),
    });
    current = [];
  };

  for (let i = 0; i < words.length; i++) {
    const word = words[i];
    const prev = current[current.length - 1];
    const gap = prev ? word.start - prev.end : 0;

    // A pause before this word ends the previous segment.
    if (prev && gap > maxGapSec) flush();

    current.push(word);

    const endsSentence = SENTENCE_END.test(word.word);
    if (endsSentence || current.length >= maxWords) flush();
  }
  flush();

  return segments;
}
