import AppKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        return AppShell {
            StepperView()
        } content: {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    fileCard
                    silenceForm(binding: $appState)
                    retakeForm(binding: $appState)
                    outputForm(binding: $appState)
                    actionRow
                }
                .padding(.horizontal, 36)
                .padding(.vertical, 28)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review settings").font(.system(size: 22, weight: .semibold))
            Text("These mirror the quietcut smartcut CLI flags. Defaults match the CLI.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var fileCard: some View {
        if let url = appState.droppedFile {
            HStack(spacing: 14) {
                Text("🎬").font(.system(size: 32))
                VStack(alignment: .leading, spacing: 4) {
                    Text(url.lastPathComponent)
                        .font(.system(size: 14, weight: .medium))
                    Text(metadataLine).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Change…") { appState.resetToDrop() }
                    .controlSize(.small)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
        }
    }

    private var metadataLine: String {
        guard let md = appState.metadata else { return "—" }
        var parts: [String] = [Formatters.duration(md.durationSec)]
        if let w = md.width, let h = md.height { parts.append("\(w)×\(h)") }
        if let c = md.codec { parts.append(c) }
        parts.append(Formatters.bytes(md.sizeBytes))
        return parts.joined(separator: " · ")
    }

    // MARK: - Forms

    private func silenceForm(binding: Bindable<AppState>) -> some View {
        FormSection(title: "Silence detection") {
            LabeledNumber(
                label: "Threshold",
                hint: "Below this is considered silence",
                unit: "dB",
                value: binding.options.thresholdDb,
                format: "%.0f"
            )
            LabeledNumber(
                label: "Minimum length",
                hint: "Cut silences this long or longer",
                unit: "seconds",
                value: binding.options.minSilence,
                format: "%.1f",
                step: 0.1
            )
        }
    }

    private func retakeForm(binding: Bindable<AppState>) -> some View {
        FormSection(title: "AI retake detection") {
            HStack(alignment: .center, spacing: 24) {
                Text("Model").frame(width: 160, alignment: .leading)
                Picker("", selection: binding.options.model) {
                    Text("claude-opus-4-8").tag("claude-opus-4-8")
                    Text("claude-sonnet-4-5").tag("claude-sonnet-4-5")
                    Text("claude-haiku-4-5").tag("claude-haiku-4-5")
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
                Spacer()
            }

            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Passes")
                    Text("Later passes re-clean leftovers")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 160, alignment: .leading)
                Stepper(value: binding.options.passes, in: 1...4) {
                    Text("\(appState.options.passes)").frame(width: 30, alignment: .trailing)
                }
                .labelsHidden()
                Spacer()
            }

            HStack(alignment: .center, spacing: 24) {
                Text("Whisper model").frame(width: 160, alignment: .leading)
                Picker("", selection: binding.options.whisperModel) {
                    Text("base.en").tag("base.en")
                    Text("small.en").tag("small.en")
                    Text("medium.en").tag("medium.en")
                }
                .labelsHidden()
                .frame(maxWidth: 200, alignment: .leading)
                Spacer()
            }
        }
    }

    private func outputForm(binding: Bindable<AppState>) -> some View {
        FormSection(title: "Output") {
            HStack(alignment: .center, spacing: 24) {
                Text("Save to").frame(width: 160, alignment: .leading)
                TextField("Output path", text: binding.options.output)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 380)
                Button("Browse…") { browseForOutput() }
                Spacer()
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quality (CRF)")
                    Text("Lower = better quality, larger file")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .frame(width: 160, alignment: .leading)
                Stepper(value: binding.options.crf, in: 12...30) {
                    Text("\(appState.options.crf)").frame(width: 30, alignment: .trailing)
                }
                .labelsHidden()
                Spacer()
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 12) {
            Button(action: { Task { await appState.startProcessing() } }) {
                Text("Start smart cut").frame(minWidth: 140)
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)

            Button("Cancel") { appState.resetToDrop() }
                .controlSize(.large)

            Spacer()
        }
        .padding(.top, 8)
    }

    private func browseForOutput() {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [.mpeg4Movie]
        if !appState.options.output.isEmpty {
            let url = URL(fileURLWithPath: appState.options.output)
            panel.directoryURL = url.deletingLastPathComponent()
            panel.nameFieldStringValue = url.lastPathComponent
        }
        if panel.runModal() == .OK, let url = panel.url {
            appState.options.output = url.path
        }
    }
}

// MARK: - Form primitives

private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.system(size: 14, weight: .semibold))
            content
        }
        .padding(.vertical, 8)
    }
}

private struct LabeledNumber: View {
    let label: String
    let hint: String?
    let unit: String?
    @Binding var value: Double
    let format: String
    var step: Double = 1

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let hint {
                    Text(hint).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 160, alignment: .leading)
            HStack(spacing: 8) {
                TextField("", value: $value, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                Stepper("", value: $value, step: step).labelsHidden()
                if let unit {
                    Text(unit).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

#Preview {
    SettingsView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
