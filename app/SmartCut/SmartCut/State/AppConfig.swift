import Foundation

/// Persistent credentials + binary paths. Lives at `~/.smartcut/config.json`.
/// Plain JSON for v1; Keychain integration is a v2 chore.
struct AppConfig: Codable, Equatable, Sendable {

    // MARK: - Active fields

    /// Directory containing `ffmpeg` and `whisper-cli` — prepended to PATH
    /// when discovering tool binaries.
    var ffmpegDir: String?
    /// CF AI Gateway account ID.
    var cloudflareAccountId: String?
    /// CF AI Gateway ID (defaults to "default" if empty).
    var cfAigGatewayId: String?
    /// CF AI Gateway auth token (preferred over `anthropicApiKey`).
    var cfAigToken: String?
    /// Bring-your-own Anthropic key. Leave empty when using CF unified billing.
    var anthropicApiKey: String?

    // MARK: - Legacy fields (decoded from disk for back-compat, not surfaced in UI)

    /// Formerly the Node binary path. No longer used — kept for JSON round-trip
    /// compatibility with existing `~/.smartcut/config.json` files.
    var nodePath: String?
    /// Formerly the quietcut-server bundle path. No longer used.
    var sidecarPath: String?

    // MARK: - Defaults

    static let `default` = AppConfig(
        ffmpegDir: "/opt/homebrew/bin",
        cloudflareAccountId: nil,
        cfAigGatewayId: "default",
        cfAigToken: nil,
        anthropicApiKey: nil,
        nodePath: nil,
        sidecarPath: nil
    )

    /// Returns true when the gateway can authenticate: an account ID plus
    /// either a CF Gateway token (unified billing) or an Anthropic API key.
    var hasRequiredSecrets: Bool {
        guard let account = cloudflareAccountId, !account.isEmpty else { return false }
        let hasCfToken   = !(cfAigToken ?? "").isEmpty
        let hasAnthropic = !(anthropicApiKey ?? "").isEmpty
        return hasCfToken || hasAnthropic
    }

    /// Return a copy with empty strings converted to `nil` and defaults applied.
    /// Called before saving from `FirstRunSheet` and `CredentialsSettingsView`.
    func trimmedForSave() -> AppConfig {
        AppConfig(
            ffmpegDir: nilIfEmpty(ffmpegDir) ?? "/opt/homebrew/bin",
            cloudflareAccountId: nilIfEmpty(cloudflareAccountId),
            cfAigGatewayId: nilIfEmpty(cfAigGatewayId) ?? "default",
            cfAigToken: nilIfEmpty(cfAigToken),
            anthropicApiKey: nilIfEmpty(anthropicApiKey),
            nodePath: nil,      // do not persist legacy fields
            sidecarPath: nil
        )
    }

    private func nilIfEmpty(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    // MARK: - Persistence

    /// `~/.smartcut/config.json`
    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".smartcut/config.json")
    }

    static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: fileURL),
              var decoded = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return .default }

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
            withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try data.write(to: url, options: [.atomic])
        // 0600 — best-effort, file holds secrets.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
