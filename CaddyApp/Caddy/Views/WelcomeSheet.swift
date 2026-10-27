import AppKit
import SwiftUI

/// Every shared timing in the tour, in one place to tune. Each illustration's
/// beats (the waits before each step) sit at the bottom of its `body`.
enum WelcomeMotion {
    /// Turning the page.
    static let page = Animation.smooth(duration: 0.45)
    /// How far the text and the illustration slide as the page turns.
    static let textShift: CGFloat = 36
    static let illustrationShift: CGFloat = 16
    /// Each beat of an illustration: things rising in, ticking, growing.
    static let beat = Animation.spring(duration: 0.5, bounce: 0.2)
    /// How long Two Ways to Work stays on each section before moving on.
    static let sectionHold = 0.9
}

/// The tour's six pages, in order.
enum WelcomePage: Int, CaseIterable, Identifiable {
    case welcome, video, views, suggestions, sensitivity, export

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: "Welcome to Caddy"
        case .video: "Start with a video"
        case .views: "Two ways to work"
        case .suggestions: "Check the suggestions"
        case .sensitivity: "Tune the detection"
        case .export: "Export when it’s ready"
        }
    }

    var text: String {
        switch self {
        case .welcome:
            "Caddy turns a finished ad into a CAD script.\nIt finds the scenes, reads the supers and transcribes the voiceover for you. Everything runs on device, so unreleased ads never leave it."
        case .video:
            "Drop an MP4 or MOV onto the window, or press ⌘N. Keep each client’s scripts in a folder, and drag scripts between folders in the sidebar."
        case .views:
            "Playback shows the section you’re watching beside the video, so you can write as it plays. Grid shows the whole script as a table, laid out like the final document."
        case .suggestions:
            "Purple cards are drafts from the voiceover and on-screen text. Confirm the ones that are right, edit the ones that are close and dismiss the rest. Nothing is final until you confirm it."
        case .sensitivity:
            "Too many sections, or too few? Drag Sensitivity under ✦ in the toolbar. Caddy only redraws sections you haven’t touched, so your edits are safe."
        case .export:
            "Export a Word or PDF file in the team’s CAD Script template. Choose whether to include frames and scene descriptions, then send it as is."
        }
    }

    /// Shortcuts shown under the text: key, then what it does.
    var keys: [(key: String, action: String)] {
        switch self {
        case .views: [("Space", "Play or pause"), ("L", "Loop"), ("↑ ↓", "Sections"), ("⌘F", "Add section")]
        case .suggestions: [("⏎", "Confirm all")]
        default: []
        }
    }
}

/// The welcome tour: an illustration, a title and a few lines per page, then
/// Back, page dots, Skip and Continue. The last page ends on Choose a Video.
/// Click an illustration to play it again.
struct WelcomeSheet: View {
    var onChooseVideo: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: WelcomePage
    @State private var forward = true
    @State private var replays = 0

    init(page: WelcomePage = .welcome, onChooseVideo: @escaping () -> Void = {}) {
        _page = State(initialValue: page)
        self.onChooseVideo = onChooseVideo
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // Illustrations place their parts from the top left, as in Figma.
                Group { illustration.id(replays) }
                    .frame(width: 560, height: 290, alignment: .topLeading)
                    .id(page)
                    .transition(slide(WelcomeMotion.illustrationShift))
            }
            .frame(width: 560, height: 290)
            .background(Color.primary.opacity(0.045))
            .clipped()
            .contentShape(.rect)
            .onTapGesture { replays += 1 }

