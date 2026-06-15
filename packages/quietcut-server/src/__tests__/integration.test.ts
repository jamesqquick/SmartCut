import { type ChildProcess, spawn } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { unlink } from "node:fs/promises";
import { dirname, join, resolve } from "node:path";
import { createInterface, type Interface } from "node:readline";
import type { PipelineEvent } from "quietcut-core";
import { afterAll, beforeAll, describe, expect, it } from "vitest";

// Walk up from cwd looking for a .env so the pipeline test can pick up
// Cloudflare AI Gateway creds the same way the CLI does.
(function loadNearestEnv(): void {
  let dir = process.cwd();
  while (true) {
    const candidate = join(dir, ".env");
    if (existsSync(candidate)) {
      try {
        process.loadEnvFile(candidate);
      } catch {
        /* best-effort */
      }
      return;
    }
    const parent = dirname(dir);
    if (parent === dir) return;
    dir = parent;
  }
})();

// -----------------------------------------------------------------------------
// Test harness
// -----------------------------------------------------------------------------

type PendingCall = {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
};

type EventWaiter = (event: PipelineEvent) => boolean;

class SidecarHarness {
  private nextId = 1;
  private readonly pending = new Map<number, PendingCall>();
  private readonly events: PipelineEvent[] = [];
  private readonly eventWaiters: EventWaiter[] = [];
  private readonly child: ChildProcess;
  private readonly rl: Interface;
  private exited = false;
  private stderrBuffer = "";

  constructor(serverEntry: string) {
    // Use tsx so we can run against the source files directly without
    // requiring a fresh build between test iterations.
    this.child = spawn("node", ["--import", "tsx", serverEntry], {
      stdio: ["pipe", "pipe", "pipe"],
      env: process.env,
    });

    this.child.on("exit", () => {
      this.exited = true;
      // Reject anything still pending so tests don't hang.
      for (const { reject } of this.pending.values()) {
        reject(new Error("sidecar exited"));
      }
      this.pending.clear();
    });

    this.rl = createInterface({
      input: this.child.stdout!,
      crlfDelay: Infinity,
    });
    this.rl.on("line", (line) => this.handleLine(line));

    this.child.stderr!.on("data", (chunk: Buffer) => {
      this.stderrBuffer += chunk.toString();
    });
  }

  async ready(): Promise<void> {
    // The server logs "ready" to stderr at startup. Wait for that, with
    // a short cap to avoid hanging on a broken binary.
    const deadline = Date.now() + 5_000;
    while (Date.now() < deadline) {
      if (this.stderrBuffer.includes("[quietcut-server] ready")) return;
      if (this.exited) {
        throw new Error(
          `sidecar exited before ready:\n${this.stderrBuffer || "(no stderr)"}`,
        );
      }
      await new Promise((r) => setTimeout(r, 20));
    }
    throw new Error("sidecar never logged ready");
  }

  request(method: string, params?: unknown): Promise<unknown> {
    if (this.exited) {
      return Promise.reject(new Error("sidecar has exited"));
    }
    const id = this.nextId++;
    const promise = new Promise<unknown>((resolveP, rejectP) => {
      this.pending.set(id, { resolve: resolveP, reject: rejectP });
    });
    this.child.stdin!.write(
      `${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`,
    );
    return promise;
  }

  /**
   * Resolve once an event satisfying `predicate` arrives. Consumes the
   * matched event so subsequent calls won't see it again.
   */
  waitForEvent(
    predicate: EventWaiter,
    timeoutMs = 60_000,
  ): Promise<PipelineEvent> {
    const idx = this.events.findIndex(predicate);
    if (idx !== -1) {
      const [event] = this.events.splice(idx, 1);
      return Promise.resolve(event);
    }
    return new Promise<PipelineEvent>((resolveP, rejectP) => {
      const timer = setTimeout(() => {
        const i = this.eventWaiters.indexOf(wrapped);
        if (i !== -1) this.eventWaiters.splice(i, 1);
        rejectP(new Error("waitForEvent timeout"));
      }, timeoutMs);
      const wrapped: EventWaiter = (event) => {
        if (!predicate(event)) return false;
        clearTimeout(timer);
        resolveP(event);
        return true;
      };
      this.eventWaiters.push(wrapped);
    });
  }

  close(): void {
    if (!this.exited) this.child.kill();
  }

  private handleLine(line: string): void {
    if (line.trim() === "") return;

    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      throw new Error(`sidecar sent unparseable line: ${line}`);
    }

    const message = parsed as {
      id?: number;
      result?: unknown;
      error?: { code: number; message: string };
      method?: string;
      params?: unknown;
    };

    if (typeof message.id === "number") {
      const pending = this.pending.get(message.id);
      if (!pending) return;
      this.pending.delete(message.id);
      if (message.error) {
        const err = new Error(message.error.message);
        (err as Error & { code?: number }).code = message.error.code;
        pending.reject(err);
      } else {
        pending.resolve(message.result);
      }
      return;
    }

