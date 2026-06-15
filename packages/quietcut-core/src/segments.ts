import type { Segment, Summary } from "./types.js";

/**
 * Invert silence segments into "keep" segments across the full duration.
 * e.g. silences at [2-5, 8-10] in a 12s file → keep [0-2, 5-8, 10-12]
 */
export function invertToKeep(silences: Segment[], duration: number): Segment[] {
  if (silences.length === 0) {
    return [{ start: 0, end: duration }];
  }

  const keep: Segment[] = [];
  let cursor = 0;

  for (const silence of silences) {
    if (cursor < silence.start) {
      keep.push({ start: cursor, end: silence.start });
    }
    cursor = silence.end;
  }

  if (cursor < duration) {
    keep.push({ start: cursor, end: duration });
  }

  return keep;
}

/**
 * Expand each keep segment by leadIn before and tailOut after.
 * Clamps to [0, duration].
 */
export function applyPadding(
  segments: Segment[],
  leadInMs: number,
  tailOutMs: number,
  duration: number,
): Segment[] {
  const leadIn = leadInMs / 1000;
  const tailOut = tailOutMs / 1000;

  return segments.map((seg) => ({
    start: Math.max(0, seg.start - leadIn),
    end: Math.min(duration, seg.end + tailOut),
  }));
}

/**
 * Merge overlapping or adjacent segments into the fewest possible ranges.
 */
export function mergeOverlaps(segments: Segment[]): Segment[] {
  if (segments.length === 0) return [];

  const sorted = [...segments].sort((a, b) => a.start - b.start);
  const merged: Segment[] = [{ ...sorted[0] }];

  for (let i = 1; i < sorted.length; i++) {
    const current = sorted[i];
    const last = merged[merged.length - 1];

    if (current.start <= last.end) {
      last.end = Math.max(last.end, current.end);
    } else {
      merged.push({ ...current });
    }
  }

  return merged;
}

/**
 * Subtract a set of cut regions from keep segments. Any portion of a keep
 * segment that overlaps a cut is removed; non-overlapping portions survive.
 *
 * Used to ensure padding never re-introduces retake (speech) cuts: padding may
 * expand a kept segment into an adjacent removed region, so we clip those
 * regions back out afterward.
 */
export function subtractRegions(keeps: Segment[], cuts: Segment[]): Segment[] {
  if (cuts.length === 0) return keeps;

  const sortedCuts = mergeOverlaps(cuts);
  const result: Segment[] = [];

  for (const keep of keeps) {
    let pieces: Segment[] = [{ ...keep }];
    for (const cut of sortedCuts) {
      const next: Segment[] = [];
      for (const piece of pieces) {
        // No overlap
        if (cut.end <= piece.start || cut.start >= piece.end) {
          next.push(piece);
          continue;
        }
        // Left remainder
        if (cut.start > piece.start) {
          next.push({ start: piece.start, end: cut.start });
        }
        // Right remainder
        if (cut.end < piece.end) {
          next.push({ start: cut.end, end: piece.end });
        }
        // Fully covered portion is dropped
      }
      pieces = next;
    }
    for (const piece of pieces) {
      if (piece.end - piece.start > 1e-6) result.push(piece);
    }
  }

  return result;
}

/**
 * Build a summary of original vs. output duration.
 */
export function summarize(keep: Segment[], originalDuration: number): Summary {
  const newDuration = keep.reduce((acc, seg) => acc + (seg.end - seg.start), 0);
  const saved = originalDuration - newDuration;
  const savedPercent = (saved / originalDuration) * 100;
  // Number of cuts = number of gaps between keep segments
  const cutCount = keep.length - 1;

  return { originalDuration, newDuration, saved, savedPercent, cutCount };
}

/**
 * Warn if minSilence is smaller than leadIn + tailOut — padding will swallow cuts.
 */
export function checkPaddingWarning(
  minSilenceSeconds: number,
  leadInMs: number,
  tailOutMs: number,
): string | null {
  const paddingSeconds = (leadInMs + tailOutMs) / 1000;
  if (minSilenceSeconds < paddingSeconds) {
    return (
      `Warning: --min-silence (${minSilenceSeconds}s) is less than lead-in + tail-out ` +
      `(${paddingSeconds}s). Some silences may not be cut after padding is applied.`
    );
  }
  return null;
}
