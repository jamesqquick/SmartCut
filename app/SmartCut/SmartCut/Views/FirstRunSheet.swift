import AppKit
import SwiftUI

/// Shown the first time the app launches (or whenever `AppConfig` is
/// missing required secrets). Collects paths + Cloudflare AI Gateway
/// credentials and persists them to `~/.smartcut/config.json`.
struct FirstRunSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AppConfig
    @State private var showsAdvancedPaths: Bool = false
    @State private var saveError: String?

    init(initial: AppConfig) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            VStack(alignment: .leading, spacing: 14) {
                credentialsSection
                pathsSection
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(28)
        .frame(width: 520)
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Set up SmartCut").font(.system(size: 20, weight: .semibold))
            Text(
                "SmartCut needs Cloudflare AI Gateway credentials to run retake detection. These are stored in ~/.smartcut/config.json."
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var credentialsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Cloudflare AI Gateway")

            field(
                "Account ID",
                placeholder: "e.g. 4426cbeacb457b1ca1b865d6c36ced0d",
                text: Binding(
                    get: { draft.cloudflareAccountId ?? "" },
                    set: { draft.cloudflareAccountId = $0 }
                ),
                hint: "From the Cloudflare dashboard URL."
            )

            field(
                "Gateway ID",
                placeholder: "default",
                text: Binding(
                    get: { draft.cfAigGatewayId ?? "default" },
                    set: { draft.cfAigGatewayId = $0 }
                ),
                hint: "Created on first authenticated request."
            )

            secureField(
                "Gateway token",
                placeholder: "cfut_…",
                text: Binding(
                    get: { draft.cfAigToken ?? "" },
                    set: { draft.cfAigToken = $0 }
                ),
                hint: "Unified billing (recommended)."
            )

            DisclosureGroup("Use a direct Anthropic key instead") {
                secureField(
                    "Anthropic API key",
                    placeholder: "sk-ant-…",
                    text: Binding(
                        get: { draft.anthropicApiKey ?? "" },
                        set: { draft.anthropicApiKey = $0 }
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
                        get: { draft.nodePath ?? "" },
                        set: { draft.nodePath = $0 }
                    )
                )
                pathField(
                    "Sidecar bundle",
                    placeholder:
                        "/Users/you/code/SmartCut/packages/quietcut-server/dist/server.cjs",
                    text: Binding(
                        get: { draft.sidecarPath ?? "" },
                        set: { draft.sidecarPath = $0 }
                    )
                )
                pathField(
                    "ffmpeg directory",
                    placeholder: "/opt/homebrew/bin",
                    text: Binding(
                        get: { draft.ffmpegDir ?? "" },
                        set: { draft.ffmpegDir = $0 }
                    )
                )
            }
            .padding(.top, 6)
        }
        .font(.system(size: 12, weight: .semibold))
        .padding(.top, 8)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = saveError {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!draft.hasRequiredSecrets)
            }
        }
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
        }
    }

    // MARK: - Save

    private func save() {
        let trimmed = AppConfig(
            nodePath: emptyToNil(draft.nodePath),
            ffmpegDir: emptyToNil(draft.ffmpegDir) ?? "/opt/homebrew/bin",
            sidecarPath: emptyToNil(draft.sidecarPath),
            cloudflareAccountId: emptyToNil(draft.cloudflareAccountId),
            cfAigGatewayId: emptyToNil(draft.cfAigGatewayId) ?? "default",
            cfAigToken: emptyToNil(draft.cfAigToken),
            anthropicApiKey: emptyToNil(draft.anthropicApiKey)
        )

        appState.saveConfig(trimmed)
        if let err = appState.errorMessage {
            saveError = err
            return
        }
        dismiss()
    }

    private func emptyToNil(_ s: String?) -> String? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty
        else { return nil }
        return s
    }
}
