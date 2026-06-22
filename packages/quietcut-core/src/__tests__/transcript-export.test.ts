import { describe, expect, it } from "vitest";
import { buildEditPlan, type EditOperation } from "../edit-plan.js";
import {
  buildAiTranscript,
  buildEditedTranscript,
  editedDuration,
  formatSrt,
  formatSrtTimestamp,
  groupIntoSegments,
  remapTranscript,
} from "../transcript-export/index.js";
import type { Segment, TranscriptToken } from "../types.js";

// Keep segments for a 10s source with a silence cut [2,3] and a retake [5,7]:
// rendered timeline = [0-2] + [3-5] + [7-10] = 7s.
const KEEP: Segment[] = [
  { start: 0, end: 2 },
  { start: 3, end: 5 },
  { start: 7, end: 10 },
];

describe("remapTranscript", () => {
  it("keeps words before a cut unchanged", () => {
    const words: TranscriptToken[] = [{ word: "intro", start: 0.5, end: 0.9 }];
    expect(remapTranscript(words, KEEP)).toEqual([
      { word: "intro", start: 0.5, end: 0.9 },
    ]);
  });

  it("drops words whose midpoint falls inside a cut", () => {
    const words: TranscriptToken[] = [
      { word: "silence", start: 2.2, end: 2.6 }, // inside [2,3]
      { word: "retake", start: 6.0, end: 6.4 }, // inside [5,7]
    ];
    expect(remapTranscript(words, KEEP)).toEqual([]);
  });

  it("shifts words after cuts by the cumulative removed time", () => {
    const words: TranscriptToken[] = [
      { word: "mid", start: 3.5, end: 3.9 }, // seg1, offset 2
      { word: "late", start: 8.0, end: 8.4 }, // seg2, offset 4
    ];
    expect(remapTranscript(words, KEEP)).toEqual([
      { word: "mid", start: 2.5, end: 2.9 },
      { word: "late", start: 5.0, end: 5.4 },
    ]);
  });

  it("clamps a word that extends past its keep segment", () => {
    const words: TranscriptToken[] = [
      { word: "edge", start: 1.6, end: 2.2 }, // mid 1.9 in seg0; end bleeds into cut
    ];
    expect(remapTranscript(words, KEEP)).toEqual([
      { word: "edge", start: 1.6, end: 2.0 },
    ]);
  });

  it("never produces a timestamp outside the edited timeline", () => {
    const words: TranscriptToken[] = [
      { word: "a", start: 0.5, end: 0.9 },
      { word: "b", start: 3.5, end: 3.9 },
      { word: "c", start: 9.5, end: 9.9 },
    ];
    const duration = editedDuration(KEEP);
    for (const w of remapTranscript(words, KEEP)) {
      expect(w.start).toBeGreaterThanOrEqual(0);
      expect(w.end).toBeLessThanOrEqual(duration);
      expect(w.end).toBeGreaterThanOrEqual(w.start);
    }
  });

  it("returns nothing when there are no keep segments", () => {
    expect(remapTranscript([{ word: "x", start: 0, end: 1 }], [])).toEqual([]);
  });
});

describe("editedDuration", () => {
  it("sums kept segment lengths", () => {
    expect(editedDuration(KEEP)).toBe(7);
  });
});

describe("buildEditedTranscript", () => {
  it("remaps against the same keep segments the renderer uses", () => {
    const ops: EditOperation[] = [
      { type: "removeSilence", start: 2, end: 3 },
      {
        type: "removeRetake",
        start: 5,
        end: 7,
        reason: "restart",
        removedText: "a",
        keptText: "b",
        contextBefore: "",
        contextAfter: "",
        confidence: 90,
      },
    ];
    const plan = buildEditPlan("in.mp4", 10, ops);
    const transcript: TranscriptToken[] = [
      { word: "intro", start: 0.5, end: 0.9 },
      { word: "cut", start: 2.4, end: 2.8 },
      { word: "mid", start: 3.5, end: 3.9 },
      { word: "late", start: 8.0, end: 8.4 },
    ];
    const edited = buildEditedTranscript(transcript, plan, 0, 0);
    expect(edited.duration).toBe(7);
    expect(edited.words).toEqual([
      { word: "intro", start: 0.5, end: 0.9 },
      { word: "mid", start: 2.5, end: 2.9 },
      { word: "late", start: 5.0, end: 5.4 },
    ]);
  });
});

describe("formatSrtTimestamp", () => {
  it("formats seconds as HH:MM:SS,mmm", () => {
    expect(formatSrtTimestamp(0)).toBe("00:00:00,000");
    expect(formatSrtTimestamp(4.21)).toBe("00:00:04,210");
    expect(formatSrtTimestamp(3661.5)).toBe("01:01:01,500");
  });

  it("clamps negatives to zero", () => {
    expect(formatSrtTimestamp(-1)).toBe("00:00:00,000");
  });
});

describe("formatSrt", () => {
  it("breaks cues on sentence-ending punctuation", () => {
    const words: TranscriptToken[] = [
      { word: "Hello", start: 0, end: 0.4 },
      { word: "world.", start: 0.4, end: 0.9 },
      { word: "Next", start: 1.0, end: 1.3 },
      { word: "one.", start: 1.3, end: 1.8 },
    ];
    const srt = formatSrt(words);
    expect(srt).toBe(
      [
        "1",
        "00:00:00,000 --> 00:00:00,900",
        "Hello world.",
        "",
        "2",
        "00:00:01,000 --> 00:00:01,800",
        "Next one.",
        "",
      ].join("\n"),
    );
  });

  it("splits on a long pause between words", () => {
    const words: TranscriptToken[] = [
      { word: "before", start: 0, end: 0.4 },
      { word: "after", start: 2.0, end: 2.4 }, // 1.6s gap > 0.6s default
    ];
    const srt = formatSrt(words);
    expect(srt.split("\n\n")).toHaveLength(2);
  });

  it("returns an empty string for no words", () => {
    expect(formatSrt([])).toBe("");
  });
});

describe("groupIntoSegments", () => {
  it("splits on sentence end and on pauses", () => {
    const words: TranscriptToken[] = [
      { word: "So", start: 0, end: 0.2 },
      { word: "today", start: 0.2, end: 0.5 },
      { word: "wiring.", start: 0.5, end: 1.2 },
      { word: "The", start: 2.0, end: 2.2 }, // 0.8s gap
      { word: "way.", start: 2.2, end: 2.6 },
    ];
    const segments = groupIntoSegments(words);
    expect(segments).toEqual([
      { id: 0, start: 0, end: 1.2, text: "So today wiring." },
      { id: 1, start: 2.0, end: 2.6, text: "The way." },
    ]);
  });
});

describe("buildAiTranscript", () => {
  it("wraps words + segments with edited-timeline metadata", () => {
    const words: TranscriptToken[] = [
      { word: "Hello", start: 0, end: 0.4 },
      { word: "world.", start: 0.4, end: 0.9 },
    ];
    const ai = buildAiTranscript(words, { source: "in.mp4", duration: 0.9 });
    expect(ai.source).toBe("in.mp4");
    expect(ai.timeline).toBe("edited");
    expect(ai.duration).toBe(0.9);
    expect(ai.words).toEqual(words);
    expect(ai.segments).toEqual([
      { id: 0, start: 0, end: 0.9, text: "Hello world." },
    ]);
  });
});
