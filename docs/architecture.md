# SmartCut Architecture

This doc captures the wire contract between the SwiftUI app and the
`quietcut-server` Node sidecar. It's the source of truth for both sides;
update it when the protocol changes.

## Process layout

```
┌──────────────────────────────────┐        stdio (JSON lines)        ┌──────────────────────────────────┐
│      SmartCut.app (Swift)        │  ─────────────────────────────▶  │   quietcut-server (Node sidecar) │
│  ┌────────────────────────────┐  │           requests               │  ┌────────────────────────────┐  │
│  │  SidecarClient.swift       │  │  ◀─────────────────────────────  │  │  index.ts                  │  │
│  │  PipelineEvent.swift       │  │     responses + notifications    │  │  rpc.ts                    │  │
│  │  AppState.swift            │  │                                  │  │  runSmartcut (core)        │  │
│  └────────────────────────────┘  │                                  │  └────────────────────────────┘  │
└──────────────────────────────────┘                                  └──────────────┬───────────────────┘
                                                                                     │  spawns
                                                                                     ▼
                                                                    ┌─────────────────────────────────┐
                                                                    │  ffmpeg / whisper-cli /         │
                                                                    │  Anthropic Claude (via CF AI    │
                                                                    │  Gateway, HTTPS)                │
                                                                    └─────────────────────────────────┘
```

Swift spawns the sidecar with `node /path/to/quietcut-server/dist/server.cjs`.
The sidecar opens `readline` on stdin and writes line-delimited JSON to
stdout. Every line on stdout is a complete JSON object; any free-form
diagnostic output goes to stderr.

## Wire format

Line-delimited JSON-RPC 2.0. One JSON object per line, terminated by `\n`.

### Requests (client → server)

```jsonc
{ "jsonrpc": "2.0", "id": <number|string>, "method": <string>, "params": <object?> }
```

`id` must be unique per outstanding request. Notifications from the
client (id absent) are **not supported** — the server returns an
`invalidRequest` error.

### Responses (server → client)

Success:
```jsonc
{ "jsonrpc": "2.0", "id": <same as request>, "result": <any> }
```

Error:
```jsonc
{ "jsonrpc": "2.0", "id": <same as request|null>, "error": { "code": <number>, "message": <string>, "data": <any?> } }
```

### Notifications (server → client)

The server emits unsolicited pipeline events as notifications (no `id`):

```jsonc
{ "jsonrpc": "2.0", "method": "event", "params": <PipelineEvent> }
```

See `PipelineEvent` below.

## RPC methods

### `ping`

Health check.

- Params: none
- Returns: `{ "pong": true }`

### `getMetadata`

Read media metadata for the drop-zone preview.

- Params: `{ "path": string }`
- Returns:
  ```jsonc
  {
    "durationSec": number,
    "sizeBytes": number,
    "codec": string?,
    "width": number?,
    "height": number?
  }
  ```
- Errors: `invalidParams` (missing `path`), `internalError` (file not
  found, ffprobe failed).

### `extractClip`

Render a short PCM WAV from `path` between `startSec` and `endSec` for
audio preview in the retake review UI.

- Params: `{ "path": string, "startSec": number, "endSec": number }`
- Returns: `{ "path": string, "durationSec": number }`
- Errors: `invalidParams` (missing fields, `endSec <= startSec`,
  non-finite numbers), `internalError` (ffmpeg failure).

The output file lives at `$TMPDIR/smartcut-previews/clip-<uuid>.wav`. It
is automatically unlinked 5 minutes after creation (`setTimeout` with
`.unref()`).

### `extractStitchedClip`

