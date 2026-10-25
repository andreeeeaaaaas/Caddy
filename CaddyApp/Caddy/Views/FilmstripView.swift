import SwiftUI

/// The whole ad as a filmstrip, with a marker per row and a draggable playhead.
struct FilmstripView: View {
    let rows: [ScriptRow]
    @Binding var selection: ScriptRow.ID?
    let playback: Playback
    let thumbnails: Thumbnails
    /// Set while scene detection runs; the strip past this point is dimmed.
    let sceneProgress: Double?

    private let tileCount = 16
    private let markerTop: CGFloat = 4
    private let stripTop: CGFloat = 26
    private let stripHeight: CGFloat = 48

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button(playback.isPlaying ? "Pause" : "Play", systemImage: playback.isPlaying ? "pause.fill" : "play.fill") {
                    playback.togglePlay()
                }
                .labelStyle(.iconOnly)
                .buttonBorderShape(.circle)
                Text("\(Timecode.full(playback.currentTime, fps: playback.frameRate)) / \(Timecode.full(playback.duration, fps: playback.frameRate))")
                    .font(.callout.monospacedDigit())
                Spacer()
            }

            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .topLeading) {
                    tiles
                        .frame(height: stripHeight)
                        .offset(y: stripTop)

                    if let sceneProgress {
                        Rectangle()
                            .fill(.background.opacity(0.6))
                            .frame(width: width * (1 - sceneProgress), height: stripHeight)
                            .offset(x: width * sceneProgress, y: stripTop)
                        Text("Finding scenes…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .offset(x: width * sceneProgress + 8, y: markerTop)
                    }

                    ForEach(rows) { row in
                        marker(for: row)
                            .offset(x: x(row.time, width) - 5, y: markerTop)
                            .onTapGesture { selection = row.id }
                    }

                    playhead
                        .offset(x: x(playback.currentTime, width) - 5)
                        .allowsHitTesting(false)
                }
                .frame(width: width, height: geo.size.height, alignment: .topLeading)
                .contentShape(.rect)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            guard playback.duration > 0 else { return }
                            playback.seek(to: value.location.x / width * playback.duration)
                        }
                )
            }
        }
        .padding(EdgeInsets(top: 10, leading: 16, bottom: 12, trailing: 16))
        .background(.background.secondary)
    }

    private var tiles: some View {
        HStack(spacing: 2) {
            ForEach(0..<tileCount, id: \.self) { i in
                if playback.duration > 0 {
                    ThumbnailView(time: Double(i) * playback.duration / Double(tileCount), thumbnails: thumbnails, cornerRadius: 2)
                } else {
                    Rectangle().fill(CaddyStyle.placeholder)
                }
            }
        }
    }

    private func marker(for row: ScriptRow) -> some View {
        VStack(spacing: 2) {
            Group {
                switch row.status {
                case .checked:
                    Rectangle().fill(CaddyStyle.checked)
                case .pending, .detected:
                    Rectangle().fill(.secondary)
                }
            }
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .padding(1)
            Rectangle()
                .fill(row.status == .checked ? CaddyStyle.checked : .secondary)
                .frame(width: 1, height: stripTop + stripHeight - markerTop - 12)
        }
        .frame(width: 10)
        .opacity(row.id == selection ? 1 : 0.8)
        .scaleEffect(row.id == selection ? 1.2 : 1, anchor: .top)
    }

    private var playhead: some View {
        VStack(spacing: 0) {
            Circle().fill(.red).frame(width: 10, height: 10)
            Rectangle().fill(.red).frame(width: 2, height: stripTop + stripHeight - 6)
        }
        .frame(width: 10)
    }

    private func x(_ time: Double, _ width: CGFloat) -> CGFloat {
        guard playback.duration > 0 else { return 0 }
        return width * min(max(time / playback.duration, 0), 1)
    }
}
