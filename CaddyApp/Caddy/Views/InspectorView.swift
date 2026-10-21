import AVKit
import SwiftUI

/// The selected row: frame, segment playback, status and every field.
struct InspectorView: View {
    @Binding var row: ScriptRow
    let number: Int
    let segmentEnd: Double
    let playback: Playback
    let onRemove: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Frame \(number)")
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

                if row.status == .suggested {
                    HStack {
                        Button("Accept") { row.status = .pending }
                            .buttonStyle(.borderedProminent)
                        Button("Remove", role: .destructive, action: onRemove)
                    }
                } else {
                    Picker("Status", selection: $row.status) {
                        Text("Pending").tag(ScriptRow.Status.pending)
                        Text("Checked").tag(ScriptRow.Status.checked)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                field("VO", text: $row.vo)
                field("Super", text: $row.supers)
                field("Jingle", text: $row.jingle)
                field("Graphics", text: $row.graphics)
                field("Notes", text: $row.notes)
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

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }
}
