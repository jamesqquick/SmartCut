# Audio Preview of Edited Sections — Design

**Date:** 2026-06-16
**Branch:** `feat/audio-preview-edited-sections`
**Status:** Approved design, ready for implementation plan
**Mockup:** `docs/audio-preview-mockup.html`

## Summary

Let the user audition each proposed cut on the review screen by pressing a play
button on its cut chip. The app plays a short stitched audio clip — **2.5
seconds before the cut and 2.5 seconds after it** — that reflects exactly what
the final render will sound like across that boundary. This lets the user
confirm, by ear as well as by text, that a cut sounds natural before applying
it.

"Faithful to the final render" is the core requirement: within the preview
window, the clip applies every edit the renderer would apply — the cut being
previewed, any neighboring cuts that fall in the window, silence removals, and
lead-in/tail-out padding. What the user hears is the assembled output for that
span, not a naive butt-join of two raw slices.

## Goals

- A play/stop control on every cut chip in `TranscriptReviewView` (AI, manual,
  enabled, and disabled cuts).
- Playback that is faithful to the final render within the window.
- Reuse the existing audio playback model (whole-clip play/stop toggle).
- Single source of truth for the edit math (`planToKeepSegments` in core).

## Non-goals

- No scrubbing, playhead, or progress bar (whole-clip toggle only).
- No video preview (audio only).
- No reviving the dead `RetakeReviewView` / `RetakeCardView`.
- No user-facing preference for the pre/post-roll duration in v1 (the RPC params
  exist, so it can be exposed later without core changes).
- No explainer/help panel in the app (the mockup's "Show/Hide" explainer is a
  documentation device only).

## Background: what already exists

Most of the plumbing exists but is wired into dead code:

- **`extractStitchedClip`** RPC (`packages/quietcut-server/src/audio-preview.ts`)
  produces a before+after stitched WAV with configurable `padSec`/`tailSec`. It
  is a **naive** two-region butt-join — it ignores silence cuts, neighboring
  cuts, and padding, so it is **not** faithful enough on its own.
- **`SidecarClient.extractStitchedClip`** Swift wrapper
  (`app/SmartCut/SmartCut/Pipeline/SidecarClient.swift`).
- **`AudioPlayer`** (`app/SmartCut/SmartCut/Util/AudioPlayer.swift`) — an
  `AVAudioPlayer`-based player with an async `play(key:loader:)` toggle model.
  Plays a whole file; no seeking. This is exactly the model we want.
- The reference UI for the buttons lives in `RetakeCardView.swift`, but that
  view and `RetakeReviewView.swift` are **dead code** — not routed by
  `ContentView`. The live review screen is **`TranscriptReviewView`**, which has
  no audio playback today.

The render-time edit math is centralized in `planToKeepSegments`
(`packages/quietcut-core/src/edit-plan.ts:73`), which inverts all `remove*`
operations into keep segments, applies lead-in/tail-out padding, merges
overlaps, and re-subtracts retake regions so padding never re-adds removed
speech. The faithful preview must reuse this function.

## Architecture decision

**Compute the faithful preview server-side, reusing `planToKeepSegments`.**

The preview must apply the same edits as the renderer. That logic exists once,
in core. Three options were considered:

- **A (chosen)** — New sidecar RPC that takes the focus window + current enabled
  cuts + silence regions + padding, builds a throwaway `EditPlan`, runs
  `planToKeepSegments`, clips the result to the window, and stitches those keep
  segments into one WAV. Edit math stays in core; preview and render can never
  drift.
- **B (rejected)** — Port the keep-segment math to Swift. Duplicates non-trivial
  logic (padding + retake re-subtraction) in a second language; guaranteed to
  drift.
- **C (rejected)** — Server retains run state (silence ops, duration, padding)
  at `reviewReady` and the RPC only needs the window + cut times. Less wire
  data, but couples a stateless RPC to live job internals for little gain.

The client already has everything needed to drive option A:

- Transcript token timings — from the `reviewReady` event (`AppState.transcript`).
- Current enabled cut ranges — `AppState.reviewCuts` (word indices →
  source-time via the `estimatedDuration` mapping at `AppState.swift:129`).
