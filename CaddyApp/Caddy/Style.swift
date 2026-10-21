import SwiftUI

/// Shared colours and shapes. System colours only, so light and dark both work.
enum CaddyStyle {
    static let checked = Color.green
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let placeholder = Color.secondary.opacity(0.15)
    static let suggestionDash = StrokeStyle(lineWidth: 1, dash: [5, 4])
}

/// A frame grab at `time`, or a grey placeholder until it loads.
struct ThumbnailView: View {
    let time: Double
    let thumbnails: Thumbnails
    var cornerRadius: CGFloat = 4

    var body: some View {
        Rectangle()
            .fill(CaddyStyle.placeholder)
            .overlay {
                if let image = thumbnails.images[time] {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius))
            .task(id: time) { thumbnails.request(time) }
    }
}
