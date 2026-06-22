import AppKit
import Sparkle
import SwiftUI

/// Ensures the Node sidecar is killed when the app quits. Without this the
/// sidecar was orphaned to launchd on every quit and lingered (historically
/// pegging a CPU core), accumulating across launches. This covers normal
/// termination — Cmd+Q, the Quit menu, `NSApp.terminate`, last-window-close.
/// It cannot run when the app itself is hard-killed (e.g. Xcode's Stop button
/// sends SIGKILL); that case is handled separately by the sidecar's own
/// parent-death watchdog (companion change in the quietcut-server package).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared?.sidecar.terminateNow()
    }
}

@main
struct SmartCutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    // Hold a strong reference so the updater is not deallocated.
    // Initialised here with startingUpdater: true so Sparkle begins its
    // background check on first launch (after requesting user permission).
    private let updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
    )

    var body: some Scene {
        WindowGroup("SmartCut") {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
                .environment(appState)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                CheckForUpdatesView(updater: updaterController.updater)
            }
        }

        Settings {
            SettingsWindow()
                .environment(appState)
        }
    }
}
