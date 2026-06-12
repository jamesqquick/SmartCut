# SmartCut — Implementation Plan

## Goal

Build a native macOS application called **SmartCut** that wraps the existing `quietcut smartcut` CLI pipeline (from `/Users/jamesqquick/code/local-video-tools`) behind a SwiftUI UI.

Scope is **personal use on James's Mac only** — no DMG, no code signing, no notarization, no Apple Developer Program enrollment in v1.

The visual reference is `docs/ui-mockup.html` (open in a browser; use the switcher to navigate the six screens).

## Non-goals (v1)

- No code signing / notarization / Gatekeeper compliance
- No DMG packaging or distribution
- No bundled Node / ffmpeg / whisper binaries (assume `brew`-installed)
- No auto-update mechanism
- No support for non-`smartcut` commands (`silence`, `retake`, `clean` come later)
- No multi-file batch processing
- No Whisper-via-API switching — keep local `whisper-cli`

## Final repo structure

```
~/code/SmartCut/
├── README.md
├── package.json                ← pnpm workspace root
├── pnpm-workspace.yaml
├── pnpm-lock.yaml
├── tsconfig.base.json
├── .gitignore
├── .env.example                ← documents required env vars
├── .nvmrc
├── docs/
│   ├── PLAN.md                 ← this file
│   ├── architecture.md         ← sidecar protocol, event types (write during Phase 2)
│   └── ui-mockup.html          ← already migrated
├── packages/
│   ├── quietcut-core/          ← migrated + refactored from local-video-tools/packages/quietcut
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   ├── tsup.config.ts
│   │   └── src/
│   │       ├── index.ts        ← public API
│   │       ├── pipeline/
│   │       │   ├── runSmartcut.ts   ← async generator yielding PipelineEvent
│   │       │   ├── events.ts        ← typed event union
│   │       │   └── decisions.ts     ← RetakeDecision types
│   │       ├── detect.ts            ← migrated
│   │       ├── edit-plan.ts         ← migrated
│   │       ├── render.ts            ← migrated
│   │       ├── segments.ts          ← migrated
│   │       ├── types.ts             ← migrated
│   │       ├── retake/              ← migrated (detect-repeats.ts, snap.ts, transcribe.ts)
│   │       ├── planners/            ← migrated (llm-retake-planner.ts, retake-planner.ts, silence-planner.ts, union.ts)
│   │       ├── llm/                 ← migrated (detect-retakes-llm.ts, gateway.ts, schema.ts)
│   │       ├── utils/               ← migrated (ffmpeg.ts, paths.ts, time.ts, whisper.ts)
│   │       └── __tests__/           ← migrated, must still pass
│   ├── quietcut-cli/           ← thin CLI wrapping quietcut-core (keeps terminal workflow alive)
│   │   ├── package.json
│   │   ├── tsconfig.json
│   │   └── src/
│   │       ├── cli.ts
│   │       └── commands/smartcut.ts ← refactored to consume pipeline events
│   └── quietcut-server/        ← Node sidecar: JSON-RPC over stdio
│       ├── package.json
│       ├── tsconfig.json
│       ├── tsup.config.ts
│       └── src/
│           ├── index.ts             ← stdio loop
│           ├── rpc.ts               ← line-delimited JSON-RPC
│           ├── audio-preview.ts     ← extractClip helper
│           └── __tests__/
└── app/
    └── SmartCut/               ← Xcode project
        ├── SmartCut.xcodeproj
        ├── SmartCut/
        │   ├── SmartCutApp.swift
        │   ├── Info.plist
        │   ├── SmartCut.entitlements
        │   ├── Assets.xcassets
        │   ├── Pipeline/
        │   │   ├── SidecarClient.swift
        │   │   ├── PipelineEvent.swift    ← Codable mirror of TS types
        │   │   └── RetakeDecision.swift
        │   ├── State/
        │   │   └── AppState.swift         ← @Observable single source of truth
        │   ├── Views/
        │   │   ├── ContentView.swift      ← routes to current screen
        │   │   ├── DropZoneView.swift
        │   │   ├── SettingsView.swift
        │   │   ├── PipelineRunningView.swift
        │   │   ├── RetakeReviewView.swift
        │   │   ├── RetakeCardView.swift
        │   │   ├── RenderProgressView.swift
        │   │   ├── DoneView.swift
        │   │   └── Sidebar/
        │   │       ├── StepperView.swift
        │   │       └── StatusPanelView.swift
        │   └── Util/
        │       ├── AudioPlayer.swift      ← wraps AVAudioPlayer
        │       └── Formatters.swift
        └── README.md                       ← how to open in Xcode + run
```

