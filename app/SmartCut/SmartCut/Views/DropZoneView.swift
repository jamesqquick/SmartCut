import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme

    @State private var isTargeted = false
    @State private var isLoadingMetadata = false

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
        StatusPanelView()
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 20) {
            Spacer()
            dropZone
                .frame(maxWidth: 520)

            Text("SmartCut will detect silence and AI-flagged retakes, then let you review each cut.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            if let error = appState.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
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

    private var dropZone: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.indigo)
                .frame(width: 56, height: 56)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.wash)
                )
            Text("Drop a video here")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Theme.ink)
            Text("Supported: .mp4, .mov, .mkv, .webm")
                .font(.system(size: 12))
                .foregroundStyle(Theme.muted)
            Text("or").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            Button(action: openFilePicker) {
                Text("Choose file…")
                    .frame(minWidth: 120)
            }
            .buttonStyle(.scPrimary)
            .disabled(isLoadingMetadata)

            if isLoadingMetadata {
                ProgressView().controlSize(.small)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
        .padding(.horizontal, 24)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(isTargeted ? Theme.wash : Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(
                            isTargeted ? Theme.indigo : Theme.borderStrong,
                            style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                        )
                )
        )
        .onDrop(of: [UTType.movie, UTType.video, UTType.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
        }
    }

    // MARK: - File pick / drop handling

    private func openFilePicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await load(url: url) }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        let typeIdentifier = UTType.fileURL.identifier
        guard provider.hasItemConformingToTypeIdentifier(typeIdentifier) else { return false }
        provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, _ in
            let resolved: URL?
            if let url = item as? URL {
                resolved = url
            } else if let data = item as? Data {
                resolved = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                resolved = nil
            }
            guard let url = resolved else { return }
            Task { @MainActor in await load(url: url) }
        }
        return true
    }

    @MainActor
    private func load(url: URL) async {
        isLoadingMetadata = true
        defer { isLoadingMetadata = false }
        await appState.handleDrop(url)
    }
}

#Preview {
    DropZoneView()
        .environment(AppState())
        .frame(width: 960, height: 640)
}
