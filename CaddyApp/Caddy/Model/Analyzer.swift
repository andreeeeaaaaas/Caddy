import AVFoundation
import Observation
import SwiftUI

/// Runs scene detection and transcription for one document, writing suggested
/// rows and their VO into the script as results arrive.
@Observable
final class Analyzer {
    enum Phase: Equatable {
        case idle
        case findingScenes(progress: Double)
        case readingText(progress: Double)
        case downloadingSpeechModel
        case transcribing(progress: Double)
        case finished
    }

    private(set) var phase: Phase = .idle
    /// Shown in the toolbar after analysis, e.g. when transcription failed.
    private(set) var notice: String?

    var isBusy: Bool {
        switch phase {
        case .idle, .finished: false
        default: true
        }
    }

    var isTranscribing: Bool {
        switch phase {
        case .downloadingSpeechModel, .transcribing: true
        default: false
        }
    }

    func run(videoURL: URL, script: Binding<Script>) async {
        notice = nil
        guard await detectScenes(videoURL: videoURL, script: script) else { return }
        await readText(videoURL, script: script)
        if Task.isCancelled { return }

        let hasAudio = !((try? await AVURLAsset(url: videoURL).loadTracks(withMediaType: .audio)) ?? []).isEmpty
        if hasAudio {
            await transcribe(videoURL, script: script)
            if Task.isCancelled { return }
        }

        script.wrappedValue.analysed = true
        phase = .finished
    }

    /// Returns false if cancelled.
    @discardableResult
    func detectScenes(videoURL: URL, script: Binding<Script>) async -> Bool {
        phase = .findingScenes(progress: 0)
        do {
            let scores = try await SceneDetector.scores(for: videoURL) { [weak self] partial, progress in
                self?.phase = .findingScenes(progress: progress)
                self?.suggest(from: partial, script: script)
            }
            script.wrappedValue.sceneScores = scores
            suggest(from: scores, script: script)
            phase = .finished
            return true
        } catch is CancellationError {
            return false
        } catch {
            notice = "Scene detection failed"
            phase = .finished
            return true
        }
    }

    /// Re-applies the document's sensitivity to its saved scores.
    func applySensitivity(script: Binding<Script>) {
        guard let scores = script.wrappedValue.sceneScores else { return }
        suggest(from: scores, script: script)
    }

    private func readText(_ url: URL, script: Binding<Script>) async {
        guard let scores = script.wrappedValue.sceneScores, let last = scores.last else { return }
        phase = .readingText(progress: 0)
        let times = ScreenTextReader.sampleTimes(duration: last.time, scores: scores)
        do {
            let samples = try await ScreenTextReader.read(url, at: times) { [weak self] partial, progress in
                self?.phase = .readingText(progress: progress)
                script.wrappedValue.screenText = partial
                self?.realign(script: script)
            }
            script.wrappedValue.screenText = samples
            realign(script: script)
        } catch is CancellationError {
            return
        } catch {
            notice = "Couldn't read on-screen text"
        }
    }

    private func transcribe(_ url: URL, script: Binding<Script>) async {
        phase = .transcribing(progress: 0)
        script.wrappedValue.transcript = []
        do {
            try await VoiceoverTranscriber.transcribe(url, locale: .current) { [weak self] in
                self?.phase = .downloadingSpeechModel
            } onWords: { [weak self] words, progress in
                self?.phase = .transcribing(progress: progress)
                script.wrappedValue.transcript?.append(contentsOf: words)
                self?.realign(script: script)
            }
        } catch is CancellationError {
            return
        } catch {
            notice = error.localizedDescription
        }
    }

    /// Replaces the suggested rows with the frames detected at the current
    /// sensitivity. Rows the user has accepted or added are kept.
    private func suggest(from scores: [SceneScore], script: Binding<Script>) {
        let threshold = SceneDetector.threshold(forSensitivity: script.wrappedValue.sensitivity)
        let times = SceneDetector.suggestions(from: scores, threshold: threshold)
        let current = script.wrappedValue.rows
        let kept = current.filter { $0.status != .suggested }
        let suggested = current.filter { $0.status == .suggested }

        var rows = kept
        for time in times where !kept.contains(where: { abs($0.time - time) < 0.3 }) {
            rows.append(suggested.first { abs($0.time - time) < 0.001 } ?? ScriptRow(time: time, status: .suggested))
        }
        rows.sort { $0.time < $1.time }
        rows = aligned(rows, script: script.wrappedValue)
        if rows != current { script.wrappedValue.rows = rows }
    }

    private func realign(script: Binding<Script>) {
        let rows = aligned(script.wrappedValue.rows, script: script.wrappedValue)
        if rows != script.wrappedValue.rows { script.wrappedValue.rows = rows }
    }

    /// Fills suggested rows' VO and supers. Accepted rows keep theirs, since
    /// the user may have edited them.
    private func aligned(_ rows: [ScriptRow], script: Script) -> [ScriptRow] {
        var rows = alignedVoiceover(rows, words: script.transcript)
        if let samples = script.screenText, !samples.isEmpty {
            let supers = ScreenTextReader.supers(for: rows.map(\.time), from: samples)
            for i in rows.indices where rows[i].status == .suggested {
                rows[i].supers = supers[i]
            }
        }
        return rows
    }

    /// Gives each sentence to the row whose frame it overlaps most, so VO is
    /// never split mid-sentence. Accepted rows keep their VO, since the user
    /// may have edited it; sentences that land on them aren't repeated.
    private func alignedVoiceover(_ rows: [ScriptRow], words: [TranscriptWord]?) -> [ScriptRow] {
        guard let words, !words.isEmpty, !rows.isEmpty else { return rows }
        var lines = Array(repeating: [String](), count: rows.count)
        for sentence in VoiceoverTranscriber.sentences(from: words) {
            var best = 0
            var bestOverlap = -Double.infinity
            for i in rows.indices {
                let start = i == 0 ? -Double.infinity : rows[i].time
                let end = i + 1 < rows.count ? rows[i + 1].time : .infinity
                let overlap = min(sentence.end, end) - max(sentence.start, start)
                if overlap > bestOverlap {
                    best = i
                    bestOverlap = overlap
                }
            }
            lines[best].append(sentence.text)
        }
        var rows = rows
        for i in rows.indices where rows[i].status == .suggested {
            rows[i].vo = lines[i].joined(separator: " ")
        }
        return rows
    }
}
