# Releasing SmartCut

This document explains the full release process: how versioning works, what GitHub secrets are required and how to create them, and what the automated pipeline does step by step.

## Overview

Releases are triggered by pushing a version tag. GitHub Actions picks it up, builds a signed and notarized DMG on a macOS runner, and publishes it as a GitHub Release with the DMG attached.

```
git tag v0.2.0 → GitHub Actions → signed + notarized SmartCut.dmg → GitHub Release
```

Pre-release versions (tags containing a hyphen, e.g. `v0.2.0-beta.1`) are automatically marked as pre-release on GitHub.

---

## Step 1 — Bump the version

Use the helper script to update all release version strings in one command:

```bash
./scripts/bump-version.sh 0.2.0
```

This updates:
- `app/SmartCut/project.yml` — `CFBundleShortVersionString` (shown in Finder / About)
- `app/SmartCut/SmartCut/Info.plist` — `CFBundleShortVersionString` and `CFBundleVersion` used by the release workflow/appcast
- `package.json` — root workspace
- `packages/quietcut-core/package.json`
- `packages/quietcut-cli/package.json`
- `packages/quietcut-server/package.json`

Commit and tag:

```bash
git add -A
git commit -m "chore: bump version to 0.2.0"
git tag v0.2.0
git push && git push --tags
```

Pushing the tag triggers the release workflow.

---

## Step 2 — Required GitHub secrets

Before the first release, populate all of these under **Settings → Secrets and variables → Actions** in the GitHub repo.

### `BUILD_CERTIFICATE_BASE64`

Your **Developer ID Application** certificate, exported as a `.p12` and base64-encoded.

1. Open **Keychain Access** on your Mac.
2. Find your **Developer ID Application: Your Name (TEAMID)** certificate under **My Certificates**.
3. Right-click → **Export**. Choose `.p12` format and set a strong password.
4. Base64-encode it:
   ```bash
   base64 -i ~/Downloads/certificate.p12 | pbcopy
   ```
5. Paste into the `BUILD_CERTIFICATE_BASE64` secret.

### `P12_PASSWORD`

The password you set when exporting the `.p12` in the step above.

### `KEYCHAIN_PASSWORD`

Any throwaway password — the workflow creates a temporary keychain on the runner to import the cert. It is discarded after the job. Example: generate one with `openssl rand -base64 32`.

### `APPLE_TEAM_ID`

Your 10-character Apple Developer Team ID. Find it at [developer.apple.com/account](https://developer.apple.com/account) under **Membership Details**, or run:

```bash
security find-certificate -c "Developer ID Application" -p | \
  openssl x509 -noout -subject | grep -o 'OU=[A-Z0-9]*' | cut -d= -f2
```

### `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_BASE64`

These are the App Store Connect API key credentials used by `notarytool` for notarization.

1. Go to [appstoreconnect.apple.com/access/integrations/api](https://appstoreconnect.apple.com/access/integrations/api).
2. Click **+** to create a new key. Role: **Developer** is sufficient for notarization.
3. Download the `.p8` file (it can only be downloaded once).
4. Note the **Key ID** and **Issuer ID** shown on the page.
5. Base64-encode the `.p8`:
   ```bash
   base64 -i ~/Downloads/AuthKey_XXXXXXXXXX.p8 | pbcopy
   ```

| Secret | Where to find it |
| ------ | ---------------- |
| `AC_API_KEY_ID` | Key ID shown on the API Keys page |
| `AC_API_ISSUER_ID` | Issuer ID shown at the top of the API Keys page |
| `AC_API_KEY_BASE64` | Base64-encoded contents of the `.p8` file |

---

## What the workflow does

The workflow lives at `.github/workflows/release.yml`. Here is what each section does:

1. **Checkout + Node setup** — checks out the repo, installs pnpm dependencies, builds the `quietcut-server` sidecar (`dist/server.cjs`).
2. **Install build tools** — `brew install xcodegen create-dmg`.
3. **Generate Xcode project** — runs `xcodegen generate` from `project.yml`.
4. **Import certificate** — decodes `BUILD_CERTIFICATE_BASE64` into a `.p12`, creates a temporary keychain, and imports the Developer ID cert. The keychain is automatically cleaned up when the runner is discarded.
5. **Archive** — runs `xcodebuild archive` in Release configuration with hardened runtime and Developer ID signing enabled.
6. **Export** — runs `xcodebuild -exportArchive` using `app/SmartCut/ExportOptions.plist` (method: `developer-id`).
7. **Notarize app** — submits `SmartCut.app` to Apple's notarization service via `notarytool` and waits up to 20 minutes for approval.
8. **Staple app** — attaches the notarization ticket to the `.app` bundle so it passes Gatekeeper offline.
9. **Build DMG** — runs `scripts/package-dmg.sh` to produce `SmartCut.dmg` using `create-dmg`.
10. **Notarize DMG** — submits the DMG for notarization and waits up to 10 minutes.
11. **Staple DMG** — attaches the notarization ticket to the DMG.
12. **Publish** — creates a GitHub Release named `SmartCut v0.x.x`, auto-generates release notes from merged PRs/commits since the last tag, and attaches `SmartCut.dmg`.

---

## Building a DMG locally (without CI)

If you need to produce a DMG manually:

```bash
# 1. Build the sidecar.
pnpm --filter quietcut-server build

# 2. Generate the Xcode project.
cd app/SmartCut && xcodegen generate && cd ../..

# 3. Archive and export (sign manually in Xcode, or adjust signing settings).
xcodebuild archive \
  -project app/SmartCut/SmartCut.xcodeproj \
  -scheme SmartCut \
  -configuration Release \
  -archivePath ~/Desktop/SmartCut.xcarchive

xcodebuild -exportArchive \
  -archivePath ~/Desktop/SmartCut.xcarchive \
  -exportPath ~/Desktop/SmartCut-export \
  -exportOptionsPlist app/SmartCut/ExportOptions.plist

# 4. Notarize (requires AC API key credentials).
xcrun notarytool submit ~/Desktop/SmartCut-export/SmartCut.app \
  --key ~/path/to/AuthKey.p8 \
  --key-id YOUR_KEY_ID \
  --issuer YOUR_ISSUER_ID \
  --wait

xcrun stapler staple ~/Desktop/SmartCut-export/SmartCut.app

# 5. Package the DMG.
./scripts/package-dmg.sh \
  ~/Desktop/SmartCut-export/SmartCut.app \
  ~/Desktop/SmartCut.dmg \
  0.2.0
```

---

## Troubleshooting

**Notarization timeout** — Apple's notarization service is usually fast (< 2 min) but can take up to 15 min during peak times. The workflow allows 20 min for the app and 10 min for the DMG.

**`errSecInternalComponent` on certificate import** — the `set-key-partition-list` step needs the keychain password to match exactly. Check that `KEYCHAIN_PASSWORD` is set and not empty.

**Hardened runtime + spawning external processes** — SmartCut spawns `node`, `ffmpeg`, and `whisper-cli` as child processes. These are separate signed executables and do not require `com.apple.security.cs.disable-library-validation`. If notarization is rejected for this reason, check `SmartCut.entitlements` and ensure only the entitlements in `project.yml` are present.

**First release fails** — all secrets must exist before the tag is pushed. Create all six secrets, then re-tag:
```bash
git tag -d v0.1.0
git push origin :refs/tags/v0.1.0
git tag v0.1.0
git push --tags
```
