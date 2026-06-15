import Foundation

/// Locations the SidecarClient needs to discover at runtime.
/// Built from a user-supplied `AppConfig` plus sensible defaults.
struct SidecarConfig {
    var nodePath: URL
    var sidecarPath: URL
    /// Extra env vars to merge into the spawned child's environment.
    var extraEnv: [String: String]
    /// Directories prepended to PATH for ffmpeg / whisper-cli resolution.
    var extraPathDirs: [String]

    /// Build a SidecarConfig from a user-supplied AppConfig. Falls back
    /// to discovery defaults when fields are missing.
    static func from(_ appConfig: AppConfig) -> SidecarConfig {
        let nodeURL =
            appConfig.nodePath.flatMap(nonEmptyURL)
            ?? resolveNodeBinary()

        let sidecarURL =
            appConfig.sidecarPath.flatMap(nonEmptyURL)
            ?? resolveSidecarBinary()

        var paths: [String] = []
        if let dir = appConfig.ffmpegDir, !dir.isEmpty {
            paths.append(dir)
        }
        // Always include common brew prefixes as fallbacks.
        for fallback in ["/opt/homebrew/bin", "/usr/local/bin"] where !paths.contains(fallback) {
            paths.append(fallback)
        }

        // If config doesn't have creds, fall back to a workspace `.env`
        // so dev workflow keeps working when config.json isn't populated.
        var env = appConfig.processEnv
        if env["CLOUDFLARE_ACCOUNT_ID"] == nil {
            for (k, v) in loadDevEnv() {
                env[k] = v
            }
        }

        return SidecarConfig(
            nodePath: nodeURL,
            sidecarPath: sidecarURL,
            extraEnv: env,
            extraPathDirs: paths
        )
    }

    /// Legacy convenience used by smoke tests / previews.
    static func defaults() -> SidecarConfig {
        from(.load())
    }

    /// Resolve the bundled `server.cjs`. The app bundles it into Resources
    /// (see project.yml `preBuildScripts`), making the .app portable. For
    /// `swift run`/preview contexts where there is no bundle, fall back to a
    /// dev workspace path derived from `SMARTCUT_DEV_ROOT` (or the repo
    /// checkout two levels above the executable).
    private static func resolveSidecarBinary() -> URL {
        if let bundled = Bundle.main.url(forResource: "server", withExtension: "cjs") {
            return bundled
        }

        let env = ProcessInfo.processInfo.environment
        if let devRoot = env["SMARTCUT_DEV_ROOT"], !devRoot.isEmpty {
            return URL(fileURLWithPath: devRoot)
                .appendingPathComponent("packages/quietcut-server/dist/server.cjs")
        }

        // Last-resort dev fallback: relative to the current working directory.
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("packages/quietcut-server/dist/server.cjs")
    }

    /// Look in well-known Homebrew prefixes (apple silicon, intel) then
    /// fall back to `/usr/bin/env node`. The fallback only works when
    /// `node` is on the GUI's PATH, which is rare from Finder.
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

    /// Best-effort load of a workspace `.env` so the spawned sidecar can
    /// authenticate during local development before the user fills in
    /// `~/.smartcut/config.json`. Only consulted when `SMARTCUT_DEV_ROOT`
    /// points at a checkout; shipped apps rely on `~/.smartcut/config.json`.
    private static func loadDevEnv() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        guard let devRoot = env["SMARTCUT_DEV_ROOT"], !devRoot.isEmpty else {
            return [:]
        }
        let path = URL(fileURLWithPath: devRoot)
            .appendingPathComponent(".env").path
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            return parseDotEnv(contents)
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

private func nonEmptyURL(_ raw: String) -> URL? {
    raw.isEmpty ? nil : URL(fileURLWithPath: raw)
}
