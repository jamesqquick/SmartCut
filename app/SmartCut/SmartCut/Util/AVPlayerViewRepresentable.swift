import AVKit
import SwiftUI

/// NSViewRepresentable wrapper around AVPlayerView.
///
/// Replaces AVKit.VideoPlayer (the SwiftUI convenience wrapper) which routes
/// through the private _AVKit_SwiftUI overlay framework and crashes on macOS 26
/// due to a class-metadata incompatibility introduced in that OS version.
/// AVPlayerView is the stable AppKit layer and is unaffected.
struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}