Render a "stitched preview" — the audio that would result if a proposed
retake cut were applied. Used by the retake review card's `Play
stitched preview` button.

- Params:
  ```jsonc
  {
    "path": string,        // input media file
    "removeStart": number, // seconds, start of the cut
    "removeEnd": number,   // seconds, end of the cut
    "padSec": number?,     // seconds of context BEFORE the cut (default 1.5)
    "tailSec": number?     // seconds AFTER the cut (default 4.0)
  }
  ```
- Returns: `{ "path": string, "durationSec": number }`
- Errors: `invalidParams` (`removeEnd <= removeStart`), `internalError`
  (ffmpeg failure).

Output file lives at `$TMPDIR/smartcut-previews/stitched-<uuid>.wav` and
uses the same 5-minute TTL as `extractClip`.

### `start`

Begin a smartcut run. Resolves **immediately** with an opaque job
identifier; pipeline progress flows asynchronously through `event`
notifications. The job is considered complete when a `done` or `error`
event arrives.

- Params:
  ```jsonc
  {
    "input": string,
    "options": {
      "output": string,              // required
      "thresholdDb": number?,        // default -30
      "minSilence": number?,         // default 0.6
      "model": string?,              // default "claude-opus-4-8"
      "maxRetakeRatio": number?,     // default 15
      "passes": number?,             // default 2
      "whisperModel": string?,       // default "base.en"
      "transcriptPath": string?,
      "saveTranscriptPath": string?,
      "planPath": string?,
      "savePlanPath": string?,
      "leadInMs": number?,           // default 300
      "tailOutMs": number?,          // default 300
      "skipApproval": boolean?,      // default false
      "dryRun": boolean?,            // default false
      "crf": number?,                // default 18
      "preset": string?              // default "medium"
    }
  }
  ```
- Returns: `{ "jobId": "current" }` (the sidecar runs at most one job at
  a time; the literal `"current"` is reserved for the only valid id).
- Errors:
  - `jobAlreadyRunning` (-32001) if a job is already in flight.
  - `invalidParams` if `input` or `options.output` is missing.

### `decide`

Push a decision into the active job in response to a `retakeProposed`
event. The server queues decisions, so it is safe to send `decide`
before the next `retakeProposed` arrives — the queue is drained
in-order.

- Params:
  ```jsonc
  { "opId": string, "action": "remove" | "keep" | "approveRest" | "cancel" }
  ```
- Returns: `{ "ok": true }`
- Errors: `jobNotRunning` (-32002), `invalidParams`.

### `cancel`

Abort the active job. Equivalent to sending a `cancel` decision: the
generator returns at its next yield point. Mid-stage ffmpeg/whisper
processes are not yet hard-killed (Phase 2 follow-up).

- Params: none
- Returns: `{ "ok": true, "wasRunning": boolean }`

## `PipelineEvent` discriminated union

Each notification carries one of these shapes in `params`. The full type
lives in `packages/quietcut-core/src/pipeline/events.ts`; Swift mirrors
it in `Pipeline/PipelineEvent.swift`.

| `type`              | Fields                                                                                          | Meaning                                                                 |
| ------------------- | ----------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------- |
| `stage`             | `stage`, `status` (`start`\|`done`\|`fail`), `message?`, `durationMs?`                          | A pipeline stage transitioned.                                          |
| `progress`          | `stage`, `current?`, `total?`, `percent?`, `note?`                                              | Intra-stage progress note.                                              |
| `metadata`          | `durationSec`, `sizeBytes`, `codec?`, `width?`, `height?`                                       | Emitted once during `probe` so the UI can render the media card early.  |
| `silenceFound`      | `count`, `segments`                                                                             | Coarse silence detection completed.                                     |
| `transcript`        | `tokenCount`, `preview`                                                                         | Whisper transcript produced. `preview` currently carries the full text. |
| `retakeProposed`    | `opId`, `op`, `index`, `total`                                                                  | Server is waiting for a `decide` RPC with this `opId`.                  |
| `retakeDecision`    | `opId`, `action`                                                                                | Server confirms the decision was applied (mirrors the client's choice). |
| `renderProgress`    | `frame?`, `fps?`, `speed?`, `percent?`, `etaSec?`                                               | ffmpeg `-progress pipe:1` update. Multiple per second.                  |
| `done`              | `plan`, `output`, `savedSec`, `savedPercent`, `elapsedSec`                                      | Job finished. `output` is `""` for dry-runs.                            |
| `error`             | `message`, `stage?`, `stack?`                                                                   | Unrecoverable failure. The job has ended.                               |

### `Stage` enum

`probe`, `extract-audio`, `silence-coarse`, `silence-fine`, `transcribe`,
`detect-retakes`, `review`, `render`.

## Stage sequence

```
probe ─▶ extract-audio ─▶ silence-coarse ─▶ silence-fine ─▶ transcribe ─▶ detect-retakes ─▶ review ─▶ render ─▶ done
                                                                                                ▲
                                                                  retakeProposed/decide loop ──┘