    if (message.method === "event") {
      const event = message.params as PipelineEvent;
      // Hand to the first matching waiter, otherwise buffer.
      for (let i = 0; i < this.eventWaiters.length; i++) {
        if (this.eventWaiters[i](event)) {
          this.eventWaiters.splice(i, 1);
          return;
        }
      }
      this.events.push(event);
    }
  }
}

// -----------------------------------------------------------------------------
// Suite
// -----------------------------------------------------------------------------

const SERVER_ENTRY = resolve(__dirname, "..", "index.ts");

let harness: SidecarHarness;

beforeAll(async () => {
  harness = new SidecarHarness(SERVER_ENTRY);
  await harness.ready();
});

afterAll(() => {
  harness?.close();
});

describe("RPC primitives", () => {
  it("responds to ping", async () => {
    const result = await harness.request("ping");
    expect(result).toEqual({ pong: true });
  });

  it("returns methodNotFound for unknown methods", async () => {
    await expect(harness.request("nope")).rejects.toThrow(/Method not found/);
  });

  it("validates getMetadata params", async () => {
    await expect(harness.request("getMetadata", {})).rejects.toThrow(
      /missing params.path/,
    );
  });
});

describe("media handlers", () => {
  const FIXTURE =
    process.env.SMARTCUT_FIXTURE ??
    `${process.env.HOME}/Movies/2026-06-11 11-44-01.mov`;
  const hasFixture = existsSync(FIXTURE);

  it.skipIf(!hasFixture)(
    "getMetadata reads duration + dimensions",
    async () => {
      const md = (await harness.request("getMetadata", { path: FIXTURE })) as {
        durationSec: number;
        sizeBytes: number;
        codec?: string;
        width?: number;
        height?: number;
      };
      expect(md.durationSec).toBeGreaterThan(0);
      expect(md.sizeBytes).toBe(statSync(FIXTURE).size);
      expect(md.codec).toBeTypeOf("string");
      expect(md.width).toBeGreaterThan(0);
      expect(md.height).toBeGreaterThan(0);
    },
  );

  it.skipIf(!hasFixture)(
    "extractClip writes a wav at the expected duration",
    async () => {
      const result = (await harness.request("extractClip", {
        path: FIXTURE,
        startSec: 5,
        endSec: 7.5,
      })) as { path: string; durationSec: number };
      expect(result.durationSec).toBeCloseTo(2.5, 2);
      expect(existsSync(result.path)).toBe(true);
      // Clean up immediately rather than waiting on the 5-min TTL.
      await unlink(result.path).catch(() => undefined);
    },
  );

  it("extractClip rejects bad ranges", async () => {
    await expect(
      harness.request("extractClip", {
        path: "/does/not/matter.mov",
        startSec: 10,
        endSec: 5,
      }),
    ).rejects.toThrow(/must be greater than/);
  });
});

describe("pipeline", () => {
  const FIXTURE =
    process.env.SMARTCUT_FIXTURE ??
    `${process.env.HOME}/Movies/2026-06-11 11-44-01.mov`;
  const hasFixture = existsSync(FIXTURE);
  const hasLlmCreds = Boolean(
    process.env.CLOUDFLARE_ACCOUNT_ID &&
      (process.env.CF_AIG_TOKEN || process.env.ANTHROPIC_API_KEY),
  );
  const shouldRun = hasFixture && hasLlmCreds;

  it.skipIf(!shouldRun)(
    "runs runSmartcut end-to-end via JSON-RPC (dry-run)",
    async () => {
      const planPath = join("/tmp", `smartcut-sidecar-test-${Date.now()}.json`);
      const startResult = await harness.request("start", {
        input: FIXTURE,
        options: {
          output: "/tmp/sidecar-test-output.mp4",
          dryRun: true,
          skipApproval: true,
          savePlanPath: planPath,
          whisperModel: "base.en",
        },
      });
      expect(startResult).toMatchObject({ jobId: expect.any(String) });

      // Confirm key stage events arrive in order.
      const probeStart = await harness.waitForEvent(
        (e) =>
          e.type === "stage" && e.stage === "probe" && e.status === "start",
      );
      expect(probeStart.type).toBe("stage");

      await harness.waitForEvent(
        (e) =>
          e.type === "stage" &&
          e.stage === "extract-audio" &&
          e.status === "done",
      );

      await harness.waitForEvent((e) => e.type === "transcript");

      // For the default fixture there are no retakes, so we should reach
      // `done` without ever needing to send a `decide`. Time generously
      // for whisper + claude.
      const done = await harness.waitForEvent(
        (e) => e.type === "done",
        180_000,
      );
      expect(done.type).toBe("done");
      if (done.type === "done") {
        expect(done.savedSec).toBeGreaterThan(0);
        expect(existsSync(planPath)).toBe(true);
      }

      await unlink(planPath).catch(() => undefined);
    },
    240_000,
  );
});
