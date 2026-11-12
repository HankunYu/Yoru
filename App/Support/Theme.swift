import SwiftUI

/// Shared visual constants. Yoru is dark-only: a night palette with one warm accent.
enum Theme {
    /// Warm moonlight; used sparingly for progress and selection.
    static let accent = Color(red: 0.96, green: 0.80, blue: 0.56)
    /// App background behind lists.
    static let background = Color(red: 0.05, green: 0.05, blue: 0.09)

    /// Grouped rows and panels sitting on `background`.
    static let card = Color(red: 0.10, green: 0.10, blue: 0.15)

    static let controlShadow = Color.black.opacity(0.45)
}
