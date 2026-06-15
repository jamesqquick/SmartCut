import path from "node:path";
import chalk from "chalk";
import Table from "cli-table3";
import {
  type EditPlan,
  formatDuration,
  formatTime,
  retakeOps,
  type Segment,
} from "quietcut-core";

export { formatDuration, formatTime };

// --- summary -----------------------------------------------------------------

type SummaryRow = {
  originalDuration: number;
  newDuration: number;
  saved: number;
  savedPercent: number;
  cutCount: number;
};

function summarize(keep: Segment[], duration: number): SummaryRow {
  const newDuration = keep.reduce((acc, s) => acc + (s.end - s.start), 0);
  const saved = Math.max(0, duration - newDuration);
  const savedPercent = duration > 0 ? (saved / duration) * 100 : 0;
  return {
    originalDuration: duration,
    newDuration,
    saved,
    savedPercent,
    cutCount: Math.max(0, keep.length - 1),
  };
}

// --- confidence color --------------------------------------------------------

export function formatConfidence(confidence: number): string {
  const pct = `${Math.round(confidence)}%`;
  if (confidence >= 80) return chalk.green(pct);
  if (confidence >= 50) return chalk.yellow(pct);
  return chalk.red(pct);
}

// --- main preview printer ----------------------------------------------------

/**
 * Print the final smartcut summary from an EditPlan: silence/retake counts and
 * the resulting keep-segment table.
 *
 * Ported from packages/quietcut/src/preview.ts.
 */
export function printSmartcutPreview(
  plan: EditPlan,
  keep: Segment[],
  duration: number,
  inputFile: string,
): void {
  const summary = summarize(keep, duration);
  const filename = path.basename(inputFile);
  const silenceCount = plan.operations.filter(
    (op) => op.type === "removeSilence",
  ).length;
  const retakeCount = retakeOps(plan).length;

  console.log();
  console.log(chalk.bold(`smartcut plan: ${chalk.cyan(filename)}`));
  console.log();
  console.log(`  ${chalk.dim("Silence regions:")}  ${silenceCount}`);
  console.log(`  ${chalk.dim("Retakes:")}         ${retakeCount}`);
  console.log();

  const retakes = retakeOps(plan);
  if (retakes.length > 0) {
    for (let i = 0; i < retakes.length; i++) {
      const op = retakes[i];
      const cutDuration = op.end - op.start;
      console.log(
        chalk.bold(`Retake ${i + 1}`) +
          `  ${chalk.dim(formatTime(op.start))} → ${chalk.dim(formatTime(op.end))}` +
          `  ${chalk.red(`-${formatDuration(cutDuration)}`)}` +
          `  ${chalk.dim("confidence")} ${formatConfidence(op.confidence)}`,
      );
      console.log(
        `  ${chalk.dim("Remove:")}  ${chalk.red(`"${op.removedText}"`)}`,
      );
      console.log(`  ${chalk.dim("Reason:")}  ${chalk.dim(op.reason)}`);
      console.log(`  ${chalk.dim("Result if removed:")}`);
      const before = op.contextBefore ?? "";
      const after = op.contextAfter ?? "";
      const stitched = [
        before ? chalk.dim(`…${before}`) : "",
        chalk.green(op.keptText),
        after ? chalk.dim(`${after}…`) : "",
      ]
        .filter(Boolean)
        .join(" ");
      console.log(`    ${stitched}`);
      console.log();
    }
  }

  const table = new Table({
    head: [
      chalk.bold("#"),
      chalk.bold("Keep From"),
      chalk.bold("Keep To"),
      chalk.bold("Kept"),
      chalk.bold("Cut Before"),
    ],
    style: { head: [], border: [] },
    colAligns: ["right", "left", "left", "right", "right"],
  });

  let prevEnd: number | null = null;
  for (let i = 0; i < keep.length; i++) {
    const seg = keep[i];
    const kept = seg.end - seg.start;
    const cutBefore = prevEnd !== null ? seg.start - prevEnd : null;
    table.push([
      String(i + 1),
      formatTime(seg.start),
      formatTime(seg.end),
      chalk.green(formatDuration(kept)),
      cutBefore !== null && cutBefore > 0
        ? chalk.red(`-${formatDuration(cutBefore)}`)
        : chalk.dim("—"),
    ]);
    prevEnd = seg.end;
  }

  console.log(table.toString());
  console.log();
  console.log(
    `  ${chalk.dim("Original:")}  ${formatDuration(summary.originalDuration)}`,
  );
  console.log(
    `  ${chalk.dim("New:     ")}  ${chalk.green(formatDuration(summary.newDuration))}`,
  );
  console.log(
    `  ${chalk.dim("Saved:   ")}  ${chalk.yellow(formatDuration(summary.saved))}  ${chalk.dim(`(${summary.savedPercent.toFixed(1)}%)`)}`,
  );
  console.log(`  ${chalk.dim("Cuts:    ")}  ${summary.cutCount}`);
  console.log();
}
