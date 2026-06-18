import type { Segment, TranscriptToken } from "../types.js";

// ---------------------------------------------------------------------------
// Remap original-timeline transcript words onto the final edited timeline.
//
// The rendered video is the concatenation of `keep` segments (the same ones
// the renderer consumes — see planToKeepSegments). A word survives iff its
// midpoint falls inside a keep segment; its timestamps are then shifted earlier
// by the total removed time before it, so they line up exactly with the
// rendered file rather than the original recording.
// ---------------------------------------------------------------------------

/** Round to millisecond precision to avoid float drift in exported files. */
function roundMs(seconds: number): number {
  return Math.round(seconds * 1000) / 1000;
}

/**
 * Project original-timeline transcript words onto the edited timeline defined
 * by `keep` (the rendered keep segments). Words whose midpoint lies in a removed
 * region are dropped; survivors are re-timed so the first kept segment starts at
 * 0 and gaps between kept segments collapse.
 *
 * Word start/end are clamped to their containing keep segment so a word that
 * extends slightly into an adjacent cut never produces a timestamp outside the
 * edited timeline.
 */
export function remapTranscript(
  words: TranscriptToken[],
  keep: Segment[],
): TranscriptToken[] {
  if (keep.length === 0) return [];

  // Cumulative edited-timeline offset at the start of each keep segment.
  const offsets: number[] = [];
  let acc = 0;
  for (const seg of keep) {
    offsets.push(acc);
    acc += seg.end - seg.start;
  }

  const out: TranscriptToken[] = [];
  for (const w of words) {
    const mid = (w.start + w.end) / 2;
    const k = keep.findIndex((seg) => mid >= seg.start && mid < seg.end);
    if (k === -1) continue; // word lives in a removed region

    const seg = keep[k];
    const off = offsets[k];
    const clampedStart = Math.min(Math.max(w.start, seg.start), seg.end);
    const clampedEnd = Math.min(Math.max(w.end, seg.start), seg.end);
    const start = roundMs(off + (clampedStart - seg.start));
    const end = roundMs(off + (clampedEnd - seg.start));
    out.push({ word: w.word, start, end: Math.max(start, end) });
  }

  return out;
}

/** Total duration of the edited timeline (sum of kept segment lengths). */
export function editedDuration(keep: Segment[]): number {
  return roundMs(keep.reduce((acc, seg) => acc + (seg.end - seg.start), 0));
}
