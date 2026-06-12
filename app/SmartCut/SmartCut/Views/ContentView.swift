import SwiftUI

/// Root view. Switches between the six screens declared in `AppState.Screen`.
/// Owns a single `AppState` for the whole window.
struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        Group {
            switch appState.screen {
            case .drop:
                DropZoneView()
            case .settings:
                ScreenPlaceholder(title: "Review settings", screen: .settings)
            case .running:
                ScreenPlaceholder(title: "Processing…", screen: .running)
            case .review:
                ScreenPlaceholder(title: "Review proposed cuts", screen: .review)
            case .render:
                ScreenPlaceholder(title: "Rendering", screen: .render)
            case .done:
                ScreenPlaceholder(title: "Smart cut complete", screen: .done)
            }
        }
        .environment(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

/// Placeholder used between Phase 3.4 and the screen-specific commits in
/// Phase 3.5. Replaced view-by-view as each screen lands.
private struct ScreenPlaceholder: View {
    @Environment(AppState.self) private var appState

    let title: String
    let screen: AppState.Screen

    var body: some View {
        VStack(spacing: 16) {
            Text(title).font(.system(size: 22, weight: .semibold))
            Text("Screen: \(String(describing: screen))")
                .foregroundStyle(.secondary)
                .font(.system(size: 13))
            // Quick devkit so we can flip between screens before the real
            // views exist; this gets removed when DropZoneView ships.
            HStack(spacing: 8) {
                screenButton(.drop, "Drop")
                screenButton(.settings, "Settings")
                screenButton(.running, "Running")
                screenButton(.review, "Review")
                screenButton(.render, "Render")
                screenButton(.done, "Done")
            }
            .padding(.top, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func screenButton(_ target: AppState.Screen, _ label: String) -> some View {
        Button(label) { appState.screen = target }
            .buttonStyle(.bordered)
    }
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
