import AppKit
import Sparkle
import SwiftUI

/// Ensures any running pipeline job is cancelled cleanly when the app quits.
/// This covers normal termination — Cmd+Q, the Quit menu, NSApp.terminate,
/// last-window-close — and kills any live ffmpeg/whisper child process.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared?.engine.terminateNow()
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
