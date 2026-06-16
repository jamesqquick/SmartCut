import SwiftUI

/// Shown the first time the app launches (or whenever `AppConfig` is
/// missing required secrets). Collects paths + Cloudflare AI Gateway
/// credentials and persists them to `~/.smartcut/config.json`.
/// After first launch, all credential edits happen in Settings → Credentials.
struct FirstRunSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var draft: AppConfig
    @State private var saveError: String?

    init(initial: AppConfig) {
        _draft = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            CredentialFields(config: $draft, onSave: { })
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

    // MARK: - Save

    private func save() {
        appState.saveConfig(draft.trimmedForSave())
        if let err = appState.errorMessage {
            saveError = err
            return
        }
        dismiss()
    }
}
