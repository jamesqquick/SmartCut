import { execa, type ResultPromise } from "execa";
import type { Config, Segment, VideoEncoder } from "./types.js";
import { detectVideoToolbox } from "./utils/ffmpeg.js";

/** The encoder actually used after resolving "auto"/availability. */
export type ResolvedVideoEncoder = "hardware" | "software";

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
  /**
   * Called once with the encoder actually selected, after resolving "auto"
   * and probing hardware availability. Lets callers surface/log it.
   */
  onEncoder?: (encoder: ResolvedVideoEncoder) => void;
};

/** ffmpeg encoder name for hardware H.264 on macOS. */
const VIDEOTOOLBOX_H264 = "h264_videotoolbox";

/**
 * Map an x264-style CRF (lower = better; UI range 12–30) onto a VideoToolbox
 * constant-quality value (`-q:v`, higher = better; 1–100).
 *
 * VideoToolbox has no CRF. Its 1–100 scale is monotonic (higher q → higher
 * bitrate/quality), so we map the CRF UI range [12,30] linearly onto [80,40]
 * and clamp. This keeps the existing Quality slider meaningful when the
 * renderer falls back to — or is forced onto — hardware encoding.
 */
export function crfToVideoToolboxQuality(crf: number): number {
  const q = Math.round(80 - ((crf - 12) * 40) / 18);
  return Math.max(1, Math.min(100, q));
}

/**
 * Resolve the requested encoder preference into a concrete encoder, probing
 * VideoToolbox availability when relevant.
 * - "software" never probes.
 * - "hardware" probes and throws if unavailable (fail fast — the caller asked
 *   for it explicitly).
 * - "auto" probes and silently falls back to software.
 */
async function resolveEncoder(
  pref: VideoEncoder,
): Promise<ResolvedVideoEncoder> {
  if (pref === "software") return "software";

  const hardwareAvailable = await detectVideoToolbox();
  if (pref === "hardware") {
    if (!hardwareAvailable) {
      throw new Error(
        `Hardware encoder "${VIDEOTOOLBOX_H264}" is not available in this ffmpeg build. ` +
          `Use encoder "auto" or "software".`,
      );
    }
    return "hardware";
  }
  return hardwareAvailable ? "hardware" : "software";
}

/**
 * Build the `-c:v …` portion of the ffmpeg command for the resolved encoder.
 * Hardware uses VideoToolbox constant-quality; software uses libx264 CRF.
 */
function buildVideoCodecArgs(
  encoder: ResolvedVideoEncoder,
  crf: number,
  preset: string,
): string[] {
  if (encoder === "hardware") {
    return [
      "-c:v",
      VIDEOTOOLBOX_H264,
      "-q:v",
      String(crfToVideoToolboxQuality(crf)),
      "-pix_fmt",
      "yuv420p",
    ];
  }
  return [
    "-c:v",
    "libx264",
    "-crf",
    String(crf),
    "-preset",
    preset,
    "-pix_fmt",
    "yuv420p",
  ];
}

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
      `[0:v]trim=start=${seg.start}:end=${seg.end},setpts=PTS-STARTPTS[v${i}]`,
    );
    parts.push(
      `[0:a]atrim=start=${seg.start}:end=${seg.end},asetpts=PTS-STARTPTS[a${i}]`,
    );
    concatInputs.push(`[v${i}][a${i}]`);
  });

  parts.push(
    `${concatInputs.join("")}concat=n=${segments.length}:v=1:a=1[v][a]`,
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
  totalKeptMs: number,
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
      const percent = Math.max(
        0,
        Math.min(100, (elapsedMs / totalKeptMs) * 100),
      );
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
  options: RenderOptions = {},
): Promise<void> {
  const { input, output, crf, preset, encoder } = config;
  const resolvedEncoder = await resolveEncoder(encoder);
  options.onEncoder?.(resolvedEncoder);

  const filterComplex = buildTrimConcatFilter(keep);

  const totalKeptMs = keep.reduce(
    (acc, seg) => acc + (seg.end - seg.start) * 1000,
    0,
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
    ...buildVideoCodecArgs(resolvedEncoder, crf, preset),
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
      let idx = buffer.indexOf("progress=");
      while (idx !== -1) {
        const nlAfter = buffer.indexOf("\n", idx);
        if (nlAfter === -1) break;
        const block = buffer.slice(0, nlAfter);
        buffer = buffer.slice(nlAfter + 1);
        const update = parseProgressBlock(block, totalKeptMs);
        if (update) options.onProgress?.(update);
        idx = buffer.indexOf("progress=");
      }
    });
  }

  const result = await proc;

  if (result.exitCode !== 0) {
    const errOutput = result.stderr ?? "";
    throw new Error(
      `ffmpeg exited with code ${result.exitCode}:\n${errOutput}`,
    );
  }
}
