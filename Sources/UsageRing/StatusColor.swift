import AppKit
import SwiftUI

/// Status coding for how close a window is to its limit.
/// Redundant with the numeric % shown next to every bar, so color is never
/// the only signal.
enum StatusColor {
    static func nsColor(for utilization: Double) -> NSColor {
        switch utilization {
        case ..<50: return .systemGreen
        case ..<80: return .systemYellow
        case ..<95: return .systemOrange
        default: return .systemRed
        }
    }

    static func color(for utilization: Double) -> Color {
        Color(nsColor: nsColor(for: utilization))
    }
}
