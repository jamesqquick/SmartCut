import AppKit
import SwiftUI

struct DoneView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

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
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink)
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
        .background(alignment: .topTrailing) {
            Theme.halo(colorScheme)
                .frame(width: 720, height: 520)
                .offset(x: 160, y: -140)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var card: some View {
        if let summary = appState.summary {
            VStack(spacing: 20) {
                checkmark
                Text("Smart cut complete")
                    .font(.system(size: 26, weight: .light))
                    .gradientTitle(colorScheme)
                HStack(spacing: 4) {
                    Text("Saved to").foregroundStyle(Theme.muted)
                    Text(summary.outputPath.path)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.bodyText)
                }
                .font(.system(size: 13))

                summaryGrid(summary: summary)

                Text(detailLine(summary: summary))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.top, 2)

                actionButtons(summary: summary)
                    .padding(.top, 8)
            }
            .padding(28)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(Theme.elevated)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(Theme.border, lineWidth: 1)
                    )
                    .shadow(color: Color(srgb: 0x32325D).opacity(0.12), radius: 24, x: 0, y: 12)
            )
        } else {
            ProgressView("Finishing up…")
        }
    }

    private var checkmark: some View {
        ZStack {
            Circle().fill(Theme.wash)
                .frame(width: 64, height: 64)
            Image(systemName: "checkmark")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(Theme.indigo)
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
                tint: Theme.good
            )
        }
    }

    private func summaryTile(label: String, value: String, tint: Color = Theme.ink) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .regular))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
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
                Text("Reveal in Finder")
            }
            .buttonStyle(.scPrimary)
            .keyboardShortcut(.defaultAction)

            Button {
                NSWorkspace.shared.open(summary.outputPath)
            } label: {
                Text("Open").frame(minWidth: 64)
            }
            .buttonStyle(.scSecondary)

            Button {
                appState.resetToDrop()
            } label: {
                Text("Process another")
            }
            .buttonStyle(.scGhost)
        }
    }
}

#Preview {
    DoneView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
