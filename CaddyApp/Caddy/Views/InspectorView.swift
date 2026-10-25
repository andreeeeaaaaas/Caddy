import AVKit
import SwiftUI

/// The selected section: frame, segment playback and a field per element kind.
struct InspectorView: View {
    @Binding var row: ScriptRow
    let number: Int
    let segmentEnd: Double
    let playback: Playback

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Section \(number)")
                        .font(.headline)
                    Text(Timecode.short(row.time))
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                PlayerView(player: playback.player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(.rect(cornerRadius: 6))

                HStack(spacing: 10) {
                    Button("Play Segment", systemImage: "play.fill") {
                        playback.playSegment(from: row.time, to: segmentEnd)
                    }
                    Spacer()
                    Text("\(Timecode.compact(row.time)) – \(Timecode.compact(segmentEnd))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                ForEach(ScriptElement.Kind.allCases, id: \.self) { kind in
                    field(kind.title, text: Binding { row.text(kind) } set: { row.setText(kind, $0) })
                }
            }
            .padding(16)
        }
        .background(.background.secondary)
    }

    private func field(_ label: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            TextField(label, text: text, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...6)
                .labelsHidden()
        }
    }
}

/// AVKit's `AVPlayerView` with inline controls. SwiftUI's `VideoPlayer` crashes
/// at launch with the Xcode 27.1 SDK, so this wraps the AppKit view instead.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    var showsControls = true
    /// Without controls the video fills the view unless told otherwise.
    var gravity: AVLayerVideoGravity = .resizeAspectFill

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        if showsControls {
            view.controlsStyle = .inline
            view.showsFullScreenToggleButton = true
        } else {
            view.controlsStyle = .none
            view.videoGravity = gravity
        }
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
