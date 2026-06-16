import SwiftUI

/// Root view. Switches between the screens declared in `AppState.Screen`.
/// `AppState` is owned by `SmartCutApp` and injected into the environment
/// so the `Settings {}` scene can share the same instance.
struct ContentView: View {
    @Environment(AppState.self) private var appState

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
        case .running:
            PipelineRunningView()
        case .review:
            TranscriptReviewView()
        case .render:
            RenderProgressView()
        case .done:
            DoneView()
        }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