- Silence regions — carried by the `silenceFound` event but currently
  **discarded** (`AppState.swift:490` only logs the count). We will capture them.
- Padding — `options.leadInMs` / `options.tailOutMs` (default 300/300), which
  match what `buildConfig` sends to the renderer.

## Detailed design

### Preview window and windowing semantics

For the previewed cut, derive its source-time bounds from its current word
indices (not the original `op.start`/`op.end`, which go stale when boundaries
are dragged, and are absent for manual cuts):

- `focusStart = transcript[removeStartIndex].start`
- `focusEnd = transcript[removeEndIndex + 1].start` (falling back to
  `transcript[removeEndIndex].end` when the cut ends at the last token)

This mirrors `AppState.estimatedDuration`. A shared helper should expose it so
the view and the RPC caller agree.

The preview window in source time is:

- `windowStart = max(0, focusStart - padSec)` with `padSec = 2.5`
- `windowEnd = min(duration, focusEnd + tailSec)` with `tailSec = 2.5`

The server computes the full set of keep segments for the plan, intersects them
with `[windowStart, windowEnd]`, and concatenates the intersected segments into
one WAV. Because the window is carved out of the *real* keep segments, the user
hears exactly what survives across that boundary — this cut, neighboring cuts,
silence trims, and padding all applied. If there is silence in the 2.5s before
the cut, the user hears less than 2.5s of speech there, which is correct: that
is what the export does.

### Server: new RPC `extractEditedPreview`

New function in `packages/quietcut-server/src/audio-preview.ts` and a handler in
`packages/quietcut-server/src/index.ts`.

**Params:**

```
{
  path: string;          // source video file
  duration: number;      // source duration (seconds)
  focusStart: number;    // cut start (source seconds)
  focusEnd: number;      // cut end / kept resume (source seconds)
  padSec?: number;       // default 2.5
  tailSec?: number;      // default 2.5
  leadInMs?: number;     // default 300 (must match render config)
  tailOutMs?: number;    // default 300
  cuts: Segment[];       // all ENABLED retake + manual cuts, source seconds
  silences: Segment[];   // silence regions, source seconds
}
```

**Returns:** `{ path: string; durationSec: number }` (same shape as the existing
extract methods; ephemeral temp WAV, mono 44.1 kHz PCM, auto-deleted after 5
minutes via the existing `scheduleCleanup`).

**Algorithm:**

1. Validate: `path` present; `duration`, `focusStart`, `focusEnd` finite;
   `focusEnd > focusStart`. Throw `invalidParams` otherwise.
2. Build operations: `cuts` → `removeRetake`-shaped ops (manual cuts are hard
   joins, same as retakes — no padding bleed); `silences` → `removeSilence` ops.
   Only `start`/`end`/`type` matter to `planToKeepSegments`.
3. `plan = { source: path, duration, operations }`.
4. `keep = planToKeepSegments(plan, leadInMs, tailOutMs)`.
5. Intersect each keep segment with `[windowStart, windowEnd]`; drop empties.
6. If the intersection is empty (degenerate — the whole window is removed),
   throw `invalidParams` with a clear message (the UI should not normally allow
   this, but guard anyway).
7. Build an ffmpeg `filter_complex` with one `atrim` per windowed keep segment
   plus a final `concat=n=<count>:v=0:a=1`, generalizing the two-region filter
   already used by `extractStitchedClip`. Output mono 44.1 kHz `pcm_s16le`.
8. `durationSec` = sum of windowed segment lengths.

`planToKeepSegments` is already exported from `quietcut-core` and the server
already imports from that package, so no new core surface is required (beyond
optionally re-exporting `Segment` if not already available to the server).

### Client: capture silence regions

`AppState` currently discards `silenceFound.segments`. Add storage:

- `var silenceSegments: [Segment] = []`. The Swift `Segment`
  `{ start: Double; end: Double }` and `silenceFound` segment decoding already
  exist (`PipelineEvent.swift:40`, `:145`); only `AppState` needs to retain them.
- Populate it in the `.silenceFound` case (`AppState.swift:490`), keeping the
  existing log line.
