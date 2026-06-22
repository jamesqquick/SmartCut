import Sparkle
import SwiftUI

/// Menu-item button that triggers Sparkle's update check.
///
/// Note: we intentionally do not gate this on `canCheckForUpdates`.
/// SwiftUI on macOS has a known quirk where a `CommandGroup` item that
/// starts in a `.disabled(true)` state is never rendered — it simply
/// doesn't appear in the menu. Because `canCheckForUpdates` is `false`
/// until Sparkle finishes initialising, using `.disabled` here causes
/// the item to be invisible on launch and never recover. Sparkle handles
/// concurrent / redundant `checkForUpdates()` calls gracefully (no-op),
/// so leaving the button always enabled is safe.
struct CheckForUpdatesView: View {
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates\u{2026}", action: updater.checkForUpdates)
    }
}