## What gets migrated from `local-video-tools`

All paths below are relative to `/Users/jamesqquick/code/local-video-tools/`.

### Into `packages/quietcut-core/src/`

Copy these files verbatim:

- `packages/quietcut/src/detect.ts`
- `packages/quietcut/src/edit-plan.ts`
- `packages/quietcut/src/preview.ts` *(some of this moves to CLI; see Phase 1.5)*
- `packages/quietcut/src/render.ts`
- `packages/quietcut/src/review.ts` *(moves to CLI in Phase 1.5)*
- `packages/quietcut/src/segments.ts`
- `packages/quietcut/src/types.ts`
- `packages/quietcut/src/llm/` (all files)
- `packages/quietcut/src/planners/` (all files)
- `packages/quietcut/src/retake/` (all files)
- `packages/quietcut/src/utils/` (all files)
- `packages/quietcut/src/__tests__/` (all files)

Also copy and adapt:
- `packages/quietcut/tsconfig.json`
- `packages/quietcut/tsup.config.ts`

### Into `packages/quietcut-cli/src/`

- `packages/quietcut/src/cli.ts` *(keep only `smartcut` registration for v1; drop silence/retake/clean)*
- `packages/quietcut/src/commands/smartcut.ts` *(refactored — see Phase 1.5)*

### Drop entirely

- `packages/scrollcap/` — out of scope
- `packages/quietcut/src/commands/{silence,retake,clean}.ts` — out of scope for v1

### Already migrated

- `tmp/smartcut-mockup.html` → `docs/ui-mockup.html` (done)

### Adapt for SmartCut

- Root `README.md`
- Root `pnpm-workspace.yaml`
- Root `package.json` workspace-level scripts

---

## Phase 1 — Refactor `quietcut-core` for embedding

**Goal:** the pipeline becomes an async generator. CLI keeps working identically.

### 1.1 — Bootstrap the workspace

- Create root `package.json` with pnpm workspace config
- Create `pnpm-workspace.yaml` listing `packages/*`
- Create `tsconfig.base.json` with shared compiler options
- Create `.nvmrc` (Node 20+, copy from local-video-tools)
- Create `.gitignore` (include `node_modules/`, `dist/`, `*.log`, `.DS_Store`, `.env`, `.env.*`, `tmp/`)
- Create `.env.example` documenting required env vars
- First commit: `chore: scaffold pnpm workspace`

### 1.2 — Copy `quietcut-core` files

- Run the migration list above
- Update `package.json` to:
  - `"name": "quietcut-core"`
  - Remove `"bin"` field
  - Remove deps: `@inquirer/prompts`, `ora`, `chalk` (chalk still useful, debatable; lean toward removing)
  - Keep all other deps
- `pnpm install`
- `pnpm --filter quietcut-core build` succeeds
- `pnpm --filter quietcut-core test` — **all existing tests must pass before any refactor**

Commit: `feat(quietcut-core): migrate source from local-video-tools` and `feat(quietcut-core): all existing tests pass after migration`.

### 1.3 — Define the event stream

Create `src/pipeline/events.ts`:

```ts
import type { Segment, Token } from "../types.js";
import type { EditPlan, RemoveRetakeOp } from "../edit-plan.js";

export type Stage =
  | "probe" | "extract-audio" | "silence-coarse" | "silence-fine"
  | "transcribe" | "detect-retakes" | "review" | "render";

export type PipelineEvent =
  | { type: "stage"; stage: Stage; status: "start" | "done" | "fail"; message?: string; durationMs?: number }
  | { type: "progress"; stage: Stage; current?: number; total?: number; percent?: number; note?: string }
  | { type: "metadata"; durationSec: number; sizeBytes: number; codec?: string; width?: number; height?: number }
  | { type: "silenceFound"; count: number; segments: Segment[] }
  | { type: "transcript"; tokenCount: number; preview: string }
  | { type: "retakeProposed"; opId: string; op: RemoveRetakeOp; index: number; total: number }
  | { type: "retakeDecision"; opId: string; action: "remove" | "keep" }
  | { type: "renderProgress"; frame?: number; fps?: number; speed?: number; percent?: number; etaSec?: number }
  | { type: "done"; plan: EditPlan; output: string; savedSec: number; savedPercent: number; elapsedSec: number }
  | { type: "error"; message: string; stage?: Stage; stack?: string };
```

