import * as readline from "node:readline";
import {
  parseRpcLine,
  RPC_ERROR,
  RpcDispatcher,
  RpcDispatchError,
  type RpcNotification,
  type RpcResponse,
} from "./rpc.js";
import { getMetadata } from "./metadata.js";

// -----------------------------------------------------------------------------
// Wire layer: write only protocol messages to stdout, everything else to stderr.
// -----------------------------------------------------------------------------

function logInfo(msg: string): void {
  process.stderr.write(`[quietcut-server] ${msg}\n`);
}

function logError(err: unknown): void {
  const msg = err instanceof Error ? err.stack ?? err.message : String(err);
  process.stderr.write(`[quietcut-server] ERROR: ${msg}\n`);
}

function send(message: RpcResponse | RpcNotification): void {
  process.stdout.write(JSON.stringify(message) + "\n");
}

// -----------------------------------------------------------------------------
// Handlers (skeleton — full set of methods is wired in subsequent commits).
// -----------------------------------------------------------------------------

const dispatcher = new RpcDispatcher();

dispatcher.register("ping", async () => ({ pong: true }));

dispatcher.register("getMetadata", async (params) => {
  const p = params as { path?: string } | undefined;
  if (!p?.path) {
    throw new RpcDispatchError(RPC_ERROR.invalidParams, "missing params.path");
  }
  return await getMetadata(p.path);
});

// -----------------------------------------------------------------------------
// Stdio loop.
// -----------------------------------------------------------------------------

const inFlight = new Set<Promise<unknown>>();

async function handleLine(line: string): Promise<void> {
  const parsed = parseRpcLine(line);
  if (!parsed) return;
  if (parsed.kind === "error") {
    send(parsed.response);
    return;
  }
  const response = await dispatcher.dispatch(parsed.request);
  send(response);
}

function trackInFlight(p: Promise<unknown>): void {
  inFlight.add(p);
  p.finally(() => inFlight.delete(p));
}

async function drainInFlight(): Promise<void> {
  while (inFlight.size > 0) {
    await Promise.allSettled([...inFlight]);
  }
}

function main(): void {
  process.on("uncaughtException", (err) => logError(err));
  process.on("unhandledRejection", (err) => logError(err));

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.on(signal, () => {
      logInfo(`received ${signal}, shutting down`);
      drainInFlight().finally(() => process.exit(0));
    });
  }

  const rl = readline.createInterface({
    input: process.stdin,
    crlfDelay: Infinity,
  });
  rl.on("line", (line) => {
    trackInFlight(handleLine(line).catch((err) => logError(err)));
  });
  rl.on("close", () => {
    logInfo("stdin closed, draining and exiting");
    drainInFlight().finally(() => process.exit(0));
  });

  logInfo("ready");
}

main();
