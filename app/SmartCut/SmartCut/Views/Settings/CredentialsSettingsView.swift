import SwiftUI

/// Settings → Credentials tab. Edits `AppConfig` (API keys + binary paths).
/// Uses the shared `CredentialFields` view. Saves on field submit (Return)
/// and also when the pane disappears (window closed or tab switched).
struct CredentialsSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var draft: AppConfig = .default

    var body: some View {
        ScrollView {
            CredentialFields(config: $draft, onSave: save)
                .padding(20)
        }
        .onAppear {
            draft = appState.config
        }
        .onDisappear {
            save()
        }
    }

    private func save() {
        appState.saveConfig(draft.trimmedForSave())
    }
}
