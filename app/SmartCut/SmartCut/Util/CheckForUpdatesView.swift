import Sparkle
import SwiftUI

/// A menu-item button that triggers Sparkle's update check.
/// `SPUUpdater` is an `ObservableObject`, so `canCheckForUpdates` drives
/// the disabled state reactively — the button auto-disables while a check
/// is already in progress.
struct CheckForUpdatesView: View {
    @ObservedObject var updater: SPUUpdater

    var body: some View {
        Button("Check for Updates\u{2026}") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
    }
}
