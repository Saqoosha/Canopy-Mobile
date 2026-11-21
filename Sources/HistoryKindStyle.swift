import SwiftUI

/// The icon and tint for a stored notification's `kind`, shared by History and the
/// conversation card so a stalled job never wears a completion's checkmark.
enum HistoryKindStyle {
    static func symbol(for kind: String, filled: Bool) -> String {
        let base: String
        switch kind {
        case "asking": base = "hand.raised"
        case "sent": base = "arrow.up.circle"
        case "job_stalled": base = "exclamationmark.triangle"
        case "job_done": base = "flag.checkered"
        default: base = "checkmark.circle"
        }
        // flag.checkered has no filled form.
        return filled && base != "flag.checkered" ? base + ".fill" : base
    }

    static func tint(for kind: String) -> Color {
        switch kind {
        case "asking": .orange
        case "job_stalled": SessionActivityStyle.color(for: "error")
        default: .secondary
        }
    }
}
