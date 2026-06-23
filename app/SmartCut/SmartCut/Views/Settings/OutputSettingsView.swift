import AppKit
import SwiftUI

/// Settings → Output tab. Edits `AppPreferences` render quality and the
/// default output folder. Saves to disk on every field change.
struct OutputSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        return Form {
            Section("Output") {
                Picker("Encoder", selection: $appState.preferences.encoder) {
                    Text("Auto (hardware when available)").tag("auto")
                    Text("Software (libx264)").tag("software")
                }
                .help(
                    "Auto uses Apple VideoToolbox hardware encoding when available "
                        + "(much faster), falling back to libx264. Software always uses "
                        + "libx264, which is slower but more bitrate-efficient."
                )

                if appState.preferences.encoder == "software" {
                    Picker("Software preset", selection: $appState.preferences.preset) {
                        Text("Ultra fast").tag("ultrafast")
                        Text("Super fast").tag("superfast")
                        Text("Very fast").tag("veryfast")
                        Text("Faster").tag("faster")
                        Text("Fast").tag("fast")
                        Text("Medium").tag("medium")
                        Text("Slow").tag("slow")
                        Text("Slower").tag("slower")
                    }
                    .help("Faster presets encode quicker but produce larger files at the same quality.")
                }

                LabeledContent("Quality (CRF)") {
                    HStack(spacing: 8) {
                        TextField("", value: $appState.preferences.crf, format: .number)
                            .frame(width: 50)
                        Stepper("", value: $appState.preferences.crf, in: 12...30)
                            .labelsHidden()
                        Text("12 – 30").foregroundStyle(.secondary).font(.callout)
                    }
                }
                LabeledContent("Default output folder") {
                    HStack(spacing: 10) {
                        Text(appState.preferences.outputDirectory ?? "Same folder as source")
                            .font(.system(.callout, design: .monospaced))
                            .foregroundStyle(
                                appState.preferences.outputDirectory == nil
                                    ? Color.secondary
                                    : Color.primary
                            )
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Button("Choose…") { browseForFolder() }
                        if appState.preferences.outputDirectory != nil {
                            Button("Clear") {
                                appState.preferences.outputDirectory = nil
                            }
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.preferences) { _, _ in
            appState.savePreferences()
        }
    }

    private func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose the default folder for output files"
        if panel.runModal() == .OK, let url = panel.url {
            appState.preferences.outputDirectory = url.path
        }
    }
}