            ZStack(alignment: .topLeading) {
                content
                    .id(page)
                    .transition(slide(WelcomeMotion.textShift))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()

            footer
        }
        .frame(width: 560, height: 540)
    }

    @ViewBuilder
    private var illustration: some View {
        switch page {
        case .welcome: WelcomeIllustration()
        case .video: VideoIllustration()
        case .views: ViewsIllustration()
        case .suggestions: SuggestionsIllustration()
        case .sensitivity: SensitivityIllustration()
        case .export: ExportIllustration()
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(page.title)
                .font(.title.bold())
            Text(page.text)
                .foregroundStyle(.secondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
            if !page.keys.isEmpty {
                HStack(spacing: 16) {
                    ForEach(page.keys, id: \.key) { Keycap(key: $0.key, action: $0.action) }
                }
                .padding(.top, 8)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A fixed height with the dots pinned to the middle, so nothing in it
    /// moves as the buttons either side change.
    private var footer: some View {
        HStack(spacing: 8) {
            ZStack(alignment: .leading) {
                if let previous = WelcomePage(rawValue: page.rawValue - 1) {
                    Button("Back") { go(to: previous) }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                        .controlSize(.large)
                        .transition(.opacity)
                } else {
                    FrogWordmark(width: 100)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Spacer(minLength: 0)

            Button { dismiss() } label: {
                Text(isLast ? "Close" : "Skip")
                    .contentTransition(.interpolate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut(.cancelAction)

            // One capsule that stretches into Choose a Video on the last
            // page, its label morphing, rather than a button swapped for another.
            Button {
                if let next = WelcomePage(rawValue: page.rawValue + 1) {
                    go(to: next)
                } else {
                    onChooseVideo()
                    dismiss()
                }
            } label: {
                Text(isLast ? "Choose a Video" : "Continue")
                    .contentTransition(.interpolate)
            }
            .buttonStyle(CapsuleButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .frame(height: 32)
        .overlay { PageDots(page: page) { go(to: $0) } }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }

    private var isLast: Bool { page == WelcomePage.allCases.last }

    /// Slides in from the side the reader is heading towards and out the other.
    private func slide(_ distance: CGFloat) -> AnyTransition {
        let shift = reduceMotion ? 0 : (forward ? distance : -distance)
        return .asymmetric(insertion: .offset(x: shift).combined(with: .opacity),
                           removal: .offset(x: -shift).combined(with: .opacity))
    }

    private func go(to next: WelcomePage) {
        guard next != page else { return }
        // The direction lands first, so the outgoing page leaves the right way.
        forward = next.rawValue > page.rawValue
        Task {
            withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : WelcomeMotion.page) { page = next }
        }
    }
}

/// The prominent capsule, drawn in SwiftUI so its width animates with its
/// label (AppKit's `.borderedProminent` jumps to its new size). Also used for
/// the empty states' Choose a Video.
struct CapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.medium))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 16)
            .frame(height: 30)
            .background(Color.accentColor, in: .capsule)
            .overlay(Capsule().fill(.black.opacity(configuration.isPressed ? 0.15 : 0)))
            .contentShape(.capsule)
    }
}

/// One dot per page, the current one dark. Click one to go there.
private struct PageDots: View {
    let page: WelcomePage
    let go: (WelcomePage) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(WelcomePage.allCases) { dot in
                Button { go(dot) } label: {
                    Circle()
                        .fill(Color.primary.opacity(dot == page ? 0.8 : 0.18))
                        .frame(width: 6, height: 6)
                        .padding(3.5)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, -3.5)
    }
}

private struct Keycap: View {
    let key: String
    let action: String

    var body: some View {
        HStack(spacing: 6) {
            Text(key)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary.opacity(0.75))
                .padding(.horizontal, 6)
                .padding(.top, 2)
                .padding(.bottom, 3)
                .background(Color.primary.opacity(0.04), in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5))
            Text(action)
                .font(.callout)
                .foregroundStyle(.primary.opacity(0.55))
        }
    }
}

// MARK: - Illustrations

/// A video becoming a CAD script: the video, the arrow, then the script fills in row by row.
private struct WelcomeIllustration: View {
    @State private var step = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 9) {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.video)
                    .frame(width: 176, height: 99)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(.white.opacity(0.9))
                    }
                Text("HRB_MaxYourTax.mp4")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            .reveal(step >= 1, scale: 0.96)
            .at(64, 92)

            Text("→")
                .font(.system(size: 28))
                .foregroundStyle(.primary.opacity(0.25))
                .reveal(step >= 2, x: -10, y: 0)
                .at(258, 122)

            ScriptSketch(filled: max(0, step - 3))
                .reveal(step >= 3)
                .at(312, 40)

            Text("Runs on this Mac. Nothing is uploaded.")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.7))
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Color.surface, in: .capsule)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                .reveal(step >= 7, scale: 0.9)
                .frame(width: 560)
                .at(0, 258)
        }
        // Video, arrow, script, its three rows, then the badge.
        .beats($step, [0.15, 0.3, 0.25, 0.2, 0.15, 0.15, 0.35])
    }
}