Create `src/pipeline/decisions.ts`:

```ts
export type RetakeDecision =
  | { kind: "remove" }
  | { kind: "keep" }
  | { kind: "approveRest" }
  | { kind: "cancel" };
```

Commit: `feat(quietcut-core): add pipeline event types`.

### 1.4 — Extract orchestration

Create `src/pipeline/runSmartcut.ts`. It's a near-copy of the body of the original `commands/smartcut.ts` (lines 97–328) with these transformations:

- Function signature:
  ```ts
  export async function* runSmartcut(
    config: SmartcutConfig,
    whisperModel: string
  ): AsyncGenerator<PipelineEvent, void, RetakeDecision | undefined>
  ```
- Every `ora(...)` becomes `yield { type: "stage", ... start }` / `... done`
- Every `console.log` of structured info becomes a `yield`
- The block that calls `select()` (currently in `review.ts`) is replaced inline by:
  ```ts
  for (let i = 0; i < retakes.length; i++) {
    const op = retakes[i];
    const decision = yield {
      type: "retakeProposed",
      opId: `r-${i}`,
      op, index: i, total: retakes.length
    };
    if (!decision || decision.kind === "cancel") return;
    if (decision.kind === "keep") continue;
    if (decision.kind === "approveRest") {
      approved.push(...retakes.slice(i));
      break;
    }
    approved.push(op);
  }
  ```
- `process.exit` is replaced by `yield { type: "error", ... }; return;`
- Render-progress reporting: `render.ts` currently shells out to ffmpeg. Add an optional `onProgress` callback param so the pipeline can `yield` progress as ffmpeg emits frames. Use `-progress pipe:1` for clean parsing.

Export public API from `src/index.ts`:

```ts
export { runSmartcut } from "./pipeline/runSmartcut.js";
export type { PipelineEvent, Stage } from "./pipeline/events.js";
export type { RetakeDecision } from "./pipeline/decisions.js";
export * from "./edit-plan.js";
export * from "./types.js";
```

Commit: `refactor(quietcut-core): extract runSmartcut async generator`.

### 1.5 — Refactor CLI as consumer

Create `packages/quietcut-cli/` with `src/commands/smartcut.ts` that:

- Parses options identically (commander)
- Calls `runSmartcut(config)` and consumes the generator
- On `stage:start` → `ora().start()`; on `stage:done` → `spinner.succeed()`; on `stage:fail` → `spinner.fail()`
- On `retakeProposed` → render the existing `@inquirer/prompts` review card (port logic from old `review.ts`), capture decision, pass back via `gen.next(decision)`
- On `done` → print the existing summary block

CLI keeps `@inquirer/prompts`, `ora`, `chalk` as deps. Core drops them.

Commit: `feat(quietcut-cli): consume runSmartcut, restore CLI behavior`.

### 1.6 — Verification gate

- All existing `__tests__/` pass
- Running `pnpm --filter quietcut-cli dev smartcut <existing test mp4>` produces functionally-equivalent output to the pre-refactor CLI (use a small fixture from the original repo or record a fresh one)
- Save the test fixture in `packages/quietcut-core/__fixtures__/` for repeat verification

Commit: `test(quietcut-core): verification fixture vs legacy CLI`.

**This phase must land green before Phase 2 starts.**

---

## Phase 2 — `quietcut-server` sidecar

### 2.1 — RPC protocol

Newline-delimited JSON over stdio. Each line is one JSON message. All sidecar logging goes to **stderr** to avoid corrupting the protocol stream on stdout.

**Client → server (requests):**

```jsonc
{"jsonrpc":"2.0","id":1,"method":"getMetadata","params":{"path":"/Users/.../in.mp4"}}
{"jsonrpc":"2.0","id":2,"method":"start","params":{"input":"/path","options":{...SmartcutConfig}}}
{"jsonrpc":"2.0","id":3,"method":"decide","params":{"opId":"r-7","action":"remove"}}
{"jsonrpc":"2.0","id":4,"method":"cancel"}
{"jsonrpc":"2.0","id":5,"method":"extractClip","params":{"path":"/path","startSec":134.32,"endSec":138.18}}
```

**Server → client (responses):** standard JSON-RPC 2.0 result/error keyed by id.

**Server → client (notifications):** no id; `method: "event"`; `params` is a `PipelineEvent`.

### 2.2 — Implementation

