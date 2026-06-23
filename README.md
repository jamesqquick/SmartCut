# SmartCut

> **Beta** — SmartCut is under active development. Expect rough edges and breaking changes between releases. Feedback and bug reports welcome via [GitHub Issues](https://github.com/jamesqquick/SmartCut/issues).

[![Download SmartCut](https://img.shields.io/github/v/release/jamesqquick/SmartCut?style=for-the-badge&label=Download%20SmartCut&logo=apple&color=6d28d9)](https://github.com/jamesqquick/SmartCut/releases/latest/download/SmartCut.dmg)

[Latest release](https://github.com/jamesqquick/SmartCut/releases/latest) · [All releases](https://github.com/jamesqquick/SmartCut/releases)

SmartCut is a native macOS app that automatically edits video recordings by removing dead air and AI-detected retakes. Drop in a raw recording, review the proposed cuts, and render a clean output — without touching a timeline.

It is built for developers and educators who record coding tutorials: single-speaker screen recordings where you stumble over sentences, pause too long, or re-record lines. SmartCut finds and removes those moments automatically.

## What It Does

- Detects and removes **silence and dead air** using a fast ffmpeg-based coarse + fine pass.
- **Transcribes** your recording locally using Whisper (no audio leaves your machine).
- Sends the transcript to **Claude via Cloudflare AI Gateway** to identify retakes — spots where you flubbed a line and re-recorded it.
- Lets you **review every proposed cut** one at a time: see the removed text, hear the stitched result, then keep or remove it. Or approve all at once.
- **Renders** the final edited video with ffmpeg, with live progress.
- Ships a **terminal CLI** (`quietcut`) for the same pipeline without the GUI.

## Requirements

SmartCut downloads as a native macOS app, but it is **not self-contained**. The following must be installed and configured before the app will work:

| Requirement | Install | Notes |
| ----------- | ------- | ----- |
| **macOS 14+** (Sonoma) | — | Minimum deployment target |
| **ffmpeg** | `brew install ffmpeg` | Silence detection and rendering |
| **whisper-cli** | `brew install whisper-cpp` | Local speech-to-text transcription |
| **Cloudflare account** | [dash.cloudflare.com](https://dash.cloudflare.com) | Required for AI Gateway (see Setup below) |

Install the Homebrew dependencies first:

```bash
brew install ffmpeg whisper-cpp
```

## Install

1. Download the latest `SmartCut.dmg` using the button above, or from the [releases page](https://github.com/jamesqquick/SmartCut/releases/latest).
2. Open the DMG and drag **SmartCut** into your Applications folder.
3. Launch SmartCut. On first launch, Gatekeeper may ask for confirmation — click **Open**.
4. Complete the **first-run setup sheet** (credentials are saved to `~/.smartcut/config.json`).

## Setup: Cloudflare AI Gateway

SmartCut routes Claude calls through [Cloudflare AI Gateway](https://developers.cloudflare.com/ai-gateway/) for observability and unified billing. You need a Cloudflare account to use it.

### Step 1 — Create an AI Gateway

1. Go to [dash.cloudflare.com](https://dash.cloudflare.com) and open **AI Gateway**.
2. Click **Create Gateway**. Name it anything (e.g. `smartcut`). The gateway ID defaults to `default` if you skip naming.
3. Note your **Account ID** from the sidebar — you will need it.

### Step 2 — Create an API token

In your gateway's **Settings** tab, create an authentication token with the **AI Gateway: Run** permission. Copy the token value — it is only shown once.

### Step 3 — Enter credentials in SmartCut

On first launch, SmartCut shows a setup sheet. Enter:

- **Cloudflare Account ID**
- **AI Gateway ID** (default: `default`)
- **CF AI Gateway Token** (from Step 2)

Credentials are saved to `~/.smartcut/config.json`. To update them later, edit that file directly or delete it and relaunch the app.

### Environment variables (CLI / advanced)

| Variable | Required | Description |
| -------- | -------- | ----------- |
| `CLOUDFLARE_ACCOUNT_ID` | yes | Your Cloudflare account ID |
| `CF_AIG_GATEWAY_ID` | no | AI Gateway ID (default: `default`) |
| `CF_AIG_TOKEN` | yes* | Unified billing auth token (recommended) |
| `ANTHROPIC_API_KEY` | yes* | Direct Anthropic key (alternative to CF token) |

\* One of `CF_AIG_TOKEN` or `ANTHROPIC_API_KEY` is required. The gateway token is recommended — it routes through Cloudflare AI Gateway so you get observability, caching, and unified billing.

## How It Works

```
SwiftUI app  →  PipelineEngine (Swift)  →  ffmpeg + whisper-cli (subprocess)
                                         →  Claude via Cloudflare AI Gateway (URLSession)
```

The pipeline runs entirely within the Swift app. There is no Node.js process involved. `ffmpeg`, `ffprobe`, and `whisper-cli` are invoked as subprocesses via `Foundation.Process`. Claude is called directly over HTTPS using `URLSession` with Server-Sent Events streaming.

### Pipeline steps

1. **Drop a video** onto the app (drag-and-drop or file picker).
2. **Review settings** — silence threshold, Claude model, Whisper model, output path.
3. **Start processing**:
   - ffprobe reads video metadata.
   - ffmpeg extracts audio and runs silence detection (coarse pass + fine boundary snapping).
   - whisper-cli transcribes the audio locally.
   - Claude (via Cloudflare AI Gateway) reads the transcript and identifies retakes.
4. **Review retakes** — each proposed cut shows the removed text, the reason, and an audio preview of the stitched result. Press **R** to remove, **K** to keep, **A** to approve all, **Esc** to cancel.
5. **Render** — ffmpeg concatenates the kept segments with live progress.
6. **Done** — summary stats (time saved, percentage) with Reveal in Finder / Open / Process another.

### Cloudflare AI Gateway

SmartCut uses Cloudflare AI Gateway as the egress proxy for all Claude API calls. The gateway URL is constructed from your account ID and gateway ID:

```
https://gateway.ai.cloudflare.com/v1/{CLOUDFLARE_ACCOUNT_ID}/{CF_AIG_GATEWAY_ID}/anthropic
```

This gives you:
- **Observability** — see every request, token count, latency, and cost in the Cloudflare dashboard.
- **Caching** — repeated identical requests are served from cache.
- **Unified billing** — pay for AI through Cloudflare instead of managing a separate Anthropic account (when using `CF_AIG_TOKEN`).
- **Rate limiting and fallbacks** — configurable in the gateway settings.

If you prefer to use your own Anthropic API key directly, set `ANTHROPIC_API_KEY` instead of `CF_AIG_TOKEN`.

## CLI (alternative to the GUI)

The original terminal workflow is preserved via `quietcut-cli`:

```bash
# From the repo root, with .env populated:
pnpm --filter quietcut-cli dev smartcut path/to/video.mp4

# Common flags:
#   -y              Skip interactive review (auto-approve all cuts)
#   --dry-run       Print the edit plan without rendering
#   --model NAME    Claude model (default: claude-opus-4-8)
#   --passes N      Retake detection passes (default: 2)
#   --whisper-model NAME   Whisper model (default: base.en)
#   --plan PATH     Load a saved EditPlan and re-render
#   --save-plan PATH  Write the EditPlan JSON after detection
```

## Building Locally

**Prerequisites:** macOS 14+, Xcode 15+, pnpm, ffmpeg, whisper-cli, xcodegen.

> **Note:** Node.js is only required if you want to build or run the `quietcut-cli` terminal CLI. It is not needed to build or run the macOS app.

```bash
# 1. Clone the repo.
git clone https://github.com/jamesqquick/SmartCut.git
cd SmartCut

# 2. (Optional) Install TypeScript dependencies for the CLI.
pnpm install

# 3. Generate the Xcode project.
cd app/SmartCut && xcodegen generate && cd ../..

# 4a. Open in Xcode and click Run (⌘R):
open app/SmartCut/SmartCut.xcodeproj

# 4b. Or build from the command line:
xcodebuild -project app/SmartCut/SmartCut.xcodeproj -scheme SmartCut build
```

## Repo Structure

```
SmartCut/
├── package.json                    pnpm workspace root
├── .env.example                    credential template (CLI only)
├── scripts/
│   ├── bump-version.sh             bump version across all files
│   └── package-dmg.sh              build and package a DMG locally
├── docs/
│   ├── architecture.md             native Swift pipeline reference
│   ├── RELEASING.md                release process and secrets guide
│   └── PLAN.md                     implementation plan
├── packages/
│   ├── quietcut-core/              pipeline library (async generator, CLI only)
│   ├── quietcut-cli/               terminal CLI (quietcut command)
│   └── quietcut-server/            legacy Node sidecar (no longer used by the app)
└── app/
    └── SmartCut/                   Xcode project (SwiftUI, macOS)
        ├── project.yml             xcodegen source of truth
        └── SmartCut/
            ├── Engine/             native Swift pipeline (ffmpeg, whisper, Claude)
            ├── Pipeline/           PipelineEvent types, PipelineTypes
            ├── State/              AppState, AppConfig, AppPreferences
            ├── Views/              one SwiftUI view per screen
            └── Util/               AudioPlayer, formatters
```

## Tests

```bash
# Core library unit tests (CLI):
pnpm --filter quietcut-core test
```

## Versioning

The version lives in two places that must be bumped together. Use the helper script:

```bash
./scripts/bump-version.sh 0.2.0
```

This updates `app/SmartCut/project.yml`, `app/SmartCut/SmartCut/Info.plist`, and all four `package.json` files.

## Releasing

Releases are published automatically when a version tag is pushed:

```bash
./scripts/bump-version.sh 0.2.0
git add -A && git commit -m "chore: bump version to 0.2.0"
git tag v0.2.0 && git push && git push --tags
```

GitHub Actions builds a signed, notarized DMG on a macOS runner and publishes it as a GitHub Release. See [docs/RELEASING.md](docs/RELEASING.md) for the full process and required secrets.

## License

MIT — see [LICENSE](LICENSE).