/// The CAD script card: a dark title bar, then SCENE, VO and SUPER rows.
private struct ScriptSketch: View {
    /// How many rows have their text.
    let filled: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("CAD Script")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .frame(maxWidth: .infinity, minHeight: 18, alignment: .leading)
                .background(Color.video)
            VStack(alignment: .leading, spacing: 14) {
                ForEach(Array(["SCENE", "VO", "SUPER"].enumerated()), id: \.offset) { index, label in
                    if index > 0 {
                        Rectangle().fill(Color.primary.opacity(0.1)).frame(width: 160, height: 0.5)
                    }
                    row(label, shown: filled > index)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 12)
        }
        .frame(width: 176, height: 212, alignment: .top)
        .surface(cornerRadius: 6)
    }

    private func row(_ label: String, shown: Bool) -> some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.12))
                .frame(width: 54, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.45))
                    .frame(height: 8)
                    .opacity(shown ? 1 : 0)
                Line(width: 94).grow(shown)
                Line(width: 68).grow(shown)
            }
        }
    }
}

/// The library window: a video file glides over the drop zone, drops in and
/// becomes a new script in the sidebar.
private struct VideoIllustration: View {
    @State private var step = 0

    private var hovering: Bool { step == 2 }
    private var dropped: Bool { step >= 3 }
    private var added: Bool { step >= 4 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            window
                .reveal(step >= 1, y: 6)
                .at(60, 36)

            draggedFile
                .rotationEffect(.degrees(step >= 2 ? 5 : 14))
                .scaleEffect(dropped ? 0.5 : 1)
                .opacity(step >= 2 && !dropped ? 1 : 0)
                .offset(x: dropped ? -80 : step >= 2 ? 0 : 110, y: dropped ? -60 : step >= 2 ? 0 : 70)
                .at(378, 196)
        }
        // Window, file over the drop zone, drop, new script.
        .beats($step, [0.15, 0.3, 0.9, 0.25])
    }

    private var window: some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.primary.opacity(0.04))
                .frame(width: 150, height: 218)
            TrafficLights(size: 7).at(10, 9)
            Text("Folders")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.4))
                .at(14, 34)
            sidebarText("▾  H&R Block", weight: .medium, opacity: 0.85).at(12, 52)
            count(added ? "4" : "3").at(132, 52)
            RoundedRectangle(cornerRadius: 5)
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 138, height: 20)
                .at(6, added ? 130 : 70)
            sidebarText("Max Your Tax", opacity: added ? 0.7 : 0.9).at(30, 73)
            sidebarText("Hero 30s").at(30, 93)
            sidebarText("Tax Time 15s").at(30, 113)
            sidebarText("Hero 16x9", opacity: 0.9)
                .reveal(added, y: -6)
                .at(30, 133)
            sidebarText("▸  Uber Eats", weight: .medium, opacity: 0.85).at(14, added ? 156 : 136)
            count("2").at(132, added ? 156 : 136)

            VStack(spacing: 4) {
                Text("Drop a video here")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("MP4, MOV or M4V  ·  ⌘N")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            .frame(width: 250, height: 170)
            .background(Color.accentColor.opacity(hovering ? 0.1 : 0.04), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor.opacity(hovering ? 0.9 : 0.5), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }
            .scaleEffect(hovering ? 1.015 : 1)
            .at(172, 24)
        }
        .frame(width: 440, height: 218, alignment: .topLeading)
        .surface(cornerRadius: 10)
    }

    private var draggedFile: some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.video)
                .frame(width: 32, height: 20)
            Text("Hero_16x9.mp4")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.primary.opacity(0.85))
        }
        .padding(.leading, 8)
        .frame(width: 132, height: 40, alignment: .leading)
        .surface(cornerRadius: 8)
    }

    private func sidebarText(_ text: String, weight: Font.Weight = .regular, opacity: Double = 0.7) -> some View {
        Text(text)
            .font(.system(size: 11, weight: weight))
            .foregroundStyle(.primary.opacity(opacity))
    }

    private func count(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.primary.opacity(0.4))
            .contentTransition(.numericText())
    }
}