```

- `silence-fine` is best-effort; failure is non-fatal and emitted as a
  `done` status with `message: "Snap detection skipped."`.
- `review` is skipped when `skipApproval=true` or when there are zero
  retakes.
- `render` is skipped when `dryRun=true`; the `done` event carries
  `output: ""`.

## Error code table

| Code     | Name               | Meaning                                                |
| -------- | ------------------ | ------------------------------------------------------ |
| -32700   | parseError         | stdin line was not valid JSON.                         |
| -32600   | invalidRequest     | Missing `jsonrpc`/`method`, bad `id`, or a notification. |
| -32601   | methodNotFound     | Unknown method.                                        |
| -32602   | invalidParams      | Required field missing or wrong type.                  |
| -32603   | internalError      | Unexpected exception in a handler.                     |
| -32001   | jobAlreadyRunning  | `start` called while a job is in flight.               |
| -32002   | jobNotRunning      | `decide` called with no active job.                    |
| -32003   | cancelled          | (Reserved; not currently emitted.)                     |

## Lifecycle

```
   Swift                          Sidecar
     │                               │
     │  spawn(node server.cjs)       │
     │ ───────────────────────────▶ │   stderr: "[quietcut-server] ready"
     │                               │
     │  getMetadata(path)            │
     │ ───────────────────────────▶ │
     │ ◀──────────────────────────  │   result: { durationSec, ... }
     │                               │
     │  start(input, options)        │
     │ ───────────────────────────▶ │
     │ ◀──────────────────────────  │   result: { jobId: "current" }
     │                               │
     │ ◀──────────────────────────  │   event: stage(probe, start)
     │ ◀──────────────────────────  │   event: metadata(...)
     │ ◀──────────────────────────  │   event: stage(probe, done)
     │              ...              │
     │ ◀──────────────────────────  │   event: retakeProposed(r-0, ...)
     │  decide(r-0, remove)          │
     │ ───────────────────────────▶ │
     │ ◀──────────────────────────  │   result: { ok: true }
     │              ...              │
     │ ◀──────────────────────────  │   event: renderProgress(percent: 42.3, ...)
     │              ...              │
     │ ◀──────────────────────────  │   event: done(output, savedSec, ...)
     │                               │
     │  (optional: another start)    │
     │              ...              │
     │  close stdin / SIGTERM        │
     │ ───────────────────────────▶ │   drain in-flight, exit(0)
```

The sidecar is **long-lived**: it stays up after `done` and can accept
another `start`. The client tears it down by closing stdin or sending
`SIGTERM`. Both trigger a graceful drain.

## Cancellation semantics

1. Client sends `cancel`.
2. Server sets a flag and pushes `{ kind: "cancel" }` onto the decision
   queue.
3. The generator picks up the decision at its next yield point.
   - During retake review: returns immediately.
   - Mid-stage (ffmpeg, whisper, LLM): the stage completes first, then
     the cancel takes effect on the next yield.
4. The generator emits no `done`; instead the `stage` event for `review`
   reports `fail` with `message: "Cancelled."`.
5. The server resets `activeJob` to `null`. The client is free to call
   `start` again.

Hard-killing in-flight ffmpeg/whisper child processes is a v1
follow-up. For now, expect up to a few seconds of latency between
`cancel` and the job actually winding down.

## Process hygiene

- All non-protocol output goes to stderr, prefixed with `[quietcut-server]`.
  Anything written to stdout that is not valid JSON will crash the
  client's line parser, so this rule is strict.
- `uncaughtException` and `unhandledRejection` are logged to stderr and
  do **not** terminate the process — the client should still be able to
  read the error and decide what to do.
- SIGINT/SIGTERM trigger a graceful drain: any in-flight RPC handlers
  finish, the active job is sent a cancel decision, and the process
  exits with code 0.
- stdin closing triggers the same drain path.

## Where the types live

| Concept           | TypeScript                                                  | Swift (Phase 3)                  |
| ----------------- | ----------------------------------------------------------- | -------------------------------- |
| `PipelineEvent`   | `packages/quietcut-core/src/pipeline/events.ts`             | `Pipeline/PipelineEvent.swift`   |
| `RetakeDecision`  | `packages/quietcut-core/src/pipeline/decisions.ts`          | `Pipeline/RetakeDecision.swift`  |
| `Stage`           | (same as `PipelineEvent`)                                   | (same as `PipelineEvent`)        |
| RPC error codes   | `packages/quietcut-server/src/rpc.ts` (`RPC_ERROR`)         | `Pipeline/SidecarClient.swift`   |
| Method names      | `packages/quietcut-server/src/index.ts` (handler registry)  | `Pipeline/SidecarClient.swift`   |
