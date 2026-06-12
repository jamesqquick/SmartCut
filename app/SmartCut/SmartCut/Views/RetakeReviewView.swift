import SwiftUI

struct RetakeReviewView: View {
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

        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Decisions so far")
            decisionRow(
                "Removed",
                "\(appState.removedCount)",
                tint: .red
            )
            decisionRow("Kept", "\(appState.keptCount)", tint: .yellow)
            decisionRow("Pending", "\(max(0, appState.retakeTotal - appState.decisions.count))")
            HStack {
                Text("Est. time saved")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Formatters.shortDuration(appState.savedSoFar))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.green)
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 10)
        }
    }

    private func decisionRow(_ label: String, _ value: String, tint: Color = .primary) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
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
                header
                progressBar
                if let proposal = appState.currentRetake {
                    RetakeCardView(proposal: proposal)
                } else {
                    waitingPlaceholder
                }
            }
            .padding(.horizontal, 36)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Review proposed cuts")
                .font(.system(size: 22, weight: .semibold))
            HStack(spacing: 6) {
                Text("Listen to each cut and choose. Keyboard:")
                    .foregroundStyle(.secondary)
                kbd("R"); Text("remove").foregroundStyle(.secondary)
                kbd("K"); Text("keep").foregroundStyle(.secondary)
                kbd("A"); Text("approve all").foregroundStyle(.secondary)
                kbd("Esc"); Text("cancel").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
        }
    }

    private func kbd(_ key: String) -> some View {
        Text(key)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
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
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(nsColor: .separatorColor).opacity(0.4))
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.accentColor)
                        .frame(width: max(0, geo.size.width * pct))
                        .animation(.easeOut(duration: 0.2), value: pct)
                }
            }
            .frame(height: 6)
            Text("\(appState.removedCount) removed")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.green)
        }
        .padding(.vertical, 4)
    }

    private var waitingPlaceholder: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("Waiting for the next proposal…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}

#Preview {
    RetakeReviewView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
