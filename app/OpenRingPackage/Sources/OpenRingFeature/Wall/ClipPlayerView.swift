import SwiftUI
import AVKit

/// Plays a recorded clip with AppKit's AVPlayerView (the QuickTime player).
///
/// Don't use SwiftUI's `VideoPlayer` here: in Release builds it aborted the app the
/// moment a clip opened (swift_getGenericMetadata -> getSuperclassMetadata fatal error
/// inside _AVKit_SwiftUI). AVPlayerView is the native control and has no such wrapper.
struct ClipPlayerView: NSViewRepresentable {
    let player: AVPlayer
    /// Inline transport controls (scrubber, play/pause). Off for small tiles.
    var showsControls = true

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = showsControls ? .inline : .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = showsControls
        view.allowsPictureInPicturePlayback = showsControls
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        view.controlsStyle = showsControls ? .inline : .none
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
