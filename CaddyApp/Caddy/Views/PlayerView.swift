import AVKit
import SwiftUI

/// AVKit's `AVPlayerView` with inline controls. SwiftUI's `VideoPlayer` crashes
/// at launch with the Xcode 27.1 SDK, so this wraps the AppKit view instead.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = true
    /// Without controls the video fills the view unless told otherwise.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        if showsControls {
            view.controlsStyle = .inline
            view.showsFullScreenToggleButton = true
        } else {
            view.controlsStyle = .none
            view.videoGravity = gravity
        }
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
