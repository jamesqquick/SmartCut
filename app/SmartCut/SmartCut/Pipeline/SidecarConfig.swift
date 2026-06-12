import Foundation

/// Locations the SidecarClient may need to discover at runtime.
/// In Phase 4 these become user-settable via `~/.smartcut/config.json`.
struct SidecarConfig {
    var nodePath: URL
    var sidecarPath: URL
    /// Extra env vars to merge into the spawned child's environment.
    /// Used to forward CF AI Gateway creds without requiring the user to
    /// launch the .app from a terminal.
    var extraEnv: [String: String]

    /// Default discovery — for personal-use v1. Tries common Homebrew
    /// locations for `node`; points the sidecar at the dev workspace's
    /// dist/server.cjs.
    static func defaults() -> SidecarConfig {
        let node = resolveNodeBinary()
        let sidecar = URL(
            fileURLWithPath:
                "/Users/jamesqquick/code/SmartCut/packages/quietcut-server/dist/server.cjs")
        let env = loadWorkspaceEnv()
        return SidecarConfig(nodePath: node, sidecarPath: sidecar, extraEnv: env)
    }

    /// Look in well-known Homebrew prefixes (apple silicon, intel) then
    /// fall back to `/usr/bin/env node`. The fallback works at run time
    /// only when `node` is also on the GUI's PATH, which it usually
    /// isn't — Homebrew paths first is intentional.
    private static func resolveNodeBinary() -> URL {
        let candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return URL(fileURLWithPath: "/usr/bin/env")
    }

    /// Best-effort load of the workspace `.env` so the spawned sidecar
    /// can authenticate with Cloudflare AI Gateway when the app is
    /// launched from Finder (where env vars from a shell are absent).
    /// Returns an empty dict if the file isn't there.
    private static func loadWorkspaceEnv() -> [String: String] {
        let candidates = [
            "/Users/jamesqquick/code/SmartCut/.env",
            "/Users/jamesqquick/code/local-video-tools/.env",
        ]
        for path in candidates {
            if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
                return parseDotEnv(contents)
            }
        }
        return [:]
    }

    private static func parseDotEnv(_ contents: String) -> [String: String] {
        var env: [String: String] = [:]
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: eq)...])
                .trimmingCharacters(in: .whitespaces)
            // Strip wrapping quotes if present.
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 {
                value = String(value.dropFirst().dropLast())
            }
            if !key.isEmpty {
                env[key] = value
            }
        }
        return env
    }
}
