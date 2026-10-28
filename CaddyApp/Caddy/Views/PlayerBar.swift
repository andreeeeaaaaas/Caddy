import SwiftUI

/// The player's transport, from the Figma toolbar: play, a bar with one
/// block per section, loop and split section.
struct PlayerBar: View {
    let rows: [ScriptRow]
    let playback: Playback
    @Binding var isLooping: Bool
    let onSplit: () -> Void
    let onPlay: (ScriptRow.ID) -> Void
    let onLoop: (ScriptRow.ID) -> Void
    let onDelete: (ScriptRow.ID) -> Void
    /// The section whose block a dragged card is over.
    var dropTarget: ScriptRow.ID? = nil
    /// Reports the track's frame in the playback view, so a dragged card can find the block under it.
    var onTrackFrame: (CGRect) -> Void = { _ in }

    var body: some View {
        HStack(spacing: 16) {
            Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                playback.togglePlay()
            }
            .buttonStyle(BarButtonStyle(width: 99))
            .help(playback.isPlaying ? "Pause (Space)" : "Play (Space)")

            ScrubBar(rows: rows, playback: playback, isLooping: isLooping, onPlay: onPlay, onLoop: onLoop, onDelete: onDelete, dropTarget: dropTarget, onTrackFrame: onTrackFrame)

            HStack(spacing: 8) {
                Button("Loop", systemImage: "repeat") { isLooping.toggle() }
                    .buttonStyle(BarButtonStyle(width: 84, isOn: isLooping))
                    .help(isLooping ? "Stop looping this section (L)" : "Loop this section (L)")
                Button("Split Section", systemImage: "scissors", action: onSplit)
                    .buttonStyle(BarButtonStyle(width: 75))
                    .help("Split the section at the playhead (⌘F)")
                    .disabled(rows.hasFrame(at: playback.currentTime))
            }
        }
        .labelStyle(.iconOnly)
    }
}

/// One block per section, sized by duration. Thin at rest; taller with
/// section numbers on hover or while looping. Click or drag to scrub.
private struct ScrubBar: View {
    let rows: [ScriptRow]
    let playback: Playback
    let isLooping: Bool
    let onPlay: (ScriptRow.ID) -> Void
    let onLoop: (ScriptRow.ID) -> Void
    let onDelete: (ScriptRow.ID) -> Void
    let dropTarget: ScriptRow.ID?
    let onTrackFrame: (CGRect) -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    private static let inset: CGFloat = 16
    private static let gap: CGFloat = 2
    private static let centre: CGFloat = 30

    private var isExpanded: Bool { (isHovering && isEnabled) || isLooping || dropTarget != nil }
    private var trackHeight: CGFloat { isExpanded ? 12 : 8 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width - Self.inset * 2)
            let current = rows.index(at: playback.currentTime)
            ZStack(alignment: .topLeading) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    segment(index, row: row, width: width, current: current)
                }
                // No time to show without the video.
                if isEnabled {
                    TimeBubble(time: playback.currentTime)
                        .position(x: Self.inset + x(playback.currentTime, width), y: Self.centre - trackHeight / 2 - TimeBubble.height / 2)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard playback.duration > 0 else { return }
                        let fraction = min(max((value.location.x - Self.inset) / width, 0), 1)
                        playback.seek(to: fraction * playback.duration)
                    }
            )
        }
        .frame(height: 60)
        .background(.black.opacity(0.85), in: .rect(cornerRadius: 16))
        // Dimmed like the bar's buttons when disabled.
        .opacity(isEnabled ? 1 : 0.4)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(PlaybackView.space)).insetBy(dx: Self.inset, dy: 0)
        } action: { onTrackFrame($0) }
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: 0.2), value: isExpanded)
        .animation(.snappy(duration: 0.2), value: isLooping)
    }

    private func segment(_ index: Int, row: ScriptRow, width: CGFloat, current: Int?) -> some View {
        let range = rows.segment(index, duration: playback.duration)
        let start = x(range.lowerBound, width)
        let blockWidth = max(1, x(range.upperBound, width) - start - (index + 1 < rows.count ? Self.gap : 0))
        let isCurrent = index == current
        // Played blocks fill. While looping the others' fill fades out rather
        // than shrinking, and the looped block turns mint like the Loop button.
        let fill: CGFloat = switch current {
        case index?:
            range.isEmpty ? 1 : CGFloat((playback.currentTime - range.lowerBound) / (range.upperBound - range.lowerBound))
        case let current? where index < current: 1
        default: 0
        }
        let isLooped = isLooping && isCurrent

        return ZStack(alignment: .topLeading) {
            Capsule()
                .fill(isLooped ? Color.mint.opacity(0.35) : Color(white: 0.965).opacity(0.6))
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isLooped ? .mint : .white)
                        .frame(width: blockWidth * min(max(fill, 0), 1))
                        .opacity(isLooping && !isCurrent ? 0 : 1)
                }
                .clipShape(.capsule)
                .overlay {
                    if dropTarget == row.id {
                        Capsule()
                            .stroke(Color.accentColor, lineWidth: 2)
                            .padding(-3)
                    }
                }
                .frame(width: blockWidth, height: trackHeight)
                .offset(y: Self.centre - trackHeight / 2)
            if isExpanded && blockWidth >= 12 {
                Text("\(index + 1)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(isLooped ? .mint : .white)
                    .opacity(isCurrent ? 1 : 0.4)
                    .offset(y: 40)
                    .transition(.opacity)
            }
        }
        .frame(width: blockWidth, height: 60, alignment: .topLeading)
        .contentShape(.rect)
        .contextMenu {
            FrameMenu(number: index + 1, canDelete: index > 0, play: { onPlay(row.id) }, loop: { onLoop(row.id) }, delete: { onDelete(row.id) })
        }
        .offset(x: Self.inset + start)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard playback.duration > 0 else { return 0 }
        return width * CGFloat(min(max(time / playback.duration, 0), 1))
    }
}