/// Playback and Grid side by side, following the same section as it moves along.
private struct ViewsIllustration: View {
    @State private var step = 0
    @State private var section = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 12) {
                PlaybackSketch(section: section)
                caption("Playback", "Write as you watch")
            }
            .reveal(step >= 1)
            .at(52, 46)

            VStack(spacing: 12) {
                GridSketch(section: section)
                caption("Grid", "See the whole script")
            }
            .reveal(step >= 2)
            .at(288, 46)
        }
        // Playback, then Grid.
        .beats($step, [0.15, 0.12])
        .task {
            guard !reduceMotion else { return }
            while true {
                do { try await Task.sleep(for: .seconds(WelcomeMotion.sectionHold)) } catch { return }
                withAnimation(.smooth(duration: 0.35)) { section = (section + 1) % PlaybackSketch.sections.count }
            }
        }
    }

    private func caption(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.45))
        }
        .frame(width: 220)
    }
}

/// A small playback window: video, the section's cards, and the player bar.
private struct PlaybackSketch: View {
    /// Which section is playing.
    let section: Int

    /// Each section's block width in the player bar.
    static let sections: [CGFloat] = [64, 22, 18, 30, 22]
    /// The section's suggestion: which card is purple.
    private static let suggestion = [1, 0, 2, 1, 0]

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrafficLights(size: 6).at(8, 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.video)
                .frame(width: 130, height: 74)
                .at(10, 24)
            VStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { card in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(card == Self.suggestion[section] ? CaddyStyle.suggested.opacity(0.14) : Color.primary.opacity(0.06))
                        .frame(width: 62, height: 20)
                }
            }
            .at(148, 24)
            Capsule()
                .fill(Color.video)
                .frame(width: 200, height: 16)
                .at(10, 112)
            HStack(spacing: 4) {
                ForEach(Self.sections.indices, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(index == section ? 0.9 : 0.35))
                        .frame(width: Self.sections[index], height: 4)
                }
            }
            .at(30, 118)
        }
        .frame(width: 220, height: 150, alignment: .topLeading)
        .surface(cornerRadius: 8)
    }
}

/// A small grid window: a row per section, the playing one tinted.
private struct GridSketch: View {
    let section: Int

    var body: some View {
        ZStack(alignment: .topLeading) {
            TrafficLights(size: 6).at(8, 8)
            Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 220, height: 0.5).at(0, 22)
            if section < 4 {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.08))
                    .frame(width: 220, height: 29)
                    .at(0, 26 + 29 * CGFloat(section))
            }
            ForEach(0..<4, id: \.self) { row in
                let y = 30 + 29 * CGFloat(row)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.primary.opacity(0.12))
                    .frame(width: 36, height: 21)
                    .at(10, y)
                Line(width: 120, opacity: 0.14).at(54, y + 4)
                Line(width: 84, color: row == 2 ? CaddyStyle.suggested.opacity(0.5) : Color.primary.opacity(0.14))
                    .at(54, y + 12)
                Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 220, height: 0.5).at(0, y + 25)
            }
        }
        .frame(width: 220, height: 150, alignment: .topLeading)
        .surface(cornerRadius: 8)
    }
}

