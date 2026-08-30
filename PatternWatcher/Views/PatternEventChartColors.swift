import SwiftUI

/// Landing / takeoff bar colors on the pattern charts.
enum PatternEventChartColors {
    static let landingConfirmed = Color(red: 0.06, green: 0.14, blue: 0.42)
    static let landingInferred = landingConfirmed.opacity(0.5)
    static let takeoffConfirmed = Color(red: 0.1, green: 0.55, blue: 0.22)
    static let takeoffInferred = takeoffConfirmed.opacity(0.5)

    static func landing(confirmed: Bool) -> Color {
        confirmed ? landingConfirmed : landingInferred
    }

    static func takeoff(confirmed: Bool) -> Color {
        confirmed ? takeoffConfirmed : takeoffInferred
    }
}
