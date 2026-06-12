import { select } from "@inquirer/prompts";
import chalk from "chalk";
import { formatTime, formatDuration } from "./utils/time.js";
import { formatConfidence } from "./preview.js";
import { retakeOps, type EditPlan, type RemoveRetakeOp } from "./edit-plan.js";

export type ReviewResult = {
  plan: EditPlan;
  cancelled: boolean;
};

function printCut(op: RemoveRetakeOp, index: number, total: number): void {
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

/**
 * Build the resulting stitched text if the cut is applied: the preceding
 * sentence, the kept take (highlighted), and the following sentence.
 */
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
 * Walk the retake cuts one by one, letting the user approve or skip each.
 * Silence operations are kept as-is (not individually reviewed).
 *
 * Returns a new plan containing all silence ops plus the approved retake ops.
 * `cancelled` is true if the user aborted the whole operation.
 */
export async function reviewRetakes(plan: EditPlan): Promise<ReviewResult> {
  const retakes = retakeOps(plan);
  const silenceOps = plan.operations.filter((op) => op.type === "removeSilence");

  if (retakes.length === 0) {
    return { plan, cancelled: false };
  }

  const approved: RemoveRetakeOp[] = [];
  let approveRest = false;

  for (let i = 0; i < retakes.length; i++) {
    const op = retakes[i];
    printCut(op, i, retakes.length);

    if (approveRest) {
      approved.push(op);
      continue;
    }

    const answer = await select<"remove" | "skip" | "all" | "cancel">({
      message: "What should happen to this section?",
      choices: [
        {
          name: "Remove this section (apply cut)",
          value: "remove",
        },
        {
          name: "Keep it (skip this cut)",
          value: "skip",
        },
        {
          name: "Remove this and approve all remaining",
          value: "all",
        },
        {
          name: "Cancel (abort without rendering)",
          value: "cancel",
        },
      ],
      default: "remove",
    });

    if (answer === "cancel") {
      return { plan, cancelled: true };
    }
    if (answer === "skip") {
      continue;
    }
    if (answer === "all") {
      approveRest = true;
    }
    approved.push(op);
  }

  return {
    plan: {
      ...plan,
      operations: [...silenceOps, ...approved].sort(
        (a, b) => a.start - b.start
      ),
    },
    cancelled: false,
  };
}
