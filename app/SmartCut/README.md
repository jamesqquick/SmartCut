# SmartCut.app (macOS, SwiftUI)

The native macOS front-end. Speaks JSON-RPC over stdio to the
`quietcut-server` Node sidecar in `packages/quietcut-server`.

## Prerequisites

- Xcode 15+ (the project is pinned to a macOS 14 deployment target)
- `brew install xcodegen` — the `.xcodeproj` is regenerable from `project.yml`

## Build + run

```bash
# From the repo root.

# 1. Build the Node sidecar bundle that the app spawns.
pnpm install
pnpm --filter quietcut-server build

# 2. Generate the Xcode project (only needed if project.yml changed).
( cd app/SmartCut && xcodegen generate )

# 3a. Build via xcodebuild from the CLI:
xcodebuild -project app/SmartCut/SmartCut.xcodeproj -scheme SmartCut build

# 3b. Or open in Xcode and click Run:
open app/SmartCut/SmartCut.xcodeproj
```

## Project layout

- `SmartCut/SmartCutApp.swift` — `@main` entry point + window scene
- `SmartCut/Views/` — SwiftUI views (one per mockup screen)
- `SmartCut/Pipeline/` — `SidecarClient`, `PipelineEvent`, `RetakeDecision`
- `SmartCut/State/` — `AppState` (single source of truth)
- `SmartCut/Util/` — `AudioPlayer`, formatters
- `SmartCut/Assets.xcassets` — app icon + accent color

## Sandboxing and signing

The app is **unsandboxed** (`app-sandbox: false`). Spawning `node`, `ffmpeg`,
and `whisper-cli` as child processes requires this — the sandbox blocks
arbitrary process execution.

For local development, code signing is disabled (Debug configuration).
Release builds use **Developer ID Application** signing with hardened runtime
enabled, which is required for notarization. Spawning external processes is
allowed under hardened runtime because each child process carries its own
signature and runs in its own address space.

See `docs/RELEASING.md` in the repo root for the full distribution process.

## Regenerating the project

Edit `project.yml`, then:

```bash
cd app/SmartCut
xcodegen generate
```

`project.pbxproj` is checked in but it's a generated artifact — the
canonical source is `project.yml`.
