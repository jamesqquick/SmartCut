import SwiftUI

/// Top-level container view. Real screen routing arrives in Phase 3.4 once
/// `AppState` exists; for now this is a placeholder that proves the project
/// builds and launches.
struct ContentView: View {
    var body: some View {
        VStack(spacing: 16) {
            Text("SmartCut")
                .font(.system(size: 28, weight: .semibold))
            Text("Scaffolding — UI lands in Phase 3.4+")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

#Preview {
    ContentView()
        .frame(width: 960, height: 640)
}
