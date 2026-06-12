import { Command } from "commander";
import chalk from "chalk";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { smartcutCommand } from "./commands/smartcut.js";

/**
 * Load the nearest `.env` by walking up from the current working directory
 * (Node 20.12+ / 22 built-in). Finds a repo-root .env even when the command
 * runs from a subpackage (e.g. `pnpm --filter quietcut-cli dev`).
 */
function loadNearestEnv(): void {
  let dir = process.cwd();
  while (true) {
    const candidate = join(dir, ".env");
    if (existsSync(candidate)) {
      try {
        process.loadEnvFile(candidate);
      } catch {
        // Unreadable — fall back to the ambient environment.
      }
      return;
    }
    const parent = dirname(dir);
    if (parent === dir) return;
    dir = parent;
  }
}

loadNearestEnv();

const program = new Command();

program
  .name("quietcut")
  .description("SmartCut CLI — smartcut pipeline (silence + retake cuts)")
  .version("0.1.0");

program.addCommand(smartcutCommand);

program.parseAsync(process.argv).catch((err: Error) => {
  console.error(chalk.red(err.message));
  process.exit(1);
});
