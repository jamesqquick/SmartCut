import SwiftUI

/// Batch transcript review: shows the entire transcript with every AI-suggested
/// retake cut highlighted over the words. The user can resize any cut by
/// dragging its word-level handles (or with arrow keys), toggle cuts on/off,
/// then apply all changes at once.
struct TranscriptReviewView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    /// The cut currently being edited (its handles are shown + draggable).
    @State private var activeCutId: String?
    /// Frame of each transcript word in the "tx" coordinate space, for handle
    /// placement and drag hit-testing.
    @State private var wordFrames: [Int: CGRect] = [:]
    @FocusState private var transcriptFocused: Bool

    var body: some View {
        AppShell {
            sidebar
        } content: {
            content
        }
        .onAppear {
            if activeCutId == nil { activeCutId = appState.reviewCuts.first?.opId }
        }
    }

    private var activeCut: ReviewCutState? {
        appState.reviewCuts.first { $0.opId == activeCutId }
    }

    // MARK: - Sidebar

    @ViewBuilder
    private var sidebar: some View {
        StepperView()

        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader("Review")
            statRow("Cuts enabled", "\(appState.enabledCutCount) / \(appState.reviewCuts.count)")
            statRow(
                "Est. time saved",
                Formatters.shortDuration(appState.reviewSavedEstimate),
                tint: Theme.good
            )
            statRow("Words", "\(appState.transcript.count)")
        }
    }

    private func statRow(_ label: String, _ value: String, tint: Color = Theme.ink) -> some View {
        HStack {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.muted)
            Spacer()
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 10)
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 36)
                .padding(.top, 28)
                .padding(.bottom, 16)

            if !appState.reviewCuts.isEmpty {
                cutStrip
                    .padding(.horizontal, 36)
                    .padding(.bottom, 14)
            }

            Divider().background(Theme.border)

            transcriptScroll
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 6) {
                Text("REVIEW")
                    .font(.system(size: 10))
                    .tracking(0.8)
                    .foregroundStyle(Theme.muted)
                Text(appState.reviewCuts.isEmpty ? "No retakes detected" : "Review cuts")
                    .font(.system(size: 28, weight: .light))
                    .gradientTitle(colorScheme)
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.bodyText)
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") { Task { await appState.cancel() } }
                    .buttonStyle(.scSecondary)
                    .keyboardShortcut(.cancelAction)
                Button(action: { Task { await appState.applyReview() } }) {
                    Text(applyLabel).frame(minWidth: 120)
                }
                .buttonStyle(.scPrimary)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var headerSubtitle: String {
        if appState.reviewCuts.isEmpty {
            return "Only silence cuts will be applied. Render the result?"
        }
        return "Select a cut, then drag its handles (or use ← →, ⌥← ⌥→) to change which words are removed. Toggle a cut off to keep that take."
    }

    private var applyLabel: String {
        if appState.reviewCuts.isEmpty { return "Render" }
        return "Apply \(appState.enabledCutCount) cut\(appState.enabledCutCount == 1 ? "" : "s")"
    }

    // MARK: - Cut strip

    private var cutStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(Array(appState.reviewCuts.enumerated()), id: \.element.opId) { idx, cut in
                    cutChip(index: idx, cut: cut)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func cutChip(index: Int, cut: ReviewCutState) -> some View {
        let isActive = cut.opId == activeCutId
        return Button {
            activeCutId = cut.opId
            transcriptFocused = true
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Cut \(index + 1)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(cut.enabled ? Theme.ink : Theme.muted)
                    Spacer(minLength: 12)
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { cut.enabled },
                            set: { appState.setCutEnabled(cut.opId, $0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text("\(Int(cut.op.confidence))% confidence")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.muted)
                Text(Formatters.shortDuration(appState.estimatedDuration(cut)) + " removed")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(cut.enabled ? Theme.danger : Theme.muted)
            }
            .padding(10)
            .frame(width: 170, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(isActive ? Theme.wash : Theme.card)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .stroke(isActive ? Theme.indigo : Theme.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Transcript

    private var transcriptScroll: some View {
        ScrollView {
            ZStack(alignment: .topLeading) {
                WordFlowLayout(spacing: 4, lineSpacing: 8) {
                    ForEach(appState.transcript.indices, id: \.self) { i in
                        wordView(i)
                    }
                }
                handleOverlay
            }
            .coordinateSpace(name: "tx")
            .onPreferenceChange(WordFrameKey.self) { wordFrames = $0 }
            .padding(.horizontal, 36)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .focusable()
        .focused($transcriptFocused)
        .onKeyPress { press in handleKey(press) }
    }

    /// Enabled cut whose range covers word `index`, if any.
    private func cutContaining(_ index: Int) -> ReviewCutState? {
        appState.reviewCuts.first {
            $0.enabled && index >= $0.removeStartIndex && index <= $0.removeEndIndex
        }
    }

    @ViewBuilder
    private func wordView(_ i: Int) -> some View {
        let token = appState.transcript[i]
        let cut = cutContaining(i)
        let inCut = cut != nil
        let isActive = cut?.opId == activeCutId && inCut

        Text(token.word)
            .font(.system(size: 15))
            .foregroundStyle(inCut ? Theme.danger : Theme.ink)
            .strikethrough(inCut, color: Theme.danger)
            .padding(.horizontal, 2)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSmall)
                    .fill(inCut ? Theme.danger.opacity(isActive ? 0.20 : 0.10) : .clear)
            )
            .background(
                GeometryReader { g in
                    Color.clear.preference(
                        key: WordFrameKey.self,
                        value: [i: g.frame(in: .named("tx"))]
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                if let cut { activeCutId = cut.opId }
                transcriptFocused = true
            }
    }

    // MARK: - Handles

    @ViewBuilder
    private var handleOverlay: some View {
        if let cut = activeCut,
            cut.enabled,
            let startFrame = wordFrames[cut.removeStartIndex],
            let endFrame = wordFrames[cut.removeEndIndex]
        {
            // Leading edge of the first removed word.
            handle(boundaryX: startFrame.minX, top: startFrame.minY, height: startFrame.height) {
                value in
                if let idx = nearestWordIndex(to: value.location) {
                    appState.adjustCutStart(cut.opId, to: idx)
                }
            }
            // Trailing edge of the last removed word.
            handle(boundaryX: endFrame.maxX, top: endFrame.minY, height: endFrame.height) { value in
                if let idx = nearestWordIndex(to: value.location) {
                    appState.adjustCutEnd(cut.opId, to: idx)
                }
            }
        }
    }

    /// A draggable boundary handle. Uses `.offset` (not `.position`) so its
    /// drawn shape *and* its hit region move to the boundary — keeping the two
    /// handles from each grabbing the whole transcript.
    private func handle(
        boundaryX: CGFloat,
        top: CGFloat,
        height: CGFloat,
        onDrag: @escaping (DragGesture.Value) -> Void
    ) -> some View {
        let hitWidth: CGFloat = 14
        let barHeight = max(18, height + 6)
        return ZStack {
            RoundedRectangle(cornerRadius: 2)
                .fill(Theme.indigo)
                .frame(width: 3, height: barHeight)
            Circle()
                .fill(Theme.indigo)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white, lineWidth: 1.5))
                .offset(y: -barHeight / 2)
        }
        .frame(width: hitWidth, height: barHeight + 11)
        .contentShape(Rectangle())
        .offset(x: boundaryX - hitWidth / 2, y: top - 5.5)
        .gesture(
            DragGesture(coordinateSpace: .named("tx"))
                .onChanged(onDrag)
        )
    }

    /// Index of the transcript word whose frame center is nearest `point`.
    private func nearestWordIndex(to point: CGPoint) -> Int? {
        var best: Int?
        var bestDist = CGFloat.infinity
        for (index, rect) in wordFrames {
            let dx = rect.midX - point.x
            let dy = rect.midY - point.y
            let dist = dx * dx + dy * dy
            if dist < bestDist {
                bestDist = dist
                best = index
            }
        }
        return best
    }

    // MARK: - Keyboard

    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard let cut = activeCut else { return .ignored }
        let toStart = press.modifiers.contains(.option)
        switch press.key {
        case .leftArrow:
            if toStart {
                appState.adjustCutStart(cut.opId, to: cut.removeStartIndex - 1)
            } else {
                appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex - 1)
            }
            return .handled
        case .rightArrow:
            if toStart {
                appState.adjustCutStart(cut.opId, to: cut.removeStartIndex + 1)
            } else {
                appState.adjustCutEnd(cut.opId, to: cut.removeEndIndex + 1)
            }
            return .handled
        default:
            return .ignored
        }
    }
}

// MARK: - Word frame capture

private struct WordFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

// MARK: - Flow layout

/// A simple line-wrapping layout: places subviews left-to-right, wrapping to a
/// new line when the next subview would overflow the proposed width.
struct WordFlowLayout: Layout {
    var spacing: CGFloat = 4
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.replacingUnspecifiedDimensions().width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + lineHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var x: CGFloat = 0
        var y: CGFloat = 0
        var lineHeight: CGFloat = 0
        for sv in subviews {
            let size = sv.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0
                y += lineHeight + lineSpacing
                lineHeight = 0
            }
            sv.place(
                at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

#Preview {
    TranscriptReviewView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
