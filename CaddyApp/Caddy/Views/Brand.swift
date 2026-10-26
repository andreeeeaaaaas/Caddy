import AppKit
import SwiftUI

/// The frog wordmark ("frog, Part of Capgemini Invent"), read from the Word
/// template, so the app and the exports share one logo. A template image, so it
/// takes the foreground style: dark in light mode, white in dark.
struct FrogWordmark: View {
    var width: CGFloat

    private static let image: NSImage? = DocxWriter.templateLogo().flatMap { NSImage(data: $0.data) }.map { image in
        image.isTemplate = true
        return image
    }

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .accessibilityLabel("frog, Part of Capgemini Invent")
        }
    }
}
