import SwiftUI

/// Settings → Detection tab. Edits `AppPreferences` silence and retake
/// fields. Saves to disk on every field change.
struct DetectionSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        return Form {
            Section("Silence detection") {
                LabeledContent("Threshold") {
                    HStack(spacing: 8) {
                        TextField("", value: $appState.preferences.thresholdDb, format: .number)
                            .frame(width: 72)
                        Stepper("", value: $appState.preferences.thresholdDb, step: 1)
                            .labelsHidden()
                        Text("dB").foregroundStyle(.secondary).font(.callout)
                    }
                }
                LabeledContent("Minimum length") {
                    HStack(spacing: 8) {
                        TextField("", value: $appState.preferences.minSilence, format: .number)
                            .frame(width: 72)
                        Stepper("", value: $appState.preferences.minSilence, step: 0.1)
                            .labelsHidden()
                        Text("seconds").foregroundStyle(.secondary).font(.callout)
                    }
                }
            }

            Section("AI retake detection") {
                Picker("Model", selection: $appState.preferences.model) {
                    Text("claude-opus-4-8").tag("claude-opus-4-8")
                    Text("claude-sonnet-4-5").tag("claude-sonnet-4-5")
                    Text("claude-haiku-4-5").tag("claude-haiku-4-5")
                }
                LabeledContent("Passes") {
                    HStack(spacing: 8) {
                        TextField("", value: $appState.preferences.passes, format: .number)
                            .frame(width: 50)
                        Stepper("", value: $appState.preferences.passes, in: 1...4)
                            .labelsHidden()
                    }
                }
                Picker("Whisper model", selection: $appState.preferences.whisperModel) {
                    Text("base.en").tag("base.en")
                    Text("small.en").tag("small.en")
                    Text("medium.en").tag("medium.en")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.preferences) { _, _ in
            appState.savePreferences()
        }
    }
}
