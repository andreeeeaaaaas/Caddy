import Accelerate
import AVFoundation

nonisolated struct SceneScore: Codable, Equatable, Sendable {
    var time: Double
    var score: Double
}

/// Scores how suddenly each frame changes, to find cuts and graphics coming on.
///
/// Each frame is scaled to 160 px wide and split into 5×5 px blocks. A block
/// jumps when its change from the previous frame is more than 10 grey levels
/// above its median change over the last 12 frames, so steady camera moves
/// don't count. The score is the share of blocks that jumped: about 0.7 for a
/// hard cut, 0.25 for a full-screen graphic and 0.02 to 0.03 for a single super.
///
/// ffmpeg's scene score (used by the Python app) averages change over the whole
/// frame, so supers score about 0.01 and get lost among camera moves.
nonisolated enum SceneDetector {
    static let width = 160
    static let block = 5
    static let history = 12
    static let jump: Float = 10

    /// 0 is cuts only, 1 is every small change.
    static let defaultSensitivity = 0.73

    /// Maps sensitivity to a score threshold, from 0.3 (cuts only) to 0.005.
    /// The default gives about 0.015.
    static func threshold(forSensitivity sensitivity: Double) -> Double {
        0.3 * pow(0.005 / 0.3, min(max(sensitivity, 0), 1))
    }

    /// The first frame, plus the peak of each burst of scores above `threshold`,
    /// at least `minGap` seconds apart.
    static func suggestions(from scores: [SceneScore], threshold: Double, minGap: Double = 0.4) -> [Double] {
        guard let first = scores.first else { return [] }
        var times = [first.time]
        var peak = 0.0
        for s in scores.dropFirst() where s.score > threshold {
            if let last = times.last, s.time - last < minGap {
                if times.count > 1, s.score > peak {
                    times[times.count - 1] = s.time
                    peak = s.score
                }
            } else {
                times.append(s.time)
                peak = s.score
            }
        }
        return times
    }

    /// Decodes every frame and scores it. `progress` gets the scores so far.
    @concurrent
    static func scores(
        for url: URL,
        progress: @escaping @MainActor @Sendable ([SceneScore], Double) -> Void
    ) async throws -> [SceneScore] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { return [] }
        let duration = try await asset.load(.duration).seconds
        let size = try await track.load(.naturalSize)
        let height = max(block, Int((Double(width) * size.height / size.width / Double(block)).rounded()) * block)
        let cols = width / block
        let blockCount = cols * (height / block)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }

        var luma = [UInt8](repeating: 0, count: width * height)
        var previous: [UInt8]?
        var recent: [[Float]] = []
        var scores: [SceneScore] = []

        while let sample = output.copyNextSampleBuffer() {
            if Task.isCancelled {
                reader.cancelReading()
                throw CancellationError()
            }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { continue }
            let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            scaleLuma(pixels, into: &luma, width: width, height: height)

            guard let last = previous else {
                previous = luma
                scores.append(SceneScore(time: time, score: 0))
                continue
            }

            var change = [Float](repeating: 0, count: blockCount)
            for y in 0..<height {
                let row = (y / block) * cols
                for x in 0..<width {
                    let i = y * width + x
                    change[row + x / block] += abs(Float(luma[i]) - Float(last[i]))
                }
            }
            var jumped = 0
            for b in 0..<blockCount {
                change[b] /= Float(block * block)
                let baseline = recent.isEmpty ? 0 : median(recent.map { $0[b] })
                if change[b] - baseline > jump { jumped += 1 }
            }
            recent.append(change)
            if recent.count > history { recent.removeFirst() }
            previous = luma
            scores.append(SceneScore(time: time, score: Double(jumped) / Double(blockCount)))

            if scores.count % 25 == 0 {
                await progress(scores, duration > 0 ? min(time / duration, 1) : 0)
            }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        await progress(scores, 1)
        return scores
    }

    private static func scaleLuma(_ pixels: CVPixelBuffer, into out: inout [UInt8], width: Int, height: Int) {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        var source = vImage_Buffer(
            data: base,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixels, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixels, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        )
        out.withUnsafeMutableBytes { buffer in
            var destination = vImage_Buffer(data: buffer.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
            _ = vImageScale_Planar8(&source, &destination, nil, vImage_Flags(kvImageNoFlags))
        }
    }

    private static func median(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
