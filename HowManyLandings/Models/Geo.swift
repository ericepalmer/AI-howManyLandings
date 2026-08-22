import Foundation
import CoreLocation

enum Geo {
    static let trackingRadiusNM = 10.0
    static let innerRingNM = 5.0
    static let metersPerNauticalMile = 1852.0
    static let metersPerFoot = 0.3048
    static let knotsPerMetersPerSecond = 1.94384
    static let feetPerMeter = 3.28084

    struct BoundingBox: Sendable {
        var lamin: Double
        var lomin: Double
        var lamax: Double
        var lomax: Double
    }

    static func meters(fromNM nm: Double) -> Double { nm * metersPerNauticalMile }

    static func feet(fromMeters meters: Double) -> Double { meters * feetPerMeter }

    static func knots(fromMetersPerSecond mps: Double) -> Double { mps * knotsPerMetersPerSecond }

    static func boundingBox(around center: CLLocationCoordinate2D, radiusNM: Double) -> BoundingBox {
        let latDelta = radiusNM / 60.0
        let cosLat = max(cos(center.latitude * .pi / 180), 0.01)
        let lonDelta = radiusNM / (60.0 * cosLat)
        return BoundingBox(
            lamin: center.latitude - latDelta,
            lomin: center.longitude - lonDelta,
            lamax: center.latitude + latDelta,
            lomax: center.longitude + lonDelta
        )
    }

    static func distanceMeters(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let earth = 6_371_000.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let lat1 = a.latitude * .pi / 180
        let lat2 = b.latitude * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * earth * asin(min(1, sqrt(h)))
    }

    static func distanceNM(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        distanceMeters(a, b) / metersPerNauticalMile
    }

    /// Shortest distance in nautical miles from a point to a runway line segment, with a small end-cap buffer.
    static func distanceNM(from point: CLLocationCoordinate2D, to runway: Runway) -> Double {
        let meters = distanceMeters(from: point, toSegmentStart: runway.le, end: runway.he)
        return meters / metersPerNauticalMile
    }

    static func distanceMeters(
        from point: CLLocationCoordinate2D,
        toSegmentStart start: CLLocationCoordinate2D,
        end: CLLocationCoordinate2D
    ) -> Double {
        let startLoc = CLLocation(latitude: start.latitude, longitude: start.longitude)
        let endLoc = CLLocation(latitude: end.latitude, longitude: end.longitude)
        if startLoc.distance(from: endLoc) < 1 {
            let pointLoc = CLLocation(latitude: point.latitude, longitude: point.longitude)
            return pointLoc.distance(from: startLoc)
        }

        // Local equirectangular projection around the segment midpoint.
        let midLat = ((start.latitude + end.latitude) / 2) * .pi / 180
        let kx = 111_320.0 * cos(midLat)
        let ky = 110_540.0
        let x1 = (start.longitude) * kx
        let y1 = start.latitude * ky
        let x2 = end.longitude * kx
        let y2 = end.latitude * ky
        let x = point.longitude * kx
        let y = point.latitude * ky
        let dx = x2 - x1
        let dy = y2 - y1
        let length2 = dx * dx + dy * dy
        let t = max(0, min(1, ((x - x1) * dx + (y - y1) * dy) / length2))
        let projX = x1 + t * dx
        let projY = y1 + t * dy
        let dist = hypot(x - projX, y - projY)
        return dist
    }

    static func headingDelta(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b).truncatingRemainder(dividingBy: 360)
        return raw > 180 ? 360 - raw : raw
    }

    static func isAligned(track: Double, runwayHeading: Int, tolerance: Double = 30) -> Bool {
        let reciprocal = Double((runwayHeading + 180) % 360)
        return headingDelta(track, Double(runwayHeading)) <= tolerance
            || headingDelta(track, reciprocal) <= tolerance
    }

    static func coordinate(
        from origin: CLLocationCoordinate2D,
        distanceNM: Double,
        bearingDeg: Double
    ) -> CLLocationCoordinate2D {
        let earth = 6_371_000.0
        let angular = meters(fromNM: distanceNM) / earth
        let bearing = bearingDeg * .pi / 180
        let lat1 = origin.latitude * .pi / 180
        let lon1 = origin.longitude * .pi / 180
        let lat2 = asin(sin(lat1) * cos(angular) + cos(lat1) * sin(angular) * cos(bearing))
        let lon2 = lon1 + atan2(sin(bearing) * sin(angular) * cos(lat1), cos(angular) - sin(lat1) * sin(lat2))
        return CLLocationCoordinate2D(latitude: lat2 * 180 / .pi, longitude: lon2 * 180 / .pi)
    }

    static func bearing(from start: CLLocationCoordinate2D, to end: CLLocationCoordinate2D) -> Double {
        let lat1 = start.latitude * .pi / 180
        let lat2 = end.latitude * .pi / 180
        let dLon = (end.longitude - start.longitude) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let degrees = atan2(y, x) * 180 / .pi
        return (degrees + 360).truncatingRemainder(dividingBy: 360)
    }
}
