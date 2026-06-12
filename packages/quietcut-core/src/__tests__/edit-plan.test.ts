import { describe, it, expect } from "vitest";
import { mkdtemp, writeFile, rm } from "node:fs/promises";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  buildEditPlan,
  planToKeepSegments,
  loadPlan,
  savePlan,
  retakeOps,
  type EditOperation,
} from "../edit-plan.js";

describe("planToKeepSegments", () => {
  it("collapses silence + retake removals into keep segments", () => {
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
    const keep = planToKeepSegments(plan, 0, 0);
    expect(keep).toEqual([
      { start: 0, end: 2 },
      { start: 3, end: 5 },
      { start: 7, end: 10 },
    ]);
  });

  it("never lets lead-in/tail-out padding bleed back into a retake cut", () => {
    // Padding would expand the kept segment ending at 5 forward into the retake
    // [5,7]; subtractRegions must clip it back out so removed speech stays gone.
    const ops: EditOperation[] = [
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
    const keep = planToKeepSegments(plan, 500, 500); // 0.5s padding each side
    for (const seg of keep) {
      // No kept segment may overlap the retake region [5, 7].
      expect(seg.start >= 7 || seg.end <= 5).toBe(true);
    }
  });

  it("returns the whole file as one segment when there are no operations", () => {
    const plan = buildEditPlan("in.mp4", 10, []);
    expect(planToKeepSegments(plan, 0, 0)).toEqual([{ start: 0, end: 10 }]);
  });

  it("sorts operations by start time and filters retakeOps", () => {
    const ops: EditOperation[] = [
      {
        type: "removeRetake",
        start: 8,
        end: 9,
        reason: "r",
        removedText: "",
        keptText: "",
        contextBefore: "",
        contextAfter: "",
        confidence: 90,
      },
      { type: "removeSilence", start: 1, end: 2 },
    ];
    const plan = buildEditPlan("in.mp4", 10, ops);
    expect(plan.operations[0].type).toBe("removeSilence");
    expect(retakeOps(plan)).toHaveLength(1);
  });
});

describe("loadPlan validation", () => {
  let dir: string;

  async function write(obj: unknown): Promise<string> {
    dir = await mkdtemp(join(tmpdir(), "quietcut-plan-"));
    const p = join(dir, "plan.json");
    await writeFile(p, JSON.stringify(obj), "utf8");
    return p;
  }

  it("round-trips a valid plan", async () => {
    const plan = buildEditPlan("in.mp4", 10, [
      { type: "removeSilence", start: 1, end: 2 },
    ]);
    dir = await mkdtemp(join(tmpdir(), "quietcut-plan-"));
    const p = join(dir, "plan.json");
    await savePlan(p, plan);
    const loaded = await loadPlan(p);
    expect(loaded).toEqual(plan);
    await rm(dir, { recursive: true, force: true });
  });

  it("rejects an operation that exceeds the source duration", async () => {
    const p = await write({
      source: "in.mp4",
      duration: 5,
      operations: [{ type: "removeSilence", start: 1, end: 9 }],
    });
    await expect(loadPlan(p)).rejects.toThrow(/outside the source duration/);
    await rm(dir, { recursive: true, force: true });
  });

  it("rejects a non-positive span", async () => {
    const p = await write({
      source: "in.mp4",
      duration: 5,
      operations: [{ type: "removeSilence", start: 3, end: 3 }],
    });
    await expect(loadPlan(p)).rejects.toThrow(/non-positive span/);
    await rm(dir, { recursive: true, force: true });
  });

  it("rejects an unsupported operation type", async () => {
    const p = await write({
      source: "in.mp4",
      duration: 5,
      operations: [{ type: "overlayText", start: 1, end: 2 }],
    });
    await expect(loadPlan(p)).rejects.toThrow(/unsupported operation type/);
    await rm(dir, { recursive: true, force: true });
  });

  it("rejects an invalid duration", async () => {
    const p = await write({
      source: "in.mp4",
      duration: 0,
      operations: [],
    });
    await expect(loadPlan(p)).rejects.toThrow(/invalid duration/);
    await rm(dir, { recursive: true, force: true });
  });
});
