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
    /// Time of the last seek that finished, so a view can wait for the new
    /// frame before showing the player over a still.
    private(set) var settledTime: Double?
    /// The segment being looped, if any: playback jumps back to its start at its end.
    private(set) var loop: Range<Double>?

    /// Added to frame times before converting to CMTime, which otherwise can
    /// round down to the previous frame (13.12 s showed the 13.08 s frame).
    nonisolated static let frameNudge = 0.001

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var segmentEndObserver: Any?
    @ObservationIgnored private var loopObserver: Any?
    /// Seeks still in flight. Until they land, the player can report the old time,
    /// which would pull the carousel back a frame.
    @ObservationIgnored private var pendingSeeks = 0

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
                    if self.pendingSeeks == 0 { self.currentTime = time.seconds }
                    self.isPlaying = self.player.timeControlStatus == .playing
                }
            }
        }
    }

    func seek(to seconds: Double) {
        let t = min(max(0, seconds), duration)
        currentTime = t
        settledTime = nil
        pendingSeeks += 1
        player.seek(to: CMTime(seconds: t + Self.frameNudge, preferredTimescale: 600_000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor in
                guard let self else { return }
                self.pendingSeeks -= 1
                if finished { self.settledTime = t }
            }
        }
    }

    func pause() {
        clearSegmentEnd()
        player.pause()
    }

    /// Plays or pauses. At the end of the ad, or of the loop, it starts over.
    func togglePlay() {
        clearSegmentEnd()
        if player.rate > 0 {
            player.pause()
        } else {
            let start = loop?.lowerBound ?? 0
            let end = loop?.upperBound ?? duration
            if currentTime >= end - 1 / frameRate { seek(to: start) }
            player.play()
        }
    }

    /// Loops `range` while playing, or stops looping when nil.
    func setLoop(_ range: Range<Double>?) {
        guard range != loop else { return }
        loop = range
        if let loopObserver {
            player.removeTimeObserver(loopObserver)
            self.loopObserver = nil
        }
        guard let range, !range.isEmpty else { return }
        // Half a frame early, so the next segment's first frame never shows.
        let end = max(range.lowerBound, range.upperBound - 0.5 / frameRate)
        let endTime = NSValue(time: CMTime(seconds: end, preferredTimescale: 600_000))
        loopObserver = player.addBoundaryTimeObserver(forTimes: [endTime], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.seek(to: range.lowerBound) }
        }
        if !range.contains(currentTime) { seek(to: range.lowerBound) }
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