/// The playhead's timecode, pointing down at the bar.
private struct TimeBubble: View {
    static let height: CGFloat = 39
    let time: Double

    var body: some View {
        VStack(spacing: 0) {
            Text(Timecode.minutes(time))
                .font(.system(size: 16, design: .monospaced))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .frame(height: 32)
                .background(.mint, in: .rect(cornerRadius: 8))
            Pointer()
                .fill(.mint)
                .frame(width: 14, height: 7)
        }
        .frame(height: Self.height)
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private nonisolated struct Pointer: Shape {
        func path(in rect: CGRect) -> Path {
            Path { p in
                p.move(to: CGPoint(x: rect.minX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
                p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
                p.closeSubpath()
            }
        }
    }
}

/// Right-click menu for a section on the bar.
struct FrameMenu: View {
    let number: Int
    let canDelete: Bool
    let play: () -> Void
    let loop: () -> Void
    let delete: () -> Void

    var body: some View {
        Button("Play Section \(number)", systemImage: "play.fill", action: play)
        Button("Loop Section \(number)", systemImage: "repeat", action: loop)
        Divider()
        Button("Join with Previous", systemImage: "arrow.merge", action: delete)
            .keyboardShortcut(.delete, modifiers: [])
            .disabled(!canDelete)
    }
}

/// The toolbar's dark rounded buttons. `isOn` tints a toggle.
private struct BarButtonStyle: ButtonStyle {
    let width: CGFloat
    var isOn = false

    func makeBody(configuration: Configuration) -> some View {
        BarButton(configuration: configuration, width: width, isOn: isOn)
    }
}

/// A dark bar button that lifts and lightens on hover, and presses in with a
/// firm spring that settles with a slight bounce.
private struct BarButton: View {
    let configuration: ButtonStyleConfiguration
    let width: CGFloat
    let isOn: Bool

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovering = false

    var body: some View {
        let isPressed = configuration.isPressed
        let isHovered = isHovering && isEnabled && !isPressed
        configuration.label
            .font(.system(size: 28))
            .foregroundStyle(isOn ? .mint : .white)
            .scaleEffect(isPressed ? 0.85 : 1)
            .frame(width: width, height: 60)
            .background(.black.opacity(0.85), in: .rect(cornerRadius: 16))
            .overlay {
                RoundedRectangle(cornerRadius: 16)
                    .fill(.white.opacity(isHovered ? 0.1 : 0))
            }
            .scaleEffect(isPressed ? 0.94 : isHovered ? 1.04 : 1)
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect(cornerRadius: 16))
            .onHover { isHovering = $0 }
            .animation(.spring(duration: 0.25, bounce: 0.2), value: isPressed)
            .animation(CaddyStyle.hover, value: isHovered)
    }
}

#Preview {
    PlayerBar(
        rows: Script.sample.rows,
        playback: Playback(),
        isLooping: .constant(false),
        onSplit: {}, onPlay: { _ in }, onLoop: { _ in }, onDelete: { _ in }
    )
    .padding(40)
}
