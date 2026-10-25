import SwiftUI

/// Shared colours and shapes. System colours only, so light and dark both work.
enum CaddyStyle {
    static let checked = Color.green
    /// Suggestions from analysis: their tint, source mark and Confirm.
    static let suggested = Color.purple
    static let field = Color.primary.opacity(0.05)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let placeholder = Color.secondary.opacity(0.15)
    /// Every button's hover: Apple's smooth spring, quick enough to keep up with the pointer.
    static let hover = Animation.smooth(duration: 0.2)
}
