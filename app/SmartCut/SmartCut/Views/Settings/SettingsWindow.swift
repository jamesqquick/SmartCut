import SwiftUI

/// The native macOS Settings window (⌘,). A tab view with Detection,
/// Output, and Credentials panes. The active tab is driven by
/// `AppState.settingsTab` so other parts of the app can deep-link to a
/// specific pane (e.g. the credentials banner on the drop screen).
struct SettingsWindow: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        TabView(selection: $appState.settingsTab) {
            DetectionSettingsView()
                .tabItem { Label("Detection", systemImage: "waveform") }
                .tag(AppState.SettingsTab.detection)

            OutputSettingsView()
                .tabItem { Label("Output", systemImage: "film") }
                .tag(AppState.SettingsTab.output)

            CredentialsSettingsView()
                .tabItem { Label("Credentials", systemImage: "key") }
                .tag(AppState.SettingsTab.credentials)
        }
        .frame(width: 480)
    }
}