/// A section's cards: a voiceover, then two suggestions. The Super's Confirm is
/// pressed and it turns into an ordinary card.
private struct SuggestionsIllustration: View {
    @State private var step = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("Section 4")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.85))
                Text("0:10 – 0:13")
                    .font(.system(size: 12))
                    .foregroundStyle(.primary.opacity(0.45))
            }
            VStack(spacing: 8) {
                SketchCard(label: "Voiceover", text: "Don’t tax yourself. Get your max refund with H&R Block.")
                    .reveal(step >= 2)
                SketchCard(label: "Super", text: "Don’t tax yourself", suggested: step < 6, pressing: step == 5)
                    .reveal(step >= 3)
                SketchCard(label: "Disclaimer", text: "Max refund guarantee. See hrblock.com/guarantee for details.", suggested: true)
                    .reveal(step >= 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(width: 380, height: 244, alignment: .topLeading)
        .surface(cornerRadius: 12)
        .reveal(step >= 1, y: 6)
        .at(90, 24)
        // Panel, three cards, Confirm pressed, confirmed.
        .beats($step, [0.15, 0.2, 0.12, 0.12, 0.9, 0.2])
    }
}

private struct SketchCard: View {
    let label: String
    let text: String
    var suggested = false
    var pressing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.5))
                Text("✦")
                    .font(.system(size: 10))
                    .foregroundStyle(CaddyStyle.suggested)
                    .opacity(suggested ? 1 : 0)
                Spacer()
                HStack(spacing: 10) {
                    Text("✦ Confirm")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(CaddyStyle.suggested)
                        .padding(.horizontal, 5)
                        .background(CaddyStyle.suggested.opacity(pressing ? 0.18 : 0), in: .rect(cornerRadius: 5))
                        .padding(.horizontal, -5)
                    Text("Dismiss")
                        .font(.system(size: 11))
                        .foregroundStyle(.primary.opacity(0.3))
                }
                .opacity(suggested ? 1 : 0)
            }
            .frame(height: 13)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.primary.opacity(0.85))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.top, 9)
        .padding(.bottom, 10)
        .background(suggested ? CaddyStyle.suggested.opacity(0.1) : Color.primary.opacity(0.05), in: .rect(cornerRadius: 10))
        .scaleEffect(pressing ? 0.985 : 1)
    }
}

/// The Sensitivity slider is dragged up, then back, and the player bar's
/// sections split and merge with it.
private struct SensitivityIllustration: View {
    @State private var step = 0
    @State private var sensitivity = 0.2
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Candidate cuts along the ad, as a share of its length, and how strong
    /// each is. A cut is kept when its score beats 1 − sensitivity.
    private static let cuts: [(at: Double, score: Double)] = [
        (0.17, 0.2), (0.30, 0.1), (0.434, 0.9), (0.567, 0.5), (0.667, 0.7), (0.823, 0.95), (0.90, 0.4),
    ]
    /// Where the playhead is, for the bright section.
    private static let playhead = 0.7
    private static let barWidth: CGFloat = 364.64
    private static let trackWidth: CGFloat = 248

