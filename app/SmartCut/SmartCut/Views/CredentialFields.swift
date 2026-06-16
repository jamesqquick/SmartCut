import AppKit
import SwiftUI

/// Credential and binary-path fields shared between `FirstRunSheet`
/// (onboarding) and `CredentialsSettingsView` (Settings → Credentials tab).
///
/// `onSave` is called when any field commits (Return key or Browse panel).
/// The caller decides what "save" means — the onboarding sheet calls it as
/// a no-op and saves explicitly via its Save button; the Settings tab calls
/// `appState.saveConfig` immediately.
struct CredentialFields: View {
    @Binding var config: AppConfig
    var onSave: () -> Void

    @State private var showsAdvancedPaths = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            credentialsSection
            pathsSection
        }
    }

    // MARK: - Sections

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Cloudflare AI Gateway")

            field(
                "Account ID",
                placeholder: "e.g. 4426cbeacb457b1ca1b865d6c36ced0d",
                text: Binding(
                    get: { config.cloudflareAccountId ?? "" },
                    set: { config.cloudflareAccountId = $0 }
                ),
                hint: "From the Cloudflare dashboard URL."
            )

            field(
                "Gateway ID",
                placeholder: "default",
                text: Binding(
                    get: { config.cfAigGatewayId ?? "default" },
                    set: { config.cfAigGatewayId = $0 }
                ),
                hint: "Created on first authenticated request."
            )

            secureField(
                "Gateway token",
                placeholder: "cfut_…",
                text: Binding(
                    get: { config.cfAigToken ?? "" },
                    set: { config.cfAigToken = $0 }
                ),
                hint: "Unified billing (recommended)."
            )

            DisclosureGroup("Use a direct Anthropic key instead") {
                secureField(
                    "Anthropic API key",
                    placeholder: "sk-ant-…",
                    text: Binding(
                        get: { config.anthropicApiKey ?? "" },
                        set: { config.anthropicApiKey = $0 }
                    ),
                    hint: "Only fill this in if you skip the gateway."
                )
                .padding(.top, 6)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private var pathsSection: some View {
        DisclosureGroup("Advanced — binary paths", isExpanded: $showsAdvancedPaths) {
            VStack(alignment: .leading, spacing: 10) {
                pathField(
                    "node",
                    placeholder: "/opt/homebrew/bin/node",
                    text: Binding(
                        get: { config.nodePath ?? "" },
                        set: { config.nodePath = $0 }
                    )
                )
                pathField(
                    "Sidecar bundle",
                    placeholder: "/Users/you/code/SmartCut/packages/quietcut-server/dist/server.cjs",
                    text: Binding(
                        get: { config.sidecarPath ?? "" },
                        set: { config.sidecarPath = $0 }
                    )
                )
                pathField(
                    "ffmpeg directory",
                    placeholder: "/opt/homebrew/bin",
                    text: Binding(
                        get: { config.ffmpegDir ?? "" },
                        set: { config.ffmpegDir = $0 }
                    )
                )
            }
            .padding(.top, 6)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.top, 8)
    }

    // MARK: - Field builders

    private func sectionTitle(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }

    private func field(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        hint: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            TextField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { onSave() }
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func secureField(
        _ label: String,
        placeholder: String,
        text: Binding<String>,
        hint: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            SecureField(placeholder, text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { onSave() }
            if let hint {
                Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func pathField(
        _ label: String,
        placeholder: String,
        text: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 12, weight: .medium))
            HStack(spacing: 8) {
                TextField(placeholder, text: text)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { onSave() }
                Button("Browse…") { browse(into: text) }
            }
        }
    }

    private func browse(into binding: Binding<String>) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            binding.wrappedValue = url.path
            onSave()
        }
    }
}
