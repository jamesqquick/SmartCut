import SwiftUI

struct RetakeReviewView: View {
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

        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Decisions so far")
            decisionRow(
                "Removed",
                "\(appState.removedCount)",
                tint: Theme.danger
            )
            decisionRow("Kept", "\(appState.keptCount)", tint: Theme.warn)
            decisionRow("Pending", "\(max(0, appState.retakeTotal - appState.decisions.count))")
            HStack {
                Text("Est. time saved")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text(Formatters.shortDuration(appState.savedSoFar))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.good)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
        }
    }

    private func decisionRow(_ label: String, _ value: String, tint: Color = Theme.ink) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }

    // MARK: - Content

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if appState.awaitingReviewConfirmation {
                    noRetakesConfirmation
                } else {
                    header
                    progressBar
                    if let proposal = appState.currentRetake {
                        RetakeCardView(proposal: proposal)
                    } else {
                        waitingPlaceholder
                    }
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var noRetakesConfirmation: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("No retakes detected")
                    .font(.system(size: 28, weight: .light))
                    .gradientTitle(colorScheme)
                Text("Only silence cuts will be applied. Render the result?")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.bodyText)
            }
            HStack(spacing: 12) {
                Button(action: { Task { await appState.confirmRender() } }) {
                    Text("Render").frame(minWidth: 100)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.scPrimary)

                Button("Cancel") { Task { await appState.cancel() } }
                    .buttonStyle(.scSecondary)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REVIEW")
                .font(.system(size: 10, weight: .regular))
                .tracking(0.8)
                .foregroundStyle(Theme.muted)
            Text("Proposed cuts")
                .font(.system(size: 28, weight: .light))
                .gradientTitle(colorScheme)
            HStack(spacing: 6) {
                Text("Listen to each cut and choose. Keyboard:")
                    .foregroundStyle(Theme.muted)
                kbd("R"); Text("remove").foregroundStyle(Theme.muted)
                kbd("K"); Text("keep").foregroundStyle(Theme.muted)
                kbd("A"); Text("approve all").foregroundStyle(Theme.muted)
                kbd("Esc"); Text("cancel").foregroundStyle(Theme.muted)
            }
            .font(.system(size: 11))
        }
    }

    private func kbd(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.bodyText)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .stroke(Theme.borderStrong, lineWidth: 1)
            )
    }

    private var progressBar: some View {
        let total = appState.retakeTotal
        let currentIndex = appState.currentRetake?.index ?? appState.decisions.count
        let oneBasedCurrent = min(currentIndex + 1, max(total, 1))
        let pct = total > 0 ? Double(appState.decisions.count) / Double(total) : 0

        return HStack(spacing: 16) {
            Text("Cut \(oneBasedCurrent) of \(total)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.muted)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(Theme.border)
                    RoundedRectangle(cornerRadius: Theme.radiusSmall)
                        .fill(Theme.indigo)
                        .frame(width: max(0, geo.size.width * pct))
                        .animation(.easeOut(duration: 0.2), value: pct)
                }
            }
            .frame(height: 6)
            Text("\(appState.removedCount) removed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.good)
        }
        .padding(.vertical, 4)
    }

    private var waitingPlaceholder: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Waiting for the next proposal…")
                .font(.system(size: 13))
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .stroke(Theme.border, lineWidth: 1)
                )
        )
    }
}

#Preview {
    RetakeReviewView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