    private var sections: [(start: Double, end: Double)] {
        let kept = Self.cuts.filter { $0.score > 1 - sensitivity }.map(\.at)
        let edges = [0] + kept + [1]
        return zip(edges, edges.dropFirst()).map { ($0, $1) }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            popover
                .reveal(step >= 1, y: 6)
                .at(140, 30)
            playerBar
                .reveal(step >= 2, y: 6)
                .at(60, 206)
        }
        .task { await play() }
    }

    private var popover: some View {
        ZStack(alignment: .topLeading) {
            Text("✦  Sensitivity")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .at(16, 14)
            Line(width: Self.trackWidth, opacity: 0.12).at(16, 56)
            Line(width: Self.trackWidth * sensitivity, color: .accentColor).at(16, 56)
            Circle()
                .fill(Color.surface)
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .frame(width: 18, height: 18)
                .shadow(color: .black.opacity(0.2), radius: 1.5, y: 1)
                .at(16 + Self.trackWidth * sensitivity - 9, 49)
            HStack {
                Text("Fewer sections")
                Spacer()
                Text("More sections")
            }
            .font(.system(size: 10))
            .foregroundStyle(.primary.opacity(0.5))
            .frame(width: Self.trackWidth)
            .at(16, 76)
            Text("Edited sections are kept.")
                .font(.system(size: 10))
                .foregroundStyle(.primary.opacity(0.4))
                .at(16, 100)
        }
        .frame(width: 280, height: 128, alignment: .topLeading)
        .surface(cornerRadius: 12)
    }

    private var playerBar: some View {
        let sections = sections
        let width = Self.barWidth - 4 * CGFloat(sections.count - 1)
        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(Color.video)
                .frame(width: 440, height: 36)
            Circle()
                .fill(.white.opacity(0.15))
                .frame(width: 24, height: 24)
                .overlay {
                    Image(systemName: "play.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.white)
                }
                .at(8, 6)
            HStack(spacing: 4) {
                ForEach(sections, id: \.start) { section in
                    Capsule()
                        .fill(.white.opacity((section.start..<section.end).contains(Self.playhead) ? 0.9 : 0.35))
                        .frame(width: width * (section.end - section.start), height: 8)
                        .transition(.opacity)
                }
            }
            .at(42, 14)
        }
    }

    private func play() async {
        guard !reduceMotion else {
            step = 2
            sensitivity = 0.73
            return
        }
        do {
            for _ in 1...2 {
                try await Task.sleep(for: .seconds(0.15))
                withAnimation(WelcomeMotion.beat) { step += 1 }
            }
            try await Task.sleep(for: .seconds(0.5))
            try await drag(to: 0.92, over: 1.1)
            try await Task.sleep(for: .seconds(0.45))
            try await drag(to: 0.73, over: 0.5)
        } catch {}
    }

    /// Moves the slider in small steps, as a hand would, so sections split as it passes them.
    private func drag(to target: Double, over seconds: Double) async throws {
        let start = sensitivity
        let frames = Int(seconds / 0.03)
        for frame in 1...frames {
            let t = Double(frame) / Double(frames)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            withAnimation(.smooth(duration: 0.2)) { sensitivity = start + (target - start) * eased }
            try await Task.sleep(for: .seconds(0.03))
        }
    }
}

/// The export options are ticked, Export… is pressed and the page comes out row by row.
private struct ExportIllustration: View {
    @State private var step = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            page
                .reveal(step >= 5, x: -40, y: 0)
                .at(340, 24)
            sheet
                .reveal(step >= 1, y: 6)
                .at(56, 30)
        }
        // Sheet, Frames, Scene descriptions, Export… pressed, page, four rows, logo.
        .beats($step, [0.15, 0.35, 0.3, 0.4, 0.2, 0.15, 0.1, 0.1, 0.1, 0.2])
    }

    private var sheet: some View {
        ZStack(alignment: .topLeading) {
            Text("Export")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.85))
                .at(16, 14)
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.primary.opacity(0.06))
                .frame(width: 224, height: 26)
                .at(16, 40)
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.surface)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                .frame(width: 110, height: 22)
                .at(18, 42)
            HStack(spacing: 0) {
                Text("Word")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .frame(width: 110)
                Text("PDF")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary.opacity(0.6))
                    .frame(width: 110)
            }
            .at(18, 46)
            option("Frames", on: step >= 2).at(16, 84)
            option("Scene descriptions", on: step >= 3).at(16, 110)
            option("Unconfirmed suggestions", on: false).at(16, 136)
            Text("Export…")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 84, height: 26)
                .background(Color.accentColor, in: .capsule)
                .scaleEffect(step == 4 ? 0.92 : 1)
                .brightness(step == 4 ? -0.08 : 0)
                .at(156, 186)
        }
        .frame(width: 256, height: 228, alignment: .topLeading)
        .surface(cornerRadius: 12)
    }

    private func option(_ title: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 4)
                .fill(on ? Color.accentColor : Color.surface)
                .overlay {
                    RoundedRectangle(cornerRadius: 4).strokeBorder(Color.primary.opacity(on ? 0 : 0.25), lineWidth: 1)
                }
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .scaleEffect(on ? 1 : 0.4)
                        .opacity(on ? 1 : 0)
                }
                .frame(width: 14, height: 14)
            Text(title)
                .font(.system(size: 11))
                .foregroundStyle(.primary.opacity(0.8))
        }
    }

    private var page: some View {
        ZStack(alignment: .topLeading) {
            Text("CAD Script")
                .font(.system(size: 6, weight: .medium))
                .foregroundStyle(.white)
                .padding(.leading, 8)
                .frame(width: 164, height: 14, alignment: .leading)
                .background(Color.video)
            Text("H&R Block")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.primary.opacity(0.85))
                .at(10, 22)
            Text("Max Your Tax  ·  26 Oct 2026")
                .font(.system(size: 6))
                .foregroundStyle(.primary.opacity(0.5))
                .at(10, 40)
            ForEach(0..<4, id: \.self) { row in
                pageRow
                    .reveal(step >= 6 + row, y: 4)
                    .at(10, 58 + 40 * CGFloat(row))
            }
            Circle()
                .fill(Color(red: 0.2, green: 0.75, blue: 0.45))
                .frame(width: 12, height: 12)
                .reveal(step >= 10, y: 0, scale: 0.4)
                .at(142, 220)
        }
        .frame(width: 164, height: 240, alignment: .topLeading)
        .surface(cornerRadius: 3)
    }

    private var pageRow: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color.primary.opacity(0.14))
                .frame(width: 44, height: 26)
            VStack(alignment: .leading, spacing: 4) {
                Rectangle().frame(width: 86, height: 3)
                Rectangle().frame(width: 64, height: 3)
                Rectangle().frame(width: 74, height: 3)
            }
            .foregroundStyle(.primary.opacity(0.15))
            .at(52, 3)
            Rectangle()
                .fill(Color.primary.opacity(0.1))
                .frame(width: 144, height: 0.5)
                .at(0, 33)
        }
    }
}

