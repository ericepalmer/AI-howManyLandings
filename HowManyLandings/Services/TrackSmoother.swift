import CoreLocation
import Foundation

enum TrackSmoother {
    /// Split a track where ADS-B gaps would create unrealistic straight jumps.
    static func segments(from points: [TrackPoint]) -> [[TrackPoint]] {
        let ordered = points.sorted { $0.timestamp < $1.timestamp }
        guard !ordered.isEmpty else { return [] }

        var segments: [[TrackPoint]] = []
        var current: [TrackPoint] = []
        var last: TrackPoint?

        for point in ordered {
            if let last,
               point.timestamp.timeIntervalSince(last.timestamp) > 45
                || Geo.distanceNM(point.coordinate, last.coordinate) > 1.5 {
                if current.count >= 2 { segments.append(current) }
                current = [point]
            } else {
                current.append(point)
            }
            last = point
        }
        if current.count >= 2 { segments.append(current) }
        return segments
    }

    /// Smooth path with centripetal Catmull-Rom splines that pass through each ADS-B point.
    static func smoothCoordinates(from points: [TrackPoint], stepsPerLeg: Int = 10) -> [CLLocationCoordinate2D] {
        smoothCoordinates(from: points.map(\.coordinate), stepsPerLeg: stepsPerLeg)
    }

    static func smoothCoordinates(from points: [CLLocationCoordinate2D], stepsPerLeg: Int = 10) -> [CLLocationCoordinate2D] {
        guard points.count >= 2 else { return points }
        if points.count == 2 {
            return interpolate(from: points[0], to: points[1], steps: stepsPerLeg)
        }

        var curve: [CLLocationCoordinate2D] = []
        let padded = [points[0]] + points + [points[points.count - 1]]

        for index in 1..<(padded.count - 2) {
            let p0 = padded[index - 1]
            let p1 = padded[index]
            let p2 = padded[index + 1]
            let p3 = padded[index + 2]
            let steps = index == padded.count - 3 ? stepsPerLeg + 1 : stepsPerLeg
            for step in 0..<steps {
                let t = Double(step) / Double(stepsPerLeg)
                curve.append(centripetalCatmullRom(p0, p1, p2, p3, t: t))
            }
        }
        curve.append(points[points.count - 1])
        return dedupe(curve)
    }

    private static func centripetalCatmullRom(
        _ p0: CLLocationCoordinate2D,
        _ p1: CLLocationCoordinate2D,
        _ p2: CLLocationCoordinate2D,
        _ p3: CLLocationCoordinate2D,
        t: Double
    ) -> CLLocationCoordinate2D {
        let alpha = 0.5
        let t0 = 0.0
        let t1 = t0 + pow(max(0.000_001, distance(p0, p1)), alpha)
        let t2 = t1 + pow(max(0.000_001, distance(p1, p2)), alpha)
        let t3 = t2 + pow(max(0.000_001, distance(p2, p3)), alpha)
        let tt = t1 + (t2 - t1) * t

        let a1 = lerp(p0, p1, t: (tt - t0) / (t1 - t0))
        let a2 = lerp(p1, p2, t: (tt - t1) / (t2 - t1))
        let a3 = lerp(p2, p3, t: (tt - t2) / (t3 - t2))
        let b1 = lerp(a1, a2, t: (tt - t0) / (t2 - t0))
        let b2 = lerp(a2, a3, t: (tt - t1) / (t3 - t1))
        return lerp(b1, b2, t: (tt - t1) / (t2 - t1))
    }

    private static func interpolate(
        from start: CLLocationCoordinate2D,
        to end: CLLocationCoordinate2D,
        steps: Int
    ) -> [CLLocationCoordinate2D] {
        guard steps > 0 else { return [start, end] }
        return (0...steps).map { step in
            lerp(start, end, t: Double(step) / Double(steps))
        }
    }

    private static func lerp(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D, t: Double) -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: a.latitude + (b.latitude - a.latitude) * t,
            longitude: a.longitude + (b.longitude - a.longitude) * t
        )
    }

    private static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        Geo.distanceMeters(a, b)
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
