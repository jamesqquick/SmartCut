import AVFoundation
import Foundation
import Observation

/// Tiny @Observable wrapper around AVAudioPlayer for the retake review
/// audio previews. Each instance tracks one "source key" so views can
/// tell which clip is currently playing.
@MainActor
@Observable
final class AudioPlayer: NSObject, AVAudioPlayerDelegate {

    /// Identifier of the most recently loaded source. Views can compare
    /// this to know which of their buttons should show a Pause icon.
    private(set) var currentKey: String?
    private(set) var isPlaying: Bool = false
    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?

    private var player: AVAudioPlayer?
    private var loadTask: Task<Void, Never>?

    func play(
        key: String,
        loader: @escaping () async throws -> URL
    ) {
        // If this exact source is already playing, treat as toggle → stop.
        if currentKey == key, isPlaying {
            stop()
            return
        }

        // Cancel any in-progress load and stop any currently playing clip.
        stop()
        currentKey = key
        isLoading = true
        errorMessage = nil

        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await loader()
                try Task.checkCancellation()
                try self.playFile(at: url, expectedKey: key)
            } catch is CancellationError {
                // The user pressed Pause or switched clips mid-load.
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
        player?.stop()
        player = nil
        isPlaying = false
        isLoading = false
    }

    // MARK: - Private

    private func playFile(at url: URL, expectedKey: String) throws {
        // Guard against late completions if the user clicked another
        // button while we were extracting.
        guard currentKey == expectedKey else { return }
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        guard p.play() else {
            throw NSError(
                domain: "SmartCut.AudioPlayer", code: -1,
                userInfo: [NSLocalizedDescriptionKey: "AVAudioPlayer refused to start"]
            )
        }
        player = p
        isPlaying = true
        isLoading = false
    }

    // MARK: AVAudioPlayerDelegate

    nonisolated func audioPlayerDidFinishPlaying(
        _ player: AVAudioPlayer, successfully _: Bool
    ) {
        Task { @MainActor in
            self.player = nil
            self.isPlaying = false
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(
        _ player: AVAudioPlayer, error: Error?
    ) {
        Task { @MainActor in
            self.errorMessage = error?.localizedDescription
            self.player = nil
            self.isPlaying = false
        }
    }
}
