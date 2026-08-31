import SwiftUI

/// Landing / takeoff bar colors on the pattern charts.
enum PatternEventChartColors {
    static let landingConfirmed = Color(red: 0.06, green: 0.14, blue: 0.42)
    static let landingInferred = landingConfirmed.opacity(0.5)
    static let takeoffConfirmed = Color(red: 0.1, green: 0.55, blue: 0.22)
    static let takeoffInferred = takeoffConfirmed.opacity(0.5)
    /// Rounded ends on landing/takeoff event bars in Swift Charts.
    static let eventBarCornerRadius: CGFloat = 4
    static let eventLabelFontSize: CGFloat = 9
    /// Monospace character width at `eventLabelFontSize`.
    static var eventLabelCharWidthPt: CGFloat { eventLabelFontSize * 0.625 }
    /// Nudge vertical callsign labels up/right (~1.25 monospace character widths).
    static var eventLabelNudgePt: CGFloat { eventLabelCharWidthPt * 1.25 }
    static var eventLabelQuarterCharPt: CGFloat { eventLabelCharWidthPt * 0.25 }
    static let eventLabelExtraLeftPt: CGFloat = 1
    static var eventLabelExtraUpPt: CGFloat { eventLabelCharWidthPt * 2 }

    static func landing(confirmed: Bool) -> Color {
        confirmed ? landingConfirmed : landingInferred
    }

    static func takeoff(confirmed: Bool) -> Color {
        confirmed ? takeoffConfirmed : takeoffInferred
    }
}
