import SwiftUI

/// The frog logomark, a template image that takes the foreground style.
struct FrogMark: View {
    var width: CGFloat

    var body: some View {
        Image("FrogMark")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: width)
            .accessibilityHidden(true)
    }
}

/// The white frog on a black square, as in the corner of the app icon.
struct FrogTile: View {
    var size: CGFloat

    var body: some View {
        FrogMark(width: size * 0.72)
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(.black)
    }
}

/// The frog with "Made at frog" beside it. Callers set the font and colour.
struct MadeAtFrog: View {
    var markWidth: CGFloat = 24

    var body: some View {
        HStack(spacing: 6) {
            FrogMark(width: markWidth)
            Text("Made at frog")
        }
    }
}
