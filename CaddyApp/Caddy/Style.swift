import SwiftUI

/// Shared colours and shapes. System colours only, so light and dark both work.
enum CaddyStyle {
    static let checked = Color.green
    /// Suggestions from analysis: their tint, source mark and Confirm.
    static let suggested = Color.purple
    static let field = Color.primary.opacity(0.05)
    static let panel = Color(nsColor: .windowBackgroundColor)
    static let placeholder = Color.secondary.opacity(0.15)
}
