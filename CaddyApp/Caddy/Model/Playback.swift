import AVFoundation
import Observation

/// The document window's player, shared by the inspector and the filmstrip.
@Observable
final class Playback {
    let player = AVPlayer()
    private(set) var asset: AVURLAsset?
    private(set) var duration: Double = 0
    private(set) var frameRate: Double = 25
    private(set) var currentTime: Double = 0
    private(set) var isPlaying = false

    /// Added to frame times before converting to CMTime, which otherwise can
    /// round down to the previous frame (13.12 s showed the 13.08 s frame).
    static let frameNudge = 0.001

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var segmentEndObserver: Any?

    func load(_ url: URL) async {
        let asset = AVURLAsset(url: url)
        self.asset = asset
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        duration = (try? await asset.load(.duration).seconds) ?? 0
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let fps = try? await track.load(.nominalFrameRate), fps > 0 {
            frameRate = Double(fps)
        }
        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.currentTime = time.seconds
                    self.isPlaying = self.player.timeControlStatus == .playing
                }
            }
        }
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        player.seek(to: CMTime(seconds: t + Self.frameNudge, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func togglePlay() {
        clearSegmentEnd()
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// Plays one row's segment and stops at the next row.
    func playSegment(from start: Double, to end: Double) {
        clearSegmentEnd()
        seek(to: start)
        let endTime = NSValue(time: CMTime(seconds: end, preferredTimescale: 600))
        segmentEndObserver = player.addBoundaryTimeObserver(forTimes: [endTime], queue: .main) { [weak self] in
            MainActor.assumeIsolated {
                self?.player.pause()
                self?.clearSegmentEnd()
            }
        }
        player.play()
    }

    private func clearSegmentEnd() {
        if let segmentEndObserver {
            player.removeTimeObserver(segmentEndObserver)
            self.segmentEndObserver = nil
        }
    }
}
