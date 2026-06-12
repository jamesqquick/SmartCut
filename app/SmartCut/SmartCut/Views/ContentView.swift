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
                SettingsView()
            case .running:
                PipelineRunningView()
            case .review:
                RetakeReviewView()
            case .render:
                RenderProgressView()
            case .done:
                DoneView()
            }
        }
        .environment(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
