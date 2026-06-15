import { describe, expect, it } from "vitest";
import {
  collapseRepeatedSegments,
  extractModelSize,
} from "../retake/transcribe.js";

describe("extractModelSize (DTW preset mapping)", () => {
  it("maps large filenames (hyphens) to whisper.cpp presets (dots)", () => {
    // The bug that broke large-v3: filename uses hyphens, --dtw wants dots.
    expect(extractModelSize("ggml-large-v3.bin", "large-v3")).toBe("large.v3");
    expect(extractModelSize("ggml-large-v2.bin", "large-v2")).toBe("large.v2");
    expect(extractModelSize("/x/y/ggml-large-v1.bin", "large-v1")).toBe(
      "large.v1",
    );
  });

  it("maps bare 'large' to the newest preset", () => {
    expect(extractModelSize("large", "large")).toBe("large.v3");
  });

  it("strips language suffixes to the base size", () => {
    expect(extractModelSize("ggml-base.en.bin", "base.en")).toBe("base");
    expect(extractModelSize("ggml-small.en.bin", "small.en")).toBe("small");
    expect(extractModelSize("medium.en", "medium.en")).toBe("medium");
  });

  it("passes through plain sizes", () => {
    expect(extractModelSize("small", "small")).toBe("small");
  });
});

function seg(text: string, fromMs: number, toMs: number) {
  return {
    text,
    timestamps: { from: "", to: "" },
    offsets: { from: fromMs, to: toMs },
    tokens: [
      {
        text,
        timestamps: { from: "", to: "" },
        offsets: { from: fromMs, to: toMs },
      },
    ],
  };
}

describe("collapseRepeatedSegments", () => {
  it("collapses a long run of identical segments (hallucination loop)", () => {
    const segs = Array.from({ length: 50 }, (_, i) =>
      seg(
        "And I'm going to go to the next page here.",
        i * 1000,
        (i + 1) * 1000,
      ),
    );
    const { segments, collapsed } = collapseRepeatedSegments(segs);
    expect(segments).toHaveLength(1);
    expect(collapsed).toHaveLength(1);
    expect(collapsed[0].count).toBe(50);
    expect(collapsed[0].fromSec).toBe(0);
    expect(collapsed[0].toSec).toBe(50);
  });

  it("leaves short legitimate repeats (a few attempts) intact", () => {
    const segs = [
      seg("Let's open the terminal.", 0, 1000),
      seg("Let's open the terminal.", 1000, 2000),
      seg("Now we run the build.", 2000, 3000),
    ];
    const { segments, collapsed } = collapseRepeatedSegments(segs);
    expect(segments).toHaveLength(3);
    expect(collapsed).toHaveLength(0);
  });

  it("matches ignoring punctuation/case differences", () => {
    const segs = Array.from({ length: 8 }, (_, i) =>
      seg(
        i % 2 === 0 ? "Go to the next page." : "go to the next page",
        i,
        i + 1,
      ),
    );
    const { segments, collapsed } = collapseRepeatedSegments(segs);
    expect(segments).toHaveLength(1);
    expect(collapsed[0].count).toBe(8);
  });
});
