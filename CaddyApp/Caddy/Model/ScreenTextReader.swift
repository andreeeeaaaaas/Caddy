import AVFoundation
import Vision

/// Text read from one frame, one entry per block (a super, a logo lock-up, a disclaimer).
nonisolated struct ScreenText: Codable, Equatable, Sendable {
    var time: Double
    var lines: [String]
}

/// Reads on-screen text with Vision to suggest supers.
///
/// Each frame is read twice: at full size, which suits small type like
/// disclaimers, and at quarter size, which suits large display type (at full
/// size Vision dropped "TAX" from "MAX YOUR TAX"). Text taller than 8% of the
/// frame comes from the quarter-size pass, smaller text from the full-size one.
///
/// Text that's part of the scene, like signage, is read too; it stays a draft
/// for the user to remove.
nonisolated enum ScreenTextReader {
    private struct Piece {
        var text: String
        var box: CGRect
    }

    private static let largeText: CGFloat = 0.08

    /// Every half second, plus just after each candidate scene change.
    static func sampleTimes(duration: Double, scores: [SceneScore]) -> [Double] {
        var times = Array(stride(from: 0.25, to: duration, by: 0.5))
        let events = SceneDetector.suggestions(from: scores, threshold: SceneDetector.threshold(forSensitivity: 1))
        for (i, event) in events.enumerated() {
            let next = i + 1 < events.count ? events[i + 1] : duration
            times.append(min(event + 0.3, (event + next) / 2))
        }
        times.sort()
        return times.reduce(into: []) { result, time in
            if let last = result.last, time - last < 0.1 { return }
            result.append(time)
        }
    }

    @concurrent
    static func read(
        _ url: URL,
        at times: [Double],
        progress: @escaping @MainActor @Sendable ([ScreenText], Double) -> Void
    ) async throws -> [ScreenText] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        var results: [ScreenText] = []
        for (i, time) in times.enumerated() {
            try Task.checkCancellation()
            let (image, _) = try await generator.image(at: CMTime(seconds: time + Playback.frameNudge, preferredTimescale: 600_000))
            results.append(ScreenText(time: time, lines: try await lines(in: image)))
            if i % 4 == 3 || i == times.count - 1 {
                await progress(results, Double(i + 1) / Double(times.count))
            }
        }
        return results
    }

    private static func lines(in image: CGImage) async throws -> [String] {
        let full = try await pieces(in: image)
        let small = try await pieces(in: scaled(image, by: 0.25) ?? image)
        // Each pass's preferred reads first, then anything only the other pass
        // found. Never two reads of the same spot.
        let preferred = full.filter { $0.box.height <= largeText } + small.filter { $0.box.height > largeText }
        let rest = full.filter { $0.box.height > largeText } + small.filter { $0.box.height <= largeText }
        var chosen: [Piece] = []
        for piece in preferred + rest where !chosen.contains(where: { sameSpot($0.box, piece.box) }) {
            chosen.append(piece)
        }
        return blocks(from: chosen)
    }

    /// More than half of the smaller box overlaps the other. Neighbouring lines
    /// touch or overlap slightly, so any overlap isn't enough.
    private static func sameSpot(_ a: CGRect, _ b: CGRect) -> Bool {
        let overlap = a.intersection(b)
        guard !overlap.isNull else { return false }
        return overlap.width * overlap.height > 0.5 * min(a.width * a.height, b.width * b.height)
    }

    private static func pieces(in image: CGImage) async throws -> [Piece] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        return try await request.perform(on: image).compactMap { observation in
            guard let text = observation.topCandidates(1).first, text.confidence >= 0.3 else { return nil }
            return Piece(text: text.string, box: observation.boundingBox.cgRect)
        }
    }

    /// Joins pieces stacked close together (like "MAX", "YOUR", "TAX") into
    /// one block, read top to bottom. Boxes have a lower-left origin. Pieces
    /// more than 5× apart in height stay separate: "YOUR" is 4× smaller than
    /// "MAX", but the wall sign above "Don't tax yourself" is 6× smaller.
    private static func blocks(from pieces: [Piece]) -> [String] {
        var blocks: [[Piece]] = []
        for piece in pieces.sorted(by: { $0.box.maxY > $1.box.maxY }) {
            let index = blocks.firstIndex { block in
                block.contains { other in
                    let height = min(other.box.height, piece.box.height)
                    guard max(other.box.height, piece.box.height) < 5 * height else { return false }
                    let verticalGap = max(other.box.minY - piece.box.maxY, piece.box.minY - other.box.maxY)
                    let horizontalGap = max(other.box.minX - piece.box.maxX, piece.box.minX - other.box.maxX)
                    let stacked = verticalGap < 0.6 * height && horizontalGap < 0
                    let sideBySide = verticalGap < -0.5 * height && horizontalGap < 2 * height
                    return stacked || sideBySide
                }
            }
            if let index { blocks[index].append(piece) } else { blocks.append([piece]) }
        }
        return blocks.map { block in
            block.sorted { a, b in
                abs(a.box.midY - b.box.midY) < 0.5 * min(a.box.height, b.box.height) ? a.box.minX < b.box.minX : a.box.maxY > b.box.maxY
            }
            .map(\.text)
            .joined(separator: " ")
        }
    }

    private static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = max(1, Int(Double(image.width) * factor))
        let height = max(1, Int(Double(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    /// The text seen in each row's stretch of the ad, in order of appearance.
    ///
    /// Reads are compared on letters and digits only, so "Don't tax yourself"
    /// and "Don'ttax yourself" count as one; the most common spelling wins.
    /// Reads that contain two other reads are wrong merges of separate text
    /// (the wall sign and the super below it) and are dropped. Then partial
    /// reads are dropped, e.g. "MAX YOUR" when "MAX YOUR TAX" was read.
    static func supers(for rowTimes: [Double], from samples: [ScreenText]) -> [String] {
        guard !rowTimes.isEmpty else { return [] }
        var spellings = Array(repeating: [String: [String: Int]](), count: rowTimes.count)
        var order = Array(repeating: [String](), count: rowTimes.count)
        for sample in samples {
            let row = rowTimes.lastIndex { $0 <= sample.time + 0.001 } ?? 0
            for line in sample.lines {
                let key = normalized(line)
                guard !key.isEmpty else { continue }
                if spellings[row][key] == nil { order[row].append(key) }
                spellings[row][key, default: [:]][line, default: 0] += 1
            }
        }
        return rowTimes.indices.map { row in
            let keys = order[row].filter { key in
                order[row].filter { $0 != key && key.contains($0) }.count < 2
            }
            return keys
                .filter { key in !keys.contains { $0 != key && $0.contains(key) } }
                .compactMap { key in
                    spellings[row][key]?.max { a, b in a.value == b.value ? a.key.count < b.key.count : a.value < b.value }?.key
                }
                .joined(separator: "\n")
        }
    }

    /// Fine print that reads like a disclaimer rather than a super: offer
    /// terms, T&Cs, finance, footnotes, legal lines, or anything long.
    static func isDisclaimer(_ text: String) -> Bool {
        let text = text.lowercased()
        if text.split(whereSeparator: \.isWhitespace).count >= 14 { return true }
        return disclaimerPatterns.contains { text.firstMatch(of: $0) != nil }
    }

    nonisolated(unsafe) private static let disclaimerPatterns: [Regex<Substring>] = [
        // Offers
        /offer (?:ends|valid|available|applies|expires|subject)/, /valid (?:until|from|for|on|at|in|while)\b/,
        /while stocks last/, /limited time/, /participating/, /selected (?:stores|products|lines|items)/,
        /exclu(?:des|ding|sions)/, /min(?:imum|\.)? (?:spend|order|purchase)/, /\brrp\b/,
        // Terms
        /\bt'?s? ?& ?c'?s?\b/, /\bterms (?:apply|and|&|of|at)/, /conditions apply/, /restrictions apply/, /fees apply/,
        /subject to/, /eligib/, /for (?:full )?details/, /see .*(?:website|store|in-store)/,
        // Finance
        /\bapr\b/, /representative/, /credit (?:is )?subject/, /not available (?:in|to|with)/,
        // Footnotes and legal
        /^[*†‡]/, /©/, /copyright/, /all rights reserved/, /registered trademark/, /is a trademark/,
        // Claims and safety
        /results (?:may )?vary/, /individual results/, /not typical/, /simulated/, /dramati[sz]ation/,
        /professional driver/, /closed course/, /do not attempt/, /18\+/, /responsibly/,
    ]

    private static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains).map(Character.init))
    }
}
