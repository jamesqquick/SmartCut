import { mergeOverlaps } from "../segments.js";
import type { Segment } from "../types.js";

/**
 * Merge two sets of cut regions into a single deduplicated, sorted list.
 * Uses mergeOverlaps to collapse any overlapping or adjacent ranges.
 */
export function unionCutRegions(a: Segment[], b: Segment[]): Segment[] {
  return mergeOverlaps([...a, ...b]);
}
