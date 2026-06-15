# SmartCut

A native macOS app that wraps the `quietcut smartcut` CLI pipeline behind a
SwiftUI UI. Detects silence and AI-flagged retakes in video recordings, lets
you review each proposed cut one-by-one, then renders the cleaned output with
ffmpeg.

## Architecture

```
SwiftUI app  ↔  (JSON-RPC over stdio)  ↔  Node sidecar  ↔  runSmartcut async generator
                                                          ↔  ffmpeg + whisper-cli + Claude
                                                             (via Cloudflare AI Gateway)
```

The app spawns a single Node process (`quietcut-server`) as a child, then
drives the pipeline by exchanging newline-delimited JSON-RPC messages over
its stdin/stdout. Pipeline events (stage transitions, retake proposals, render
progress) stream back as notifications. See `docs/architecture.md` for the
full wire format.

## Prerequisites

| Tool | Install | Notes |
| ---- | ------- | ----- |
| **macOS 14+** (Sonoma) | — | Deployment target |
| **Xcode 15+** | Mac App Store | Builds the SwiftUI app |
| **xcodegen** | `brew install xcodegen` | Generates `.xcodeproj` from `project.yml` |
| **Node 20+** | `brew install node` or nvm | Runs the sidecar |
| **pnpm** | `npm i -g pnpm` | Workspace package manager |
| **ffmpeg** | `brew install ffmpeg` | Silence detection + rendering |
| **whisper-cli** | `brew install whisper-cpp` | Local speech-to-text |
| **Cloudflare account** | [dash.cloudflare.com](https://dash.cloudflare.com) | AI Gateway for Claude retake detection |

## Quick start

```bash
# 1. Clone and install TS dependencies.
git clone https://github.com/jamesqquick/SmartCut.git
cd SmartCut
pnpm install

# 2. Set up Cloudflare AI Gateway credentials.
cp .env.example .env
# Edit .env — fill in CLOUDFLARE_ACCOUNT_ID and CF_AIG_TOKEN.
# Or: the app will prompt on first launch via a setup sheet and save
# credentials to ~/.smartcut/config.json.

# 3. Build the TS workspace (core, CLI, sidecar).
pnpm build

# 4. Generate the Xcode project (only needed once or when project.yml changes).
cd app/SmartCut
xcodegen generate
cd ../..

# 5a. Build + run from Xcode:
open app/SmartCut/SmartCut.xcodeproj
# Click Run (⌘R).

# 5b. Or build from the CLI:
xcodebuild -project app/SmartCut/SmartCut.xcodeproj -scheme SmartCut build
open ~/Library/Developer/Xcode/DerivedData/SmartCut-*/Build/Products/Debug/SmartCut.app
```

## CLI (alternative to the GUI)

The original terminal workflow is preserved via `quietcut-cli`:

```bash
# From the repo root, with .env populated:
pnpm --filter quietcut-cli dev smartcut path/to/video.mp4

# Common flags (same as before):
#   -y              Skip interactive review (auto-approve all)
#   --dry-run       Print the edit plan without rendering
#   --model NAME    Claude model (default: claude-opus-4-8)
#   --passes N      Retake detection passes (default: 2)
#   --whisper-model NAME   Whisper model (default: base.en)
#   --plan PATH     Load a saved EditPlan and re-render
#   --save-plan PATH  Write the EditPlan JSON after detection
```

## Env vars

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `CLOUDFLARE_ACCOUNT_ID` | yes | Cloudflare account |
| `CF_AIG_GATEWAY_ID` | no | AI Gateway id (default: `default`) |
| `CF_AIG_TOKEN` | yes* | Unified billing auth token |
| `ANTHROPIC_API_KEY` | yes* | Direct Anthropic key (alternative to CF token) |

\*One of `CF_AIG_TOKEN` or `ANTHROPIC_API_KEY` is required. The gateway token
is recommended — it routes through Cloudflare's AI Gateway so you get
observability and unified billing.

For the GUI, credentials can also be entered in the first-run setup sheet
(persisted to `~/.smartcut/config.json`).

## Repo structure

```
SmartCut/
├── package.json                    pnpm workspace root
├── pnpm-workspace.yaml
├── tsconfig.base.json
├── .env.example
├── docs/
│   ├── PLAN.md                     implementation plan
│   ├── architecture.md             sidecar protocol reference
│   └── ui-mockup.html              visual reference (open in browser)
├── packages/
│   ├── quietcut-core/              pipeline library (async generator)
│   │   └── src/pipeline/
│   │       ├── runSmartcut.ts       the async generator
│   │       ├── events.ts            PipelineEvent type union
│   │       └── decisions.ts         RetakeDecision type
│   ├── quietcut-cli/               terminal CLI (ora + inquirer)
│   └── quietcut-server/            Node sidecar (JSON-RPC stdio)
│       └── dist/server.cjs         bundled for Swift consumption
└── app/
    └── SmartCut/                   Xcode project (SwiftUI)
        ├── project.yml             xcodegen source of truth
        └── SmartCut/
            ├── Pipeline/           SidecarClient, PipelineEvent, etc.
            ├── State/              AppState, AppConfig, AppPreferences
            ├── Views/              one per mockup screen + sidebar
            └── Util/               AudioPlayer, Formatters
```

## How it works

1. **Drop a video** onto the app (or pick via file dialog).
2. **Review settings** — silence threshold, Claude model, whisper model, output path.
3. **Start processing** — the sidecar runs:
   - ffprobe for metadata
   - ffmpeg to extract audio
   - Coarse + fine silence detection
   - Whisper transcription
   - Claude retake detection (via Cloudflare AI Gateway)
4. **Review retakes** — each proposed cut shows the removed text, the reason,
   a stitched-result preview, and audio playback buttons. Press **R** to remove,
   **K** to keep, **A** to approve all remaining, **Esc** to cancel.
5. **Render** — ffmpeg concatenates the kept segments with live progress.
6. **Done** — summary stats + Reveal in Finder / Open / Process another.

## Updating credentials

Edit `~/.smartcut/config.json` directly, or delete it and relaunch the app to
trigger the setup sheet.

## Tests

```bash
# Core library unit tests (55 tests):
pnpm --filter quietcut-core test

# Sidecar integration tests (needs .env + fixture):
SMARTCUT_FIXTURE="$HOME/Movies/your-clip.mov" \
  pnpm --filter quietcut-server test
```

## Non-goals (v1)

- No code signing / notarization / DMG packaging
- No bundled Node / ffmpeg / whisper binaries
- No auto-update
- No batch processing
- No Whisper-via-API switching
