import { describe, expect, it } from "vitest";
import { snapRetakeCutRegion } from "../retake/snap.js";
import type { Segment } from "../types.js";

// Fine silence boundaries captured from a real clip (2026-06-11 15-13-18.mov),
// ffmpeg silencedetect=noise=-40dB:d=0.1.
const REAL_SILENCES: Segment[] = [
  { start: 0, end: 0.560937 },
  { start: 0.766813, end: 1.053562 },
  { start: 1.297625, end: 1.458937 },
  { start: 4.0725, end: 4.174313 },
  { start: 4.811687, end: 5.12775 },
  { start: 6.224188, end: 7.133125 },
  { start: 9.682, end: 10.592 },
];

describe("snapRetakeCutRegion", () => {
  it("snaps the start to a silence end but clamps the end at the kept onset", () => {
    // whisper placed the kept word at 6.60s, inside the [6.224, 7.133] pause.
    // Snapping the end forward to 7.133 would clip the kept word's first word,
    // so the end is clamped to the original onset (6.60). The start still snaps.
    const snapped = snapRetakeCutRegion(
      { start: 5.14, end: 6.6 },
      REAL_SILENCES,
    );
    expect(snapped.start).toBeCloseTo(5.12775, 5);
    expect(snapped.end).toBeCloseTo(6.6, 5);
  });

  it("never advances the end past the kept word onset (clip protection)", () => {
    // A silence ends shortly AFTER the kept onset (soft onset dipped below the
    // threshold). The end must not jump forward to it.
    const silences: Segment[] = [{ start: 9.8, end: 10.3 }];
    const snapped = snapRetakeCutRegion({ start: 5.0, end: 10.0 }, silences);
    expect(snapped.end).toBeCloseTo(10.0, 5); // clamped, not 10.3
  });

  it("lets the end snap earlier to a silence edge just before the kept onset", () => {
    // A short pre-kept pause ends at 6.95, just before the kept onset at 7.0.
    const silences: Segment[] = [{ start: 6.6, end: 6.95 }];
    const snapped = snapRetakeCutRegion({ start: 2.0, end: 7.0 }, silences);
    expect(snapped.end).toBeCloseTo(6.95, 5); // trimmed pre-roll, no clip
  });

  it("keeps the original time when no boundary is within the window", () => {
    const silences: Segment[] = [{ start: 0, end: 0.5 }];
    const region = { start: 10, end: 12 };
    expect(snapRetakeCutRegion(region, silences)).toEqual(region);
  });

  it("returns the original region when snapping would invert/collapse it", () => {
    // Both boundaries fall inside the same silence -> both snap to its end,
    // which would collapse the cut. Guard must restore the original region.
    const silences: Segment[] = [{ start: 0.9, end: 2.0 }];
    const region = { start: 1.0, end: 1.2 };
    expect(snapRetakeCutRegion(region, silences)).toEqual(region);
  });

  it("handles an empty silence list by returning the region unchanged", () => {
    const region = { start: 3, end: 4 };
    expect(snapRetakeCutRegion(region, [])).toEqual(region);
  });
});
