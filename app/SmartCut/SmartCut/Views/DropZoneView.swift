import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    @Environment(AppState.self) private var appState

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
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 480)

            if let error = appState.errorMessage {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
            Spacer()
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 28)
    }

    private var dropZone: some View {
        VStack(spacing: 14) {
            Text("🎬").font(.system(size: 48))
            Text("Drop a video here")
                .font(.system(size: 22, weight: .semibold))
            Text("Supported: .mp4, .mov, .mkv, .webm")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text("or").font(.system(size: 11)).foregroundStyle(.secondary)
            Button(action: openFilePicker) {
                Text("Choose file…")
                    .frame(minWidth: 140)
            }
            .controlSize(.large)
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
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color(nsColor: .separatorColor),
                    style: StrokeStyle(lineWidth: 2, dash: [6, 5])
                )
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isTargeted ? Color.accentColor.opacity(0.06) : Color.clear)
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
