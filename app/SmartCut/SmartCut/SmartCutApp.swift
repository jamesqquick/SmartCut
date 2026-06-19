import AppKit
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
        }

        Settings {
            SettingsWindow()
                .environment(appState)
        }
    }
}