- `src/index.ts`: spawn-safe stdio reader (`readline` on `process.stdin`); writer that JSON-stringifies + `\n` to `process.stdout`
- `src/rpc.ts`: dispatcher mapping method names to handlers; pending request tracking via a Map keyed by id
- `start` handler runs `runSmartcut` in a background async task; events get serialized as notifications; decisions arrive via `decide` and are pushed into a queue that the generator awaits
- `cancel` resolves the queue with `{ kind: "cancel" }` and aborts in-flight ffmpeg/whisper child processes (track them in a `Set<ChildProcess>`)
- `audio-preview.ts`: `extractClip(input, startSec, endSec)` → shell out `ffmpeg -ss S -to E -i input -vn -c:a pcm_s16le /tmp/smartcut-<uuid>.wav`, return path. Schedule cleanup after 5 minutes (`setTimeout` + `fs.unlink`)

Commits:
- `feat(quietcut-server): JSON-RPC stdio sidecar skeleton`
- `feat(quietcut-server): wire start/decide/cancel handlers`
- `feat(quietcut-server): extractClip handler for audio preview`

### 2.3 — Test harness

Write a Node test driver in `__tests__/integration.test.ts` that:

- Spawns the sidecar as a child process
- Sends `getMetadata` then `start` for a tiny fixture mp4
- Asserts the event sequence matches expectations
- Sends `decide` messages to walk through any retake proposals
- Confirms a `done` event arrives and the output file exists

This becomes the contract test for the protocol — Swift will speak the same wire format.

Commit: `test(quietcut-server): integration test driving full pipeline`.

### 2.4 — Bundle for Swift consumption

- `tsup.config.ts`: bundle to a single CJS file at `dist/server.cjs` with all deps inlined
- Swift will launch this with `node /path/to/server.cjs`

### 2.5 — Document the protocol

Write `docs/architecture.md` capturing:

- The full RPC schema (request methods, response shapes)
- The event union with examples
- Lifecycle diagram (Swift spawns sidecar → handshake → start job → events flow → decide messages → done → tear down)
- How cancellation propagates

---

## Phase 3 — SwiftUI app

### 3.1 — Xcode project setup

- Create `app/SmartCut/SmartCut.xcodeproj` (macOS app, SwiftUI lifecycle, min target macOS 14)
- Set bundle ID to `dev.jamesqquick.smartcut`
- Disable sandboxing in `SmartCut.entitlements` (we need to spawn Node and read arbitrary files; v1 is local-only so this is fine)
- App icon: placeholder

Commit: `feat(app): scaffold Xcode project`.

### 3.2 — Wire format mirror in Swift

`Pipeline/PipelineEvent.swift` — Codable struct/enum matching `events.ts`:

```swift
enum PipelineEvent: Codable {
    case stage(stage: Stage, status: StageStatus, message: String?, durationMs: Int?)
    case progress(stage: Stage, percent: Double?, note: String?)
    case metadata(durationSec: Double, sizeBytes: Int, codec: String?)
    case silenceFound(count: Int, segments: [Segment])
    case transcript(tokenCount: Int, preview: String)
    case retakeProposed(opId: String, op: RemoveRetakeOp, index: Int, total: Int)
    case renderProgress(percent: Double?, etaSec: Double?, fps: Double?, frame: Int?)
    case done(output: String, savedSec: Double, savedPercent: Double, elapsedSec: Double)
    case error(message: String, stage: Stage?)

    // custom decoding keyed on `type` discriminator
}
```

`Pipeline/RetakeDecision.swift` — Codable mirror.

Commit: `feat(app): SidecarClient + PipelineEvent codec`.

### 3.3 — SidecarClient

`Pipeline/SidecarClient.swift`:

- Owns a `Process` instance + `Pipe` for stdin/stdout/stderr
- Spawns `node` from a configurable path (default: resolves `which node` at launch; reads override from `~/.smartcut/config.json`)
- Reads stdout line-by-line on a background queue, decodes each line as either a JSON-RPC response or a `{method: "event"}` notification
- Posts events to `AppState` on `@MainActor`
- Tracks pending RPC requests with `[Int: CheckedContinuation<JSONValue, Error>]`
- Methods: `getMetadata(url:)`, `start(url:options:)`, `decide(opId:action:)`, `cancel()`, `extractClip(url:startSec:endSec:)`

### 3.4 — App state

`State/AppState.swift`:

