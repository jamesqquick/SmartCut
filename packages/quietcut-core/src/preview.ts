import Table from "cli-table3";
import chalk from "chalk";
import { confirm } from "@inquirer/prompts";
import { formatTime, formatDuration } from "./utils/time.js";
import { summarize } from "./segments.js";
import type { Segment, RetakeMatch } from "./types.js";
import type { EditPlan } from "./edit-plan.js";
import { retakeOps } from "./edit-plan.js";
import path from "node:path";

/**
 * Render a confidence percentage with traffic-light coloring:
 * green (high ≥ 80), yellow (medium 50–79), red (low < 50).
 */
export function formatConfidence(confidence: number): string {
  const pct = `${Math.round(confidence)}%`;
  if (confidence >= 80) return chalk.green(pct);
  if (confidence >= 50) return chalk.yellow(pct);
  return chalk.red(pct);
}

/**
 * Print the cut list table and summary to stdout.
 */
export function printPreview(
  keep: Segment[],
  duration: number,
  inputFile: string
): void {
  const summary = summarize(keep, duration);
  const filename = path.basename(inputFile);

  console.log();
  console.log(chalk.bold(`quietcut analysis: ${chalk.cyan(filename)}`));
  console.log();

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
    const cutBefore =
      prevEnd !== null ? seg.start - prevEnd : null;

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
    `  ${chalk.dim("Original:")}  ${formatDuration(summary.originalDuration)}`
  );
  console.log(
    `  ${chalk.dim("New:     ")}  ${chalk.green(formatDuration(summary.newDuration))}`
  );
  console.log(
    `  ${chalk.dim("Saved:   ")}  ${chalk.yellow(formatDuration(summary.saved))}  ${chalk.dim(`(${summary.savedPercent.toFixed(1)}%)`)}`
  );
  console.log(
    `  ${chalk.dim("Cuts:    ")}  ${summary.cutCount}`
  );
  console.log();
}

/**
 * Ask the user whether to proceed with rendering.
 * Returns true if approved, false if declined.
 */
export async function promptApproval(): Promise<boolean> {
  const answer = await confirm({
    message: "Proceed with render?",
    default: true,
  });
  return answer;
}

/**
 * Print a retake-focused cut list and summary to stdout.
 * Shows each detected retake with its matching phrase and both take texts
 * so the user can verify the right segment is being removed.
 */
export function printRetakePreview(
  matches: RetakeMatch[],
  keep: Segment[],
  duration: number,
  inputFile: string
): void {
  const summary = summarize(keep, duration);
  const filename = path.basename(inputFile);

  console.log();
  console.log(chalk.bold(`retakecut analysis: ${chalk.cyan(filename)}`));
  console.log();

  if (matches.length === 0) {
    console.log(chalk.green("  No retakes detected."));
    console.log();
    return;
  }

  for (let i = 0; i < matches.length; i++) {
    const m = matches[i];
    const cutDuration = m.cutRegion.end - m.cutRegion.start;

    console.log(
      chalk.bold(`Retake ${i + 1}`) +
        `  ${chalk.dim(formatTime(m.cutRegion.start))} → ${chalk.dim(formatTime(m.cutRegion.end))}` +
        `  ${chalk.red(`-${formatDuration(cutDuration)}`)}`
    );
    console.log(
      `  ${chalk.dim("Match:")}    ${chalk.yellow(`"${m.matchedPhrase}"`)}`
    );
    console.log(
      `  ${chalk.dim("Removed:")}  ${chalk.red(`"${m.firstTake.text}"`)}`
    );
    console.log(
      `  ${chalk.dim("Kept:")}     ${chalk.green(`"${m.secondTake.text}"`)}`
    );
    console.log();
  }

  console.log(
    `  ${chalk.dim("Original:")}  ${formatDuration(summary.originalDuration)}`
  );
  console.log(
    `  ${chalk.dim("New:     ")}  ${chalk.green(formatDuration(summary.newDuration))}`
  );
  console.log(
    `  ${chalk.dim("Saved:   ")}  ${chalk.yellow(formatDuration(summary.saved))}  ${chalk.dim(`(${summary.savedPercent.toFixed(1)}%)`)}`
  );
  console.log(`  ${chalk.dim("Cuts:    ")}  ${summary.cutCount}`);
  console.log();
}

/**
 * Print the final smartcut summary from an EditPlan: silence/retake counts and
 * the resulting keep-segment table.
 */
