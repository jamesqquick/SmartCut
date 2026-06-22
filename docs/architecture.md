# SmartCut Architecture

The pipeline runs entirely within the Swift app. There is no Node.js process or
inter-process communication involved.

## Process layout

```
┌──────────────────────────────────────────────────────────────────┐
│                       SmartCut.app (Swift)                       │
│                                                                  │
│  ┌──────────────────┐   ┌──────────────────────────────────────┐ │
│  │  AppState.swift  │──▶│  PipelineEngine.swift                │ │
│  │  (SwiftUI views) │   │                                      │ │
│  └──────────────────┘   │  Engine/Tools/Ffprobe.swift          │ │
│                         │  Engine/Tools/Ffmpeg.swift           │ │
│                         │  Engine/Tools/Whisper.swift          │ │
│                         │  Engine/Transcribe.swift             │ │
│                         │  Engine/LLM/GatewayClient.swift      │ │
│                         │  Engine/LLM/RetakeDetector.swift     │ │
│                         │  Engine/LLM/RetakePlanner.swift      │ │
│                         │  Engine/ReviewBatch.swift            │ │
│                         └──────────────┬─────────────────────┬─┘ │
└────────────────────────────────────────┼─────────────────────┼───┘
                                         │ Foundation.Process   │ URLSession (SSE)
                                         ▼                      ▼
                              ffmpeg / whisper-cli     Cloudflare AI Gateway
                              (subprocesses)           → Anthropic Claude
```

`PipelineEngine` uses `Foundation.Process` to run `ffmpeg`, `ffprobe`, and
`whisper-cli` as child processes, and `URLSession` with Server-Sent Events
streaming to call Anthropic Claude via Cloudflare AI Gateway.

## Pipeline stages

```
probe → extract-audio → silence-coarse → silence-fine → transcribe → detect-retakes → review → render → done
                                                                               ▲
                                                          reviewReady/submitReview ───┘
```

Each stage emits `PipelineEvent` values (defined in `Pipeline/PipelineEvent.swift`)
that `AppState` dispatches to update the UI.

| Stage | What happens |
|---|---|
| `probe` | `ffprobe` reads duration and stream info |
| `extract-audio` | `ffmpeg` extracts a mono 16 kHz WAV to a temp directory |
| `silence-coarse` | `ffmpeg silencedetect` at the configured threshold |
| `silence-fine` | `ffmpeg silencedetect` at −40 dB / 0.1 s min for boundary snapping |
| `transcribe` | `whisper-cli` transcribes the WAV; output JSON is parsed into word tokens |
| `detect-retakes` | Claude (via AI Gateway, SSE) identifies re-recorded takes |
| `review` | App suspends on a `CheckedContinuation`; UI shows the transcript review screen |
| `render` | `ffmpeg` trims and concatenates kept segments with a `filter_complex` |

`silence-fine` is best-effort; failure is non-fatal.

The **batch review flow** is always used by the app: the pipeline pauses at
`review`, emits one `reviewReady` event with the full transcript and all
proposals, and waits for a single `submitReview` call. The per-cut
`retakeProposed`/`decide` loop is preserved for the CLI.

## Review gate

`PipelineEngine.submitReview(cuts:)` resumes the `CheckedContinuation` that
`runPipeline` is suspended on. Cancellation resumes it with a `.cancel` value.

```swift
// Pipeline suspends here:
let decision = await withCheckedContinuation { cont in
    reviewContinuation = cont
    emit(.reviewReady(...))
}

// AppState.applyReview() calls:
engine.submitReview(cuts: cuts)  // resumes the continuation
```

## Audio previews

Three preview calls are available for the review screens:

| Method | Used by | What it renders |
|---|---|---|
| `extractClip` | `RetakeCardView` | Raw clip of the removed segment |
| `extractStitchedClip` | `RetakeCardView` | Audio before + after the cut, joined |
| `extractEditedPreview` | `TranscriptReviewView` | Full edit plan applied to the preview window |

All three produce temp WAV files under `$TMPDIR/smartcut-previews/` with a 5-minute TTL.

## PipelineEvent discriminated union

Defined in `Pipeline/PipelineEvent.swift`. `AppState.handle(event:)` switches on `type`.

| `type` | Fields | Meaning |
|---|---|---|
| `stage` | `stage`, `status` (`start`\|`done`\|`fail`), `message?`, `durationMs?` | A pipeline stage transitioned |
| `progress` | `stage`, `current?`, `total?`, `percent?`, `note?` | Intra-stage note |
| `metadata` | `durationSec`, `sizeBytes`, `codec?`, `width?`, `height?` | Emitted during `probe` |
| `silenceFound` | `count`, `segments` | Coarse silence detection completed |
| `transcript` | `tokenCount`, `preview` | Whisper transcript ready |
| `reviewReady` | `total`, `transcript`, `proposals` | Pipeline suspended; UI shows review screen |
| `retakeProposed` | `opId`, `op`, `index`, `total` | Legacy per-cut flow (CLI only) |
| `retakeDecision` | `opId`, `action` | Legacy per-cut acknowledgement |
| `renderProgress` | `frame?`, `fps?`, `speed?`, `percent?`, `etaSec?` | ffmpeg progress update |
| `done` | `plan`, `output`, `savedSec`, `savedPercent`, `elapsedSec` | Job finished |
| `error` | `message`, `stage?`, `stack?` | Unrecoverable failure |

## Cancellation

Calling `engine.cancel()` or `engine.terminateNow()`:

1. Cancels the active Swift `Task`.
2. Calls `p.terminate()` on the tracked ffmpeg/whisper `Process` (if any).
3. Resumes the review `CheckedContinuation` with `.cancel` if suspended.

Mid-stage processes (ffmpeg render, whisper) are killed immediately via the
`withTaskCancellationHandler` registered in `ProcessRunner`.

## Where the types live

| Concept | File |
|---|---|
| `PipelineEvent`, `Stage`, `RemoveRetakeOp`, `EditPlan` | `Pipeline/PipelineEvent.swift` |
| `RetakeDecision`, `ReviewCutDecision` | `Pipeline/RetakeDecision.swift` |
| `VideoMetadata`, `AudioClip`, `StartOptions` | `Pipeline/PipelineTypes.swift` |
| `PipelineEngine` (orchestration) | `Engine/PipelineEngine.swift` |
| `ProcessRunner` (subprocess wrapper) | `Engine/ProcessRunner.swift` |
| `GatewayClient` (Anthropic SSE) | `Engine/LLM/GatewayClient.swift` |
| Segment math | `Engine/Model/EngineSegment.swift` |
| Silence boundary snapping | `Engine/Model/Snap.swift` |
| Whisper JSON parsing + sub-word merge | `Engine/Transcribe.swift` |
| Review proposals + applyReviewResult | `Engine/ReviewBatch.swift` |

## Legacy: quietcut-server

`packages/quietcut-server/` contains the original Node.js sidecar that the app
previously used. It is **no longer used by the macOS app** but is preserved for
reference and because `quietcut-cli` depends on `quietcut-core`, which it shares.
The JSON-RPC wire protocol it implemented is documented in the git history.
