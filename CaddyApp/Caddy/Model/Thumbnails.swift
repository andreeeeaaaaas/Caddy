import AVFoundation
import Observation

/// Frame grabs keyed by time, generated on demand and kept in memory.
@Observable
final class Thumbnails {
    private(set) var images: [Double: CGImage] = [:]

    @ObservationIgnored private var generator: AVAssetImageGenerator?
    @ObservationIgnored private var pending: Set<Double> = []
    /// Requests made before the video loaded.
    @ObservationIgnored private var waiting: Set<Double> = []

    func load(_ asset: AVAsset) {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 360)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        self.generator = generator
        images = [:]
        pending = []
        let earlier = waiting
        waiting = []
        earlier.forEach(request)
    }

    func request(_ time: Double) {
        guard let generator else {
            waiting.insert(time)
            return
        }
        guard images[time] == nil, !pending.contains(time) else { return }
        pending.insert(time)
        generator.generateCGImageAsynchronously(for: CMTime(seconds: time + Playback.frameNudge, preferredTimescale: 600_000)) { [weak self] image, _, _ in
            Task { @MainActor in
                if let image { self?.images[time] = image }
                self?.pending.remove(time)
            }
        }
    }
}