export function printSmartcutPreview(
  plan: EditPlan,
  keep: Segment[],
  duration: number,
  inputFile: string
): void {
  const summary = summarize(keep, duration);
  const filename = path.basename(inputFile);
  const silenceCount = plan.operations.filter(
    (op) => op.type === "removeSilence"
  ).length;
  const retakeCount = retakeOps(plan).length;

  console.log();
  console.log(chalk.bold(`smartcut plan: ${chalk.cyan(filename)}`));
  console.log();
  console.log(`  ${chalk.dim("Silence regions:")}  ${silenceCount}`);
  console.log(`  ${chalk.dim("Retakes:")}         ${retakeCount}`);
  console.log();

  // --- Retake details: show the snippet being removed vs. the one kept ---
  const retakes = retakeOps(plan);
  if (retakes.length > 0) {
    for (let i = 0; i < retakes.length; i++) {
      const op = retakes[i];
      const cutDuration = op.end - op.start;
      console.log(
        chalk.bold(`Retake ${i + 1}`) +
          `  ${chalk.dim(formatTime(op.start))} → ${chalk.dim(formatTime(op.end))}` +
          `  ${chalk.red(`-${formatDuration(cutDuration)}`)}` +
          `  ${chalk.dim("confidence")} ${formatConfidence(op.confidence)}`
      );
      console.log(`  ${chalk.dim("Remove:")}  ${chalk.red(`"${op.removedText}"`)}`);
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
    `  ${chalk.dim("Original:")}  ${formatDuration(summary.originalDuration)}`
  );
  console.log(
    `  ${chalk.dim("New:     ")}  ${chalk.green(formatDuration(summary.newDuration))}`
  );
  console.log(
    `  ${chalk.dim("Saved:   ")}  ${chalk.yellow(formatDuration(summary.saved))}  ${chalk.dim(`(${summary.savedPercent.toFixed(1)}%)`)}`
  );
  console.log(`  ${chalk.dim("Cuts:    ")}  ${summary.cutCount}`);
  console.log();
}

/**
 * Print the combined clean-cut analysis: shows silence and retake counts,
 * retake details, the merged keep-segment table, and the summary.
 */
export function printCleanPreview(
  silenceCount: number,
  matches: RetakeMatch[],
  keep: Segment[],
  duration: number,
  inputFile: string
): void {
  const summary = summarize(keep, duration);
  const filename = path.basename(inputFile);

  console.log();
  console.log(chalk.bold(`cleancut analysis: ${chalk.cyan(filename)}`));
  console.log();

  // --- Counts ---
  console.log(
    `  ${chalk.dim("Silence regions:")}  ${silenceCount}`
  );
  console.log(
    `  ${chalk.dim("Retakes found:")}    ${matches.length}`
  );
  console.log();

  // --- Retake details (only shown if there are any) ---
  if (matches.length > 0) {
    for (let i = 0; i < matches.length; i++) {
      const m = matches[i];
      const cutDuration = m.cutRegion.end - m.cutRegion.start;

      console.log(
        chalk.bold(`Retake ${i + 1}`) +
          `  ${chalk.dim(formatTime(m.cutRegion.start))} → ${chalk.dim(formatTime(m.cutRegion.end))}` +
          `  ${chalk.red(`-${formatDuration(cutDuration)}`)}`
      );
      console.log(
        `  ${chalk.dim("Match:")}    ${chalk.yellow(`"${m.matchedPhrase}"`)}`
      );
      console.log(
        `  ${chalk.dim("Removed:")}  ${chalk.red(`"${m.firstTake.text}"`)}`
      );
      console.log(
        `  ${chalk.dim("Kept:")}     ${chalk.green(`"${m.secondTake.text}"`)}`
      );
      console.log();
    }
  }

  // --- Keep-segment table (same as printPreview) ---
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
    `  ${chalk.dim("Original:")}  ${formatDuration(summary.originalDuration)}`
  );
  console.log(
    `  ${chalk.dim("New:     ")}  ${chalk.green(formatDuration(summary.newDuration))}`
  );
  console.log(
    `  ${chalk.dim("Saved:   ")}  ${chalk.yellow(formatDuration(summary.saved))}  ${chalk.dim(`(${summary.savedPercent.toFixed(1)}%)`)}`
  );
  console.log(
    `  ${chalk.dim("Cuts:    ")}  ${summary.cutCount}`
  );
  console.log();
}
