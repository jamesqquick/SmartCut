import { SENTENCE_END } from "../retake/transcript-text.js";
import type { TranscriptToken } from "../types.js";

// ---------------------------------------------------------------------------
// Format edited-timeline words as a SubRip (.srt) caption track for YouTube.
// Words are chunked into 1–2 line cues on sentence ends, pauses, and length
// limits; timestamps use the SubRip `HH:MM:SS,mmm` form.
// ---------------------------------------------------------------------------

export type SrtOptions = {
  maxCharsPerLine: number;
  maxLines: number;
  maxCueSec: number;
  /** Split a cue when the gap before the next word exceeds this (seconds). */
  maxGapSec: number;
};

const DEFAULTS: SrtOptions = {
  maxCharsPerLine: 42,
  maxLines: 2,
  maxCueSec: 6,
  maxGapSec: 0.6,
};

/** Format a timestamp in seconds as SubRip `HH:MM:SS,mmm`. */
export function formatSrtTimestamp(seconds: number): string {
  const clamped = Math.max(0, seconds);
  const totalMs = Math.round(clamped * 1000);
  const ms = totalMs % 1000;
  const totalSec = Math.floor(totalMs / 1000);
  const s = totalSec % 60;
  const m = Math.floor(totalSec / 60) % 60;
  const h = Math.floor(totalSec / 3600);
  const pad = (n: number, width = 2) => String(n).padStart(width, "0");
  return `${pad(h)}:${pad(m)}:${pad(s)},${pad(ms, 3)}`;
}

type Cue = { start: number; end: number; words: string[] };

/** Greedy chunk: break on sentence end, pause, char budget, or duration cap. */
function chunkIntoCues(words: TranscriptToken[], opts: SrtOptions): Cue[] {
  const budget = opts.maxCharsPerLine * opts.maxLines;
  const cues: Cue[] = [];
  let current: TranscriptToken[] = [];

  const flush = () => {
    if (current.length === 0) return;
    cues.push({
      start: current[0].start,
      end: current[current.length - 1].end,
      words: current.map((w) => w.word),
    });
    current = [];
  };

  for (const word of words) {
    const prev = current[current.length - 1];
    const gap = prev ? word.start - prev.end : 0;
    const projectedChars =
      current.map((w) => w.word).join(" ").length + 1 + word.word.length;
    const projectedDur = prev ? word.end - current[0].start : 0;

    if (
      prev &&
      (gap > opts.maxGapSec ||
        projectedChars > budget ||
        projectedDur > opts.maxCueSec)
    ) {
      flush();
    }

    current.push(word);
    if (SENTENCE_END.test(word.word)) flush();
  }
  flush();

  return cues;
}

/** Wrap a cue's words across up to `maxLines` lines within the char budget. */
function wrapLines(words: string[], opts: SrtOptions): string[] {
  const lines: string[] = [];
  let line = "";
  for (const word of words) {
    const candidate = line ? `${line} ${word}` : word;
    if (
      line &&
      candidate.length > opts.maxCharsPerLine &&
      lines.length < opts.maxLines - 1
    ) {
      lines.push(line);
      line = word;
    } else {
      line = candidate;
    }
  }
  if (line) lines.push(line);
  return lines;
}

/**
 * Render edited-timeline words as a SubRip caption file. Returns an empty
 * string when there are no words.
 */
export function formatSrt(
  words: TranscriptToken[],
  options: Partial<SrtOptions> = {},
): string {
  const opts = { ...DEFAULTS, ...options };
  const cues = chunkIntoCues(words, opts);

  const blocks = cues.map((cue, i) => {
    const lines = wrapLines(cue.words, opts).join("\n");
    const range = `${formatSrtTimestamp(cue.start)} --> ${formatSrtTimestamp(cue.end)}`;
    return `${i + 1}\n${range}\n${lines}`;
  });

  // SubRip blocks are separated by a blank line; trailing newline is customary.
  return blocks.length > 0 ? `${blocks.join("\n\n")}\n` : "";
}
