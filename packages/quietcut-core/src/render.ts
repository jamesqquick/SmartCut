import { execa, type ResultPromise } from "execa";
import type { Config, Segment } from "./types.js";

/**
 * Progress payload emitted while ffmpeg renders.
 * Mirrors the fields on the `renderProgress` pipeline event.
 */
export type RenderProgress = {
  frame?: number;
  fps?: number;
  speed?: number;
  percent?: number;
  etaSec?: number;
};

export type RenderOptions = {
  /** Called whenever ffmpeg emits a `-progress pipe:1` block. */
  onProgress?: (p: RenderProgress) => void;
  /**
   * Optional sink for the child process so callers (sidecar) can
   * cancel by killing it. Called synchronously with the spawned proc.
   */
  onProcess?: (proc: ResultPromise) => void;
};

/**
 * Build a filter_complex graph using trim/atrim + concat for the given keep segments.
 *
 * This scales to hundreds of segments without overflowing ffmpeg's expression
 * parser (which the older single-expression `select=between(t,..)+...` approach
 * does around ~100+ segments).
 */
function buildTrimConcatFilter(segments: Segment[]): string {
  const parts: string[] = [];
  const concatInputs: string[] = [];

  segments.forEach((seg, i) => {
    parts.push(
      `[0:v]trim=start=${seg.start}:end=${seg.end},setpts=PTS-STARTPTS[v${i}]`
    );
    parts.push(
      `[0:a]atrim=start=${seg.start}:end=${seg.end},asetpts=PTS-STARTPTS[a${i}]`
    );
    concatInputs.push(`[v${i}][a${i}]`);
  });

  parts.push(
    `${concatInputs.join("")}concat=n=${segments.length}:v=1:a=1[v][a]`
  );

  return parts.join(";");
}

/**
 * Parse one or more key=value blocks from ffmpeg's `-progress pipe:1` stream.
 * ffmpeg emits a block like:
 *
 *   frame=123
 *   fps=24.0
 *   out_time_ms=4083333
 *   speed=1.07x
 *   progress=continue
 *
 * `out_time_ms` is documented as microseconds despite the name.
 */
function parseProgressBlock(
  text: string,
  totalKeptMs: number
): RenderProgress | undefined {
  const fields: Record<string, string> = {};
  for (const line of text.split("\n")) {
    const eq = line.indexOf("=");
    if (eq <= 0) continue;
    fields[line.slice(0, eq).trim()] = line.slice(eq + 1).trim();
  }
  if (Object.keys(fields).length === 0) return undefined;

  const out: RenderProgress = {};
  if (fields.frame) {
    const n = parseInt(fields.frame, 10);
    if (Number.isFinite(n)) out.frame = n;
  }
  if (fields.fps) {
    const n = parseFloat(fields.fps);
    if (Number.isFinite(n) && n > 0) out.fps = n;
  }
  if (fields.speed) {
    const m = fields.speed.match(/([\d.]+)x/);
    if (m) {
      const n = parseFloat(m[1]);
      if (Number.isFinite(n) && n > 0) out.speed = n;
    }
  }
  if (fields.out_time_ms && totalKeptMs > 0) {
    const microseconds = parseInt(fields.out_time_ms, 10);
    if (Number.isFinite(microseconds)) {
      const elapsedMs = microseconds / 1000;
      const percent = Math.max(0, Math.min(100, (elapsedMs / totalKeptMs) * 100));
      out.percent = percent;
      if (out.speed && out.speed > 0) {
        const remainingMs = Math.max(0, totalKeptMs - elapsedMs);
        out.etaSec = remainingMs / 1000 / out.speed;
      }
    }
  }
  return out;
}

/**
 * Render the output file using a single ffmpeg pass.
 * Uses trim/atrim + concat filters for frame-accurate hard cuts with timestamp rewriting.
 *
 * Optional `onProgress` callback is invoked as ffmpeg reports progress.
 * The function no longer prints anything on its own — UI is the caller's job.
 */
export async function render(
  config: Config,
  keep: Segment[],
  options: RenderOptions = {}
): Promise<void> {
  const { input, output, crf, preset } = config;
  const filterComplex = buildTrimConcatFilter(keep);

  const totalKeptMs = keep.reduce(
    (acc, seg) => acc + (seg.end - seg.start) * 1000,
    0
  );

  const args = [
    "-hide_banner",
    "-y",
    "-i",
    input,
    "-filter_complex",
    filterComplex,
    "-map",
    "[v]",
    "-map",
    "[a]",
    "-c:v",
    "libx264",
    "-crf",
    String(crf),
    "-preset",
    preset,
    "-pix_fmt",
    "yuv420p",
    "-c:a",
    "aac",
    "-b:a",
    "192k",
    "-movflags",
    "+faststart",
    "-progress",
    "pipe:1",
    output,
  ];

  const proc = execa("ffmpeg", args, {
    reject: false,
    stdout: "pipe",
    stderr: "pipe",
  });
  options.onProcess?.(proc);

  if (proc.stdout && options.onProgress) {
    let buffer = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      // ffmpeg flushes a block whenever it writes `progress=continue` or
      // `progress=end`. Split on that boundary to parse complete blocks.
      let idx: number;
      while ((idx = buffer.indexOf("progress=")) !== -1) {
        const nlAfter = buffer.indexOf("\n", idx);
        if (nlAfter === -1) break;
        const block = buffer.slice(0, nlAfter);
        buffer = buffer.slice(nlAfter + 1);
        const update = parseProgressBlock(block, totalKeptMs);
        if (update) options.onProgress!(update);
      }
    });
  }

  const result = await proc;

  if (result.exitCode !== 0) {
    const errOutput = result.stderr ?? "";
    throw new Error(`ffmpeg exited with code ${result.exitCode}:\n${errOutput}`);
  }
}
