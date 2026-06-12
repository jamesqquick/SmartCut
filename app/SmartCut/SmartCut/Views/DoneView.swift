import AppKit
import SwiftUI

struct DoneView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        AppShell {
            sidebar
        } content: {
            content
        }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        StepperView()

        if let summary = appState.summary {
            VStack(alignment: .leading, spacing: 0) {
                SidebarSectionHeader("Session")
                row("Output", summary.outputPath.lastPathComponent)
                row("Total time", Formatters.shortDuration(summary.elapsedSec))
                row("Silence cuts", "\(summary.silenceCuts)")
                row("Retake cuts", "\(summary.retakeCuts)")
                row("Retakes kept", "\(summary.retakesKept)")
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium))
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 0) {
            Spacer()
            card
                .frame(maxWidth: 560)
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var card: some View {
        if let summary = appState.summary {
            VStack(spacing: 20) {
                checkmark
                Text("Smart cut complete").font(.system(size: 22, weight: .semibold))
                HStack(spacing: 4) {
                    Text("Saved to").foregroundStyle(.secondary)
                    Text(summary.outputPath.path)
                        .font(.system(size: 12, design: .monospaced))
                }
                .font(.system(size: 13))

                summaryGrid(summary: summary)

                Text(detailLine(summary: summary))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)

                actionButtons(summary: summary)
                    .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
                    )
            )
        } else {
            ProgressView("Finishing up…")
        }
    }

    private var checkmark: some View {
        ZStack {
            Circle().fill(Color.green.opacity(0.18))
                .frame(width: 64, height: 64)
            Image(systemName: "checkmark")
                .font(.system(size: 28, weight: .bold))
                .foregroundStyle(.green)
        }
    }

    private func summaryGrid(summary: DoneSummary) -> some View {
        let finalDuration = max(0, summary.originalDuration - summary.savedSec)
        return HStack(spacing: 12) {
            summaryTile(
                label: "Original",
                value: Formatters.duration(summary.originalDuration)
            )
            summaryTile(
                label: "Final",
                value: Formatters.duration(finalDuration)
            )
            summaryTile(
                label: "Saved",
                value: "\(Formatters.shortDuration(summary.savedSec)) (\(Formatters.percent(summary.savedPercent, fractionDigits: 1)))",
                tint: .green
            )
        }
    }

    private func summaryTile(label: String, value: String, tint: Color = .primary) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .underPageBackgroundColor))
        )
    }

    private func detailLine(summary: DoneSummary) -> String {
        var parts: [String] = []
        parts.append("\(summary.silenceCuts) silence region\(summary.silenceCuts == 1 ? "" : "s") removed")
        parts.append("\(summary.retakeCuts) retake\(summary.retakeCuts == 1 ? "" : "s") cut")
        if summary.retakesKept > 0 {
            parts.append("\(summary.retakesKept) kept")
        }
        return parts.joined(separator: " · ")
    }

    private func actionButtons(summary: DoneSummary) -> some View {
        HStack(spacing: 12) {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([summary.outputPath])
            } label: {
                Text("Reveal in Finder").frame(minWidth: 140)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)

            Button {
                NSWorkspace.shared.open(summary.outputPath)
            } label: {
                Text("Open").frame(minWidth: 100)
            }
            .controlSize(.large)

            Button {
                appState.resetToDrop()
            } label: {
                Text("Process another").frame(minWidth: 140)
            }
            .controlSize(.large)
        }
    }
}

#Preview {
    DoneView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
