import SwiftUI

@main
struct SmartCutApp: App {
    var body: some Scene {
        WindowGroup("SmartCut") {
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
