import CoreLocation
import Foundation

/// One rectangular traffic pattern per runway, sized from the field center.
///
/// - Downwind: 0.75 NM from the runway, parallel
/// - Crosswind end: 2 NM past field center along the runway heading
/// - Base end: 3 NM past field center on the reciprocal heading
enum TrafficPattern {
    static let downwindOffsetNM = 0.75
    static let crosswindFromCenterNM = 2.0
    static let baseFromCenterNM = 3.0
    static let cornerRadiusNM = 0.12

    enum Side: Hashable {
        case left
        case right
    }

    /// Four corners of a closed rectangle, in flight order for the chosen traffic side:
    /// crosswind/runway → crosswind/downwind → base/downwind → base/runway → (close).
    static func corners(
        for runway: Runway,
        side: Side,
        fieldCenter: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        let heading = Double(runway.headingTrue)
        let reciprocal = heading + 180
        let lateral = side == .left ? heading - 90 : heading + 90

        // Stations measured from the field center, then snapped onto this runway's centerline.
        let crossAlong = Geo.coordinate(from: fieldCenter, distanceNM: crosswindFromCenterNM, bearingDeg: heading)
        let baseAlong = Geo.coordinate(from: fieldCenter, distanceNM: baseFromCenterNM, bearingDeg: reciprocal)

        let crossNear = project(crossAlong, onto: runway)
        let baseNear = project(baseAlong, onto: runway)

        let crossFar = Geo.coordinate(from: crossNear, distanceNM: downwindOffsetNM, bearingDeg: lateral)
        let baseFar = Geo.coordinate(from: baseNear, distanceNM: downwindOffsetNM, bearingDeg: lateral)

        return [crossNear, crossFar, baseFar, baseNear, crossNear]
    }

    static func smoothPath(
        for runway: Runway,
        side: Side,
        fieldCenter: CLLocationCoordinate2D
    ) -> [CLLocationCoordinate2D] {
        filletedPath(
            through: corners(for: runway, side: side, fieldCenter: fieldCenter),
            cornerRadiusNM: cornerRadiusNM
        )
    }

    // MARK: - Geometry

    /// Closest point on the infinite runway centerline (extended past both thresholds).
    private static func project(_ point: CLLocationCoordinate2D, onto runway: Runway) -> CLLocationCoordinate2D {
        let midLat = ((runway.le.latitude + runway.he.latitude) / 2) * .pi / 180
        let kx = 111_320.0 * cos(midLat)
        let ky = 110_540.0

        let x1 = runway.le.longitude * kx
        let y1 = runway.le.latitude * ky
        let x2 = runway.he.longitude * kx
        let y2 = runway.he.latitude * ky
        let x = point.longitude * kx
        let y = point.latitude * ky

        let dx = x2 - x1
        let dy = y2 - y1
        let length2 = dx * dx + dy * dy
        guard length2 > 1 else { return runway.center }

        // Allow extension past the thresholds (infinite line, not segment).
        let t = ((x - x1) * dx + (y - y1) * dy) / length2
        return CLLocationCoordinate2D(
            latitude: (y1 + t * dy) / ky,
            longitude: (x1 + t * dx) / kx
        )
    }

    private static func filletedPath(
        through vertices: [CLLocationCoordinate2D],
        cornerRadiusNM: Double,
        straightSteps: Int = 12,
        arcSteps: Int = 10
    ) -> [CLLocationCoordinate2D] {
        guard vertices.count >= 2 else { return vertices }

        var path: [CLLocationCoordinate2D] = []
        var legStart = vertices[0]
        let lastIndex = vertices.count - 1

        for index in 1...lastIndex {
            let vertex = vertices[index]
            let previous = vertices[index - 1]
            let isClosingCorner = index < lastIndex

            if isClosingCorner {
                let next = vertices[index + 1]
                let inLength = Geo.distanceNM(previous, vertex)
                let outLength = Geo.distanceNM(vertex, next)
                let trim = min(cornerRadiusNM, inLength * 0.45, outLength * 0.45)

                let inBearing = Geo.bearing(from: previous, to: vertex)
                let outBearing = Geo.bearing(from: vertex, to: next)
                let entry = Geo.coordinate(from: vertex, distanceNM: trim, bearingDeg: inBearing + 180)
                let exit = Geo.coordinate(from: vertex, distanceNM: trim, bearingDeg: outBearing)

                path.append(contentsOf: interpolateStraight(from: legStart, to: entry, steps: straightSteps))
                path.append(contentsOf: roundedCorner(from: entry, through: vertex, to: exit, steps: arcSteps))
                legStart = exit
            } else {
                path.append(contentsOf: interpolateStraight(from: legStart, to: vertex, steps: straightSteps))
            }
        }

        return dedupe(path)
    }

    private static func interpolateStraight(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        steps: Int
    ) -> [CLLocationCoordinate2D] {
        guard steps > 0 else { return [start, end] }
        if Geo.distanceMeters(start, end) < 1 { return [end] }
        return (0...steps).map { step in
            let t = Double(step) / Double(steps)
            return CLLocationCoordinate2D(
                latitude: start.latitude + (end.latitude - start.latitude) * t,
                longitude: start.longitude + (end.longitude - start.longitude) * t
            )
        }
    }

    private static func roundedCorner(
        from entry: CLLocationCoordinate2D,
        through corner: CLLocationCoordinate2D,
        to exit: CLLocationCoordinate2D,
        steps: Int
    ) -> [CLLocationCoordinate2D] {
        guard steps > 0 else { return [exit] }
        return (1...steps).map { step in
            let t = Double(step) / Double(steps)
            let oneMinus = 1 - t
            return CLLocationCoordinate2D(
                latitude: oneMinus * oneMinus * entry.latitude
                    + 2 * oneMinus * t * corner.latitude
                    + t * t * exit.latitude,
                longitude: oneMinus * oneMinus * entry.longitude
                    + 2 * oneMinus * t * corner.longitude
                    + t * t * exit.longitude
            )
        }
    }

    private static func dedupe(_ points: [CLLocationCoordinate2D]) -> [CLLocationCoordinate2D] {
        var result: [CLLocationCoordinate2D] = []
        result.reserveCapacity(points.count)
        for point in points {
            if let last = result.last,
               abs(last.latitude - point.latitude) < 0.000_001,
               abs(last.longitude - point.longitude) < 0.000_001 {
                continue
            }
            result.append(point)
        }
        return result
    }
}
