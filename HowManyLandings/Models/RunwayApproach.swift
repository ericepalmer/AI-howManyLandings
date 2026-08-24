import CoreLocation
import Foundation

/// One landing / departure direction of a runway.
struct RunwayApproach: Sendable, Hashable {
    var ident: String
    var headingDeg: Double
    var threshold: CLLocationCoordinate2D
    var farEnd: CLLocationCoordinate2D
    var runway: Runway

    var lengthNM: Double { Geo.distanceNM(threshold, farEnd) }

    /// Numeric runway direction only (`12L` / `12R` → `12`). Used for active runway.
    var directionIdent: String { Self.directionIdent(ident) }

    /// Strip parallel suffixes so parallel strips share one active direction.
    static func directionIdent(_ ident: String) -> String {
        let trimmed = ident.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let last = trimmed.last, "LRC".contains(last) else { return trimmed }
        let stem = String(trimmed.dropLast())
        guard !stem.isEmpty, stem.allSatisfy(\.isNumber) else { return trimmed }
        return stem
    }

    func frame(at point: CLLocationCoordinate2D) -> (along: Double, crossRight: Double) {
        Geo.alongAndCrossNM(point: point, origin: threshold, headingDeg: headingDeg)
    }

    func distanceToRunwayNM(from point: CLLocationCoordinate2D) -> Double {
        Geo.distanceNM(from: point, to: runway)
    }

    func distanceToThresholdNM(from point: CLLocationCoordinate2D) -> Double {
        Geo.distanceNM(point, threshold)
    }
}
