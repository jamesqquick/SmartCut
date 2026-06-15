import Foundation

/// Persistent secrets + binary paths. Lives at `~/.smartcut/config.json`
/// because the sidecar's gateway resolver reads these as env vars.
/// Plain JSON for v1; Keychain integration is a v2 chore.
struct AppConfig: Codable, Equatable, Sendable {
    /// Path to a `node` binary. Required.
    var nodePath: String?
    /// Directory containing `ffmpeg` and `whisper-cli` — prepended to
    /// the spawned child's PATH so shell-out commands resolve.
    var ffmpegDir: String?
    /// Explicit path to the quietcut-server bundle. Optional: when unset the
    /// app uses the `server.cjs` bundled into its Resources (see project.yml).
    /// Set this only to override with a custom build.
    var sidecarPath: String?
    /// CF AI Gateway account.
    var cloudflareAccountId: String?
    /// CF AI Gateway id (defaults to "default" if empty).
    var cfAigGatewayId: String?
    /// CF AI Gateway auth token (preferred over `anthropicApiKey`).
    var cfAigToken: String?
    /// Bring-your-own Anthropic key. Leave empty when using CF unified billing.
    var anthropicApiKey: String?

    static let `default` = AppConfig(
        nodePath: nil,
        ffmpegDir: "/opt/homebrew/bin",
        sidecarPath: nil,
        cloudflareAccountId: nil,
        cfAigGatewayId: "default",
        cfAigToken: nil,
        anthropicApiKey: nil
    )

    /// Returns true when the gateway can authenticate. We need an account
    /// id plus either a CF Gateway token (unified billing) or an Anthropic
    /// API key.
    var hasRequiredSecrets: Bool {
        guard let account = cloudflareAccountId, !account.isEmpty else { return false }
        let hasCfToken = !(cfAigToken ?? "").isEmpty
        let hasAnthropic = !(anthropicApiKey ?? "").isEmpty
        return hasCfToken || hasAnthropic
    }

    // MARK: Persistence

    /// `~/.smartcut/config.json`
    static var fileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".smartcut/config.json")
    }

    static func load() -> AppConfig {
        let url = fileURL
        guard let data = try? Data(contentsOf: url) else {
            return .default
        }
        let decoder = JSONDecoder()
        guard var decoded = try? decoder.decode(AppConfig.self, from: data) else {
            return .default
        }
        if decoded.ffmpegDir?.isEmpty != false {
            decoded.ffmpegDir = AppConfig.default.ffmpegDir
        }
        if decoded.cfAigGatewayId?.isEmpty != false {
            decoded.cfAigGatewayId = AppConfig.default.cfAigGatewayId
        }
        return decoded
    }

    func save() throws {
        let url = Self.fileURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
        // 0600 — best-effort, since this file holds secrets.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: Translation to sidecar env

    /// Env vars to merge into the spawned sidecar process.
    var processEnv: [String: String] {
        var env: [String: String] = [:]
        if let v = cloudflareAccountId, !v.isEmpty { env["CLOUDFLARE_ACCOUNT_ID"] = v }
        if let v = cfAigGatewayId, !v.isEmpty { env["CF_AIG_GATEWAY_ID"] = v }
        if let v = cfAigToken, !v.isEmpty { env["CF_AIG_TOKEN"] = v }
        if let v = anthropicApiKey, !v.isEmpty { env["ANTHROPIC_API_KEY"] = v }
        return env
    }
}