- Clear it in `resetPipelineState()`.

### Client: cut-to-source-time mapping helper

Add a helper on `AppState` so the view and any preview caller agree on times:

```
func sourceTimes(for cut: ReviewCutState) -> (start: Double, end: Double)
```

Returns `focusStart`/`focusEnd` using the `estimatedDuration` mapping. Also add
a method that maps all enabled cuts to `[Segment]` for the RPC's `cuts` param.

### Client: SidecarClient wrapper

Add `extractEditedPreview(...) async throws -> AudioClip` to `SidecarClient`,
mirroring the existing `extractStitchedClip` wrapper, encoding the params above
and decoding the existing `AudioClip { path, durationSec }`.

### Client: preview button in `TranscriptReviewView`

- Add one `@State private var audio = AudioPlayer()` to the view (shared across
  chips so play/stop toggling is mutually exclusive — playing one stops any
  other, which `AudioPlayer`'s key model already enforces).
- In `cutChip(...)` (`TranscriptReviewView.swift:144`), add a small
  play/stop/spinner button in the `chip-top` row, left of the toggle (and left
  of the manual delete `×`). Key it `"preview-<opId>"`.
- Button states, driven by `audio.currentKey` / `isPlaying` / `isLoading`:
  - **Idle:** play glyph.
  - **Loading:** spinner (while the RPC extracts the WAV).
  - **Playing:** stop glyph (active/highlighted).
- On tap, call `audio.play(key:)` with a loader closure that:
  1. reads `appState.droppedFile`,
  2. computes `focusStart`/`focusEnd` via the helper,
  3. gathers enabled `cuts` and `silenceSegments`,
  4. calls `sidecar.extractEditedPreview(...)` with `padSec: 2.5, tailSec: 2.5`
     and the current `leadInMs`/`tailOutMs`,
  5. returns the resulting file URL.
- The button is available on disabled cuts too, so the user can audition "what
  it would sound like if I cut this." When previewing a disabled cut, include it
  in the `cuts` set passed to the RPC (so the previewed cut is actually applied
  in its own preview) even though it is excluded from the apply set.

### Defaults and consistency

- `padSec`/`tailSec` default to **2.5** in both the Swift call site and the
  server handler.
- `leadInMs`/`tailOutMs` are passed from `AppState.options` so the preview's
  padding matches the render. The server handler defaults to 300/300 to match
  `buildConfig` if omitted.

## Files touched

- `packages/quietcut-server/src/audio-preview.ts` — new `extractEditedPreview`.
- `packages/quietcut-server/src/index.ts` — register the RPC + param validation.
- `app/SmartCut/SmartCut/Pipeline/SidecarClient.swift` — wrapper + params type.
- `app/SmartCut/SmartCut/State/AppState.swift` — capture silences, add
  `sourceTimes(for:)` + enabled-cuts→segments helper, clear in reset.
- `app/SmartCut/SmartCut/Views/TranscriptReviewView.swift` — `AudioPlayer` state
  + preview button in `cutChip`.
- `docs/architecture.md` — document `extractEditedPreview` (and fix the existing
  drift: `submitReview` is undocumented and the doc still frames review as the
  per-cut `decide` flow).

## Testing

- **Core (`quietcut-core`):** unit-test the windowing/intersection helper — keep
  segments intersected with a window, including cases where (a) a silence sits
  inside the pre-roll, (b) a neighboring cut sits inside the post-roll, (c) the
  window clamps at file start/end, (d) the focus cut itself is excluded. If the
  intersection logic is added to core (recommended), test it there; otherwise
  test it in the server package.
- **Server (`quietcut-server`):** integration test with a fixture clip
  (gated on `SMARTCUT_FIXTURE`, matching the existing test setup) asserting the
  RPC returns a playable WAV whose `durationSec` equals the summed kept lengths
  within tolerance.
- **Manual:** drop a clip, reach review, press a cut's play button; confirm
  loading → playing → idle, mutual exclusivity across chips, and that a
  previewed boundary matches the rendered output for the same cut set.

## Open questions

None blocking. Future enhancement: expose `padSec`/`tailSec` as a user
preference (params already exist).