```swift
@MainActor @Observable
final class AppState {
    enum Screen { case drop, settings, running, review, render, done }
    var screen: Screen = .drop
    var droppedFile: URL?
    var metadata: VideoMetadata?
    var options: SmartcutOptions = .defaults
    var stages: [Stage: StageStatus] = [:]
    var activityLog: [LogLine] = []
    var pendingRetakes: [RetakeProposal] = []
    var currentRetakeIndex: Int = 0
    var renderProgress: Double = 0
    var renderEta: TimeInterval?
    var renderStats: RenderStats?
    var summary: DoneSummary?
    var errorMessage: String?

    let sidecar: SidecarClient
    init() { ... }

    func handleDrop(_ url: URL) async { ... }
    func startProcessing() async { ... }
    func decide(_ action: RetakeAction) { ... }
    func cancel() { ... }
}
```

Commit: `feat(app): AppState + ContentView routing`.

### 3.5 — Views

Each view in the mockup gets a SwiftUI implementation:

| Mockup screen | SwiftUI view | Commit |
|---|---|---|
| Drop file | `DropZoneView` | `feat(app): DropZoneView + getMetadata wiring` |
| Settings | `SettingsView` | `feat(app): SettingsView bound to AppState.options` |
| Pipeline running | `PipelineRunningView` | `feat(app): PipelineRunningView with live activity log` |
| Review retakes | `RetakeReviewView` → `RetakeCardView` | `feat(app): RetakeReviewView + RetakeCardView` |
| Rendering | `RenderProgressView` | `feat(app): RenderProgressView with ffmpeg stats` |
| Done | `DoneView` | `feat(app): DoneView with Reveal in Finder + Open` |

Sidebar: `StepperView` reading `AppState.stages`; `StatusPanelView` reading running-tally state.

`ContentView` is a single switch on `appState.screen`.

### 3.6 — Audio preview

`Util/AudioPlayer.swift`:

- Calls `sidecar.extractClip(url, startSec, endSec)` to get a temp WAV path
- Loads into `AVAudioPlayer`
- Exposes `play()`, `pause()`, `isPlaying`, `progress`
- Used by `RetakeCardView` for the two preview buttons (removed clip + stitched preview)

For the "stitched preview" button: concatenate the few seconds before the cut + the kept segment + the few seconds after, with the removed range elided. Implement via a sidecar method `extractStitchedClip(opId)` or compute the segment list in Swift and call multiple `extractClip`s.

Commit: `feat(app): AudioPlayer + extractClip wiring`.

### 3.7 — Keyboard shortcuts

On `RetakeReviewView`:

- `.keyboardShortcut("r")` → remove
- `.keyboardShortcut("k")` → keep
- `.keyboardShortcut("a")` → approve all
- `.keyboardShortcut(.escape)` → cancel

Commit: `feat(app): keyboard shortcuts (R/K/A/Esc)`.

---

## Phase 4 — Integration + polish

### 4.1 — Sidecar discovery + config

- App reads `~/.smartcut/config.json` for `nodePath`, `ffmpegPath`, `whisperPath`, `cloudflareAccountId`, `cfAigToken`, `anthropicApiKey`
- If config missing or fields missing, show a first-run settings sheet that collects them
- These env vars are passed to the sidecar process's environment so the existing `gateway.ts` env-resolution keeps working

### 4.2 — Settings persistence

- `~/Library/Application Support/SmartCut/preferences.json` for non-secret defaults (threshold, model, passes, lead-in/tail-out, output dir, last-used preset)
- Secrets live in `~/.smartcut/config.json` for v1 (Keychain comes later)

### 4.3 — Error UX

- Banner with "Show details" expander that reveals last 20 events from the activity log
- "Restart sidecar" button for the inevitable hung-process case
- Sidecar crash detection: if the `Process` terminates unexpectedly during a run, surface the stderr tail to the user

Commit: `feat(app): first-run config sheet, preferences persistence` and `feat(app): error banner + restart sidecar`.

### 4.4 — Reveal in Finder / Open output

- `NSWorkspace.shared.activateFileViewerSelecting([url])` for reveal
- `NSWorkspace.shared.open(url)` for open

### 4.5 — Manual test pass against the mockup

