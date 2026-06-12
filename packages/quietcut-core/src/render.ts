import ora from "ora";
import chalk from "chalk";
import { execa } from "execa";
import { formatDuration } from "./utils/time.js";
import { summarize } from "./segments.js";
import type { Config, Segment } from "./types.js";

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
 * Render the output file using a single ffmpeg pass.
 * Uses trim/atrim + concat filters for frame-accurate hard cuts with timestamp rewriting.
 */
export async function render(config: Config, keep: Segment[]): Promise<void> {
  const { input, output, crf, preset } = config;
  const summary = summarize(keep, 0); // cutCount not needed here
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

  const spinner = ora("Rendering...").start();

  const proc = execa("ffmpeg", args, {
    reject: false,
    stdout: "pipe",
    stderr: "pipe",
  });

  // Parse progress from -progress pipe:1 output
  if (proc.stdout) {
    let buffer = "";
    proc.stdout.on("data", (chunk: Buffer) => {
      buffer += chunk.toString();
      const lines = buffer.split("\n");
      buffer = lines.pop() ?? "";

      for (const line of lines) {
        const match = line.match(/^out_time_ms=(\d+)/);
        if (match) {
          // ffmpeg's `out_time_ms` is actually microseconds despite the name.
          const elapsedMs = parseInt(match[1], 10) / 1000;
          const pct = Math.min((elapsedMs / totalKeptMs) * 100, 100);
          spinner.text = `Rendering... ${pct.toFixed(1)}%`;
        }
      }
    });
  }

  const result = await proc;

  if (result.exitCode !== 0) {
    spinner.fail("Render failed.");
    const errOutput = result.stderr ?? "";
    throw new Error(`ffmpeg exited with code ${result.exitCode}:\n${errOutput}`);
  }

  spinner.succeed(chalk.green("Render complete."));
}
