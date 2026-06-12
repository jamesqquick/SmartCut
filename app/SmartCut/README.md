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

## Sandboxing

The app is **unsandboxed**. We need to spawn `node` and read arbitrary
user files, which the sandbox blocks. See `SmartCut.entitlements`.
This is fine for personal use; if SmartCut ever ships outside this
machine, expect to redesign the sidecar handshake.

## Regenerating the project

Edit `project.yml`, then:

```bash
cd app/SmartCut
xcodegen generate
```

`project.pbxproj` is checked in but it's a generated artifact — the
canonical source is `project.yml`.
