import AVFoundation
import Speech

nonisolated struct TranscriptWord: Codable, Equatable, Sendable {
    var time: Double
    var end: Double
    /// Includes any leading space or punctuation, so words join back up as spoken.
    var text: String
}

/// On-device transcription with SpeechTranscriber, timed per word so VO can be
/// split at frame boundaries.
nonisolated enum VoiceoverTranscriber {
    enum Failure: LocalizedError {
        case unavailable
        case unsupportedLocale

        var errorDescription: String? {
            switch self {
            case .unavailable: "Transcription isn't available on this Mac"
            case .unsupportedLocale: "Transcription doesn't support this language"
            }
        }
    }

    @concurrent
    static func transcribe(
        _ url: URL,
        locale: Locale,
        onDownload: @escaping @MainActor @Sendable () -> Void,
        onWords: @escaping @MainActor @Sendable ([TranscriptWord], Double) -> Void
    ) async throws {
        guard SpeechTranscriber.isAvailable else { throw Failure.unavailable }
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if supported == nil {
            supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US"))
        }
        guard let supported else { throw Failure.unsupportedLocale }

        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            await onDownload()
            try await request.downloadAndInstall()
        }

        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        let results = transcriber.results
        let analyzer = SpeechAnalyzer(modules: [transcriber])

        let collector = Task {
            for try await result in results {
                var words: [TranscriptWord] = []
                for (timeRange, range) in result.text.runs[\.audioTimeRange] {
                    let text = String(result.text[range].characters)
                    let start = timeRange?.start.seconds ?? result.range.start.seconds
                    let end = timeRange.map { ($0.start + $0.duration).seconds } ?? start
                    words.append(TranscriptWord(time: start, end: end, text: text))
                }
                let progress = duration > 0 ? min(result.range.end.seconds / duration, 1) : 0
                await onWords(words, progress)
            }
        }

        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        try await collector.value
    }

    struct Sentence: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    /// Groups words into sentences, ending at `.`, `?` or `!`.
    static func sentences(from words: [TranscriptWord]) -> [Sentence] {
        var sentences: [Sentence] = []
        var current: [TranscriptWord] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            sentences.append(Sentence(start: first.time, end: max(last.end, last.time), text: text))
            current = []
        }
        for word in words {
            current.append(word)
            if let mark = word.text.trimmingCharacters(in: .whitespaces).last, ".?!".contains(mark) { flush() }
        }
        flush()
        return sentences
    }
}
