import SwiftUI

/// Root view. Switches between the six screens declared in `AppState.Screen`.
/// Owns a single `AppState` for the whole window.
struct ContentView: View {
    @State private var appState = AppState()

    var body: some View {
        ZStack(alignment: .top) {
            screen
            if let message = appState.errorMessage {
                ErrorBanner(message: message)
                    .transition(
                        .move(edge: .top).combined(with: .opacity)
                    )
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: appState.errorMessage)
        .environment(appState)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .sheet(
            isPresented: Binding(
                get: { appState.needsFirstRunConfig },
                set: { newValue in
                    if !newValue { appState.needsFirstRunConfig = false }
                }
            )
        ) {
            FirstRunSheet(initial: appState.config)
                .environment(appState)
        }
    }

    @ViewBuilder
    private var screen: some View {
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
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