// MARK: - Parts

private struct TrafficLights: View {
    let size: CGFloat

    var body: some View {
        HStack(spacing: 5) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.79, blue: 0.25)], id: \.self) { color in
                Circle().fill(color).frame(width: size, height: size)
            }
        }
    }
}

/// A line of placeholder text.
private struct Line: View {
    let width: CGFloat
    var opacity = 0.12
    var color: Color?

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(color ?? Color.primary.opacity(opacity))
            .frame(width: width, height: 4)
    }
}

/// Plays an illustration's beats: `step` counts up as each wait passes, or
/// jumps to the end with Reduce Motion.
private struct Beats: ViewModifier {
    @Binding var step: Int
    let waits: [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.task {
            guard !reduceMotion else {
                step = waits.count
                return
            }
            for (index, wait) in waits.enumerated() {
                do { try await Task.sleep(for: .seconds(wait)) } catch { return }
                withAnimation(WelcomeMotion.beat) { step = index + 1 }
            }
        }
    }
}

private extension View {
    /// Places a view at a point in its illustration, as the Figma frame does.
    /// Comes after `reveal`, so scaling happens around the view itself.
    func at(_ x: CGFloat, _ y: CGFloat) -> some View {
        offset(x: x, y: y)
    }

    /// Fades in from a little offset (and scale) once shown.
    func reveal(_ shown: Bool, x: CGFloat = 0, y: CGFloat = 8, scale: CGFloat = 1) -> some View {
        opacity(shown ? 1 : 0)
            .scaleEffect(shown ? 1 : scale)
            .offset(x: shown ? 0 : x, y: shown ? 0 : y)
    }

    /// Grows from its leading edge once shown.
    func grow(_ shown: Bool) -> some View {
        scaleEffect(x: shown ? 1 : 0.001, anchor: .leading)
            .opacity(shown ? 1 : 0)
    }

    func beats(_ step: Binding<Int>, _ waits: [Double]) -> some View {
        modifier(Beats(step: step, waits: waits))
    }

    /// A window or card in an illustration: a surface with a hairline and a soft shadow.
    func surface(cornerRadius: CGFloat) -> some View {
        background(Color.surface, in: .rect(cornerRadius: cornerRadius))
            .clipShape(.rect(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 6)
    }
}

private extension Color {
    /// Cards and windows in the illustrations: white, or a lifted grey in dark mode.
    static let surface = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(white: 0.24, alpha: 1) : .white
    })
    /// Video frames and the player bar: dark, and darker still in dark mode so they stand out.
    static let video = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0.06, alpha: 1) : NSColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1)
    })
}

#Preview("Welcome") {
    WelcomeSheet()
}

#Preview("Export page") {
    WelcomeSheet(page: .export)
}
