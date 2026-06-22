import AppKit
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
