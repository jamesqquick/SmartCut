import Combine
import Sparkle
import SwiftUI

/// Observes `SPUUpdater.canCheckForUpdates` via KVO/Combine so the
/// menu button can disable itself reactively while a check is in progress.
/// SPUUpdater is an NSObject but does not conform to ObservableObject
/// directly, so this thin wrapper bridges it.
final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        // assign(to:) binds the upstream publisher directly to the @Published
        // property and manages the lifetime internally — no AnyCancellable needed.
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var viewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        self.viewModel = CheckForUpdatesViewModel(updater: updater)
    }

    var body: some View {
        Button("Check for Updates\u{2026}", action: updater.checkForUpdates)
            .disabled(!viewModel.canCheckForUpdates)
    }
}
