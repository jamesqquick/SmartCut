import AVFoundation
import Foundation
import Observation

/// @Observable wrapper around AVPlayer for low-res video cut previews.
///
/// Mirrors the `key/loader` pattern from `AudioPlayer` so views can drive
/// playback the same way: call `play(key:loader:)` with a closure that
/// returns the local mp4 URL (from the sidecar). Playing a different key
/// stops the current clip; calling the same key again toggles pause/resume.
@MainActor
@Observable
final class VideoPreviewPlayer {

    /// The cut id (opId) of the clip currently loaded or loading.
    private(set) var currentKey: String?
    private(set) var isPlaying: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?

    /// The underlying player. Views bind an `AVPlayerLayer` or `VideoPlayer`
    /// view to this instance.
    private(set) var player: AVPlayer?

    private var loadTask: Task<Void, Never>?
    private var endObserver: NSObjectProtocol?

    // MARK: - Public API

    func play(
        key: String,
        loader: @escaping () async throws -> URL
    ) {
        // Same key already playing → pause (toggle).
        if currentKey == key, isPlaying {
            player?.pause()
            isPlaying = false
            return
        }

        // Same key paused → resume from current position.
        if currentKey == key, !isLoading {
            player?.play()
            isPlaying = true
            return
        }

        // New key → cancel any in-flight load and swap the player.
        stop()
        currentKey = key
        isLoading = true
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await loader()
                try Task.checkCancellation()
                self.startPlayback(url: url, expectedKey: key)
            } catch is CancellationError {
                await MainActor.run {
                    if self.currentKey == key { self.isLoading = false }
                }
            } catch {
                await MainActor.run {
                    if self.currentKey == key {
                        self.errorMessage = error.localizedDescription
                        self.isLoading = false
                        self.currentKey = nil
                    }
                }
            }
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        tearDownPlayer()
        isPlaying = false
        isLoading = false
    }

    // MARK: - Private

    @MainActor
    private func startPlayback(url: URL, expectedKey: String) {
        guard currentKey == expectedKey else { return }

        let item = AVPlayerItem(url: url)
        let p = AVPlayer(playerItem: item)

        // Observe playback-end so we can reset isPlaying.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentKey == expectedKey else { return }
                self.isPlaying = false
                // Rewind so the user can replay without re-loading.
                self.player?.seek(to: .zero)
            }
        }

        player = p
        p.play()
        isPlaying = true
        isLoading = false
    }

    private func tearDownPlayer() {
        player?.pause()
        if let obs = endObserver {
            NotificationCenter.default.removeObserver(obs)
            endObserver = nil
        }
        player = nil
    }
}