For each of the six screens in `docs/ui-mockup.html`, verify the live SwiftUI build matches structurally (don't need pixel-perfect; needs to feel the same).

### 4.6 — README

Write the top-level `README.md` with:

- What SmartCut is
- Prerequisites (Xcode 15+, Node 20+, `brew install ffmpeg whisper-cpp`, pnpm, `.env`)
- How to build the TS workspace (`pnpm install && pnpm build`)
- How to open the Xcode project and run
- How to update env vars

Commit: `docs: README + how to run locally`.

---

## Sequenced commits (full list)

1. `chore: scaffold pnpm workspace and tsconfig`
2. `feat(quietcut-core): migrate source from local-video-tools`
3. `feat(quietcut-core): all existing tests pass after migration`
4. `feat(quietcut-core): add pipeline event types`
5. `refactor(quietcut-core): extract runSmartcut async generator`
6. `feat(quietcut-cli): consume runSmartcut, restore CLI behavior`
7. `test(quietcut-core): verification fixture vs legacy CLI`
8. `feat(quietcut-server): JSON-RPC stdio sidecar skeleton`
9. `feat(quietcut-server): wire start/decide/cancel handlers`
10. `feat(quietcut-server): extractClip handler for audio preview`
11. `test(quietcut-server): integration test driving full pipeline`
12. `docs: sidecar protocol in architecture.md`
13. `feat(app): scaffold Xcode project`
14. `feat(app): SidecarClient + PipelineEvent codec`
15. `feat(app): AppState + ContentView routing`
16. `feat(app): DropZoneView + getMetadata wiring`
17. `feat(app): SettingsView bound to AppState.options`
18. `feat(app): PipelineRunningView with live activity log`
19. `feat(app): RetakeReviewView + RetakeCardView`
20. `feat(app): AudioPlayer + extractClip wiring`
21. `feat(app): keyboard shortcuts (R/K/A/Esc)`
22. `feat(app): RenderProgressView with ffmpeg stats`
23. `feat(app): DoneView with Reveal in Finder + Open`
24. `feat(app): first-run config sheet, preferences persistence`
25. `feat(app): error banner + restart sidecar`
26. `docs: README + how to run locally`

---

## Validation criteria for v1 complete

- [ ] Dragging an mp4 onto the SmartCut window loads it, shows metadata, transitions to Settings
- [ ] Clicking Start runs the full pipeline; activity log mirrors stages in real time
- [ ] Each retake proposal appears as a card with removed text, reason, stitched preview, and two audio buttons
- [ ] Audio preview plays both the removed clip and the stitched result
- [ ] R/K/A/Esc keyboard shortcuts work
- [ ] Render progress updates live with frame count + ETA
- [ ] Done screen shows accurate summary; Reveal in Finder opens the output
- [ ] Cancelling at any stage cleanly tears down ffmpeg/whisper subprocesses
- [ ] Full `quietcut-core` test suite still passes
- [ ] CLI still works identically (regression check via fixture)

---

## Prerequisites the new agent should assume

- macOS 14+ host (Sonoma)
- Xcode 15+ installed
- Node 20+ on PATH
- `brew install ffmpeg whisper-cpp` already done — **verified**: `/opt/homebrew/bin/ffmpeg` and `/opt/homebrew/bin/whisper-cli` exist on James's machine
- `pnpm` available globally
- `.env` with `CLOUDFLARE_ACCOUNT_ID`, `CF_AIG_GATEWAY_ID=default`, and either `ANTHROPIC_API_KEY` or `CF_AIG_TOKEN` — **ask James to copy these from `/Users/jamesqquick/code/local-video-tools/.env`** (do not auto-copy; secrets handling is explicit)

---

## Open decisions for the new agent

1. **Whisper model location:** `whisper-cli` needs a model file path. The current CLI defaults to `--whisper-model base.en`. Ask James where the model file lives on his machine and surface it in settings.
2. **Render progress events from ffmpeg:** parse stderr with regex or use `-progress pipe:1`? Recommend `-progress` for cleaner parsing.
3. **Sidecar launch timing:** spawn at app launch or on first job? Recommend on first job to keep cold start fast.
4. **Cancellation depth:** if ffmpeg is mid-render when user cancels, do we keep the partial output? Recommend deleting it.
5. **Stitched preview generation:** sidecar-side concat into one WAV vs. client-side multi-clip playback. Recommend sidecar-side for simpler Swift code.

---

## Files the new agent has access to

- This plan: `~/code/SmartCut/docs/PLAN.md`
- The visual mockup: `~/code/SmartCut/docs/ui-mockup.html`
- Source repo to migrate from: `/Users/jamesqquick/code/local-video-tools/`
- Existing env vars: `/Users/jamesqquick/code/local-video-tools/.env` (James must opt in to copying)

---

## Architecture in one sentence

SwiftUI app ↔ (JSON-RPC over stdio) ↔ Node sidecar ↔ `runSmartcut` async generator ↔ (ffmpeg + whisper-cli + Claude via Cloudflare AI Gateway).
