import { select } from "@inquirer/prompts";
import chalk from "chalk";
import type { RemoveRetakeOp, RetakeDecision } from "quietcut-core";
import { formatConfidence, formatDuration, formatTime } from "./preview.js";

/**
 * Render a single retake cut card.
 * Ported from packages/quietcut/src/review.ts.
 */
export function printCut(op: RemoveRetakeOp, index: number, total: number): void {
  const dur = op.end - op.start;
  console.log();
  console.log(
    chalk.bold(`Cut ${index + 1}/${total}`) +
      `  ${chalk.dim(formatTime(op.start))} → ${chalk.dim(formatTime(op.end))}` +
      `  ${chalk.red(`-${formatDuration(dur)}`)}` +
      `  ${chalk.dim("confidence")} ${formatConfidence(op.confidence)}`
  );
  console.log(`  ${chalk.dim("Remove:")}  ${chalk.red(`"${op.removedText}"`)}`);
  console.log(`  ${chalk.dim("Reason:")}  ${chalk.dim(op.reason)}`);
  console.log(`  ${chalk.dim("Result if removed:")}`);
  console.log(`    ${formatStitchedResult(op)}`);
}

function formatStitchedResult(op: RemoveRetakeOp): string {
  const before = op.contextBefore ?? "";
  const after = op.contextAfter ?? "";
  return [
    before ? chalk.dim(`…${before}`) : "",
    chalk.green(op.keptText),
    after ? chalk.dim(`${after}…`) : "",
  ]
    .filter(Boolean)
    .join(" ");
}

/**
 * Prompt the user for what to do with a single retake.
 * Returns a `RetakeDecision` to push back into the runSmartcut generator.
 */
export async function promptRetakeDecision(): Promise<RetakeDecision> {
  const answer = await select<"remove" | "skip" | "all" | "cancel">({
    message: "What should happen to this section?",
    choices: [
      { name: "Remove this section (apply cut)", value: "remove" },
      { name: "Keep it (skip this cut)", value: "skip" },
      { name: "Remove this and approve all remaining", value: "all" },
      { name: "Cancel (abort without rendering)", value: "cancel" },
    ],
    default: "remove",
  });

  switch (answer) {
    case "remove":
      return { kind: "remove" };
    case "skip":
      return { kind: "keep" };
    case "all":
      return { kind: "approveRest" };
    case "cancel":
      return { kind: "cancel" };
  }
}
