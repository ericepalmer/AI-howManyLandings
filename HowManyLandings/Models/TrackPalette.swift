import SwiftUI

enum TrackPalette {
    static let enrouteAGLFt: Double = 2_000
    static let enrouteTrailOpacity = 0.5
    static let enrouteTrailWidth: CGFloat = 0.65
    /// Shared light blue for all airplanes above 2,000 ft AGL (symbol and dashed trail).
    static let enroute = Color(red: 0.55, green: 0.78, blue: 1.0)
    /// Aircraft reporting on ground via ADS-B.
    static let ground = Color(white: 0.68)

    static func isEnroute(_ snapshot: AircraftSnapshot, airportElevationFt: Int) -> Bool {
        !snapshot.onGround && (snapshot.altitudeAGLFt(airportElevationFt: airportElevationFt) ?? 0) > enrouteAGLFt
    }

    static func color(for snapshot: AircraftSnapshot, airportElevationFt: Int) -> Color {
        if snapshot.onGround {
            return ground
        }
        if isEnroute(snapshot, airportElevationFt: airportElevationFt) {
            return enroute
        }
        return color(for: snapshot.icao24)
    }
    /// Stable per-aircraft sRGB color from the Mode-S hex so MapKit trails and SwiftUI icons match.
    static func color(for icao24: String) -> Color {
        let hash = icao24.lowercased().unicodeScalars.reduce(UInt64(2_166_136_261)) { partial, scalar in
            (partial &* 16_777_619) ^ UInt64(scalar.value)
        }
        let hue = Double(hash % 360) / 360.0
        let saturation = 0.62 + Double((hash / 360) % 22) / 100.0
        let (r, g, b) = rgb(hue: hue, saturation: saturation, brightness: 0.95)
        return Color(red: r, green: g, blue: b)
    }

    private static func rgb(hue: Double, saturation: Double, brightness: Double) -> (Double, Double, Double) {
        let h = hue * 6
        let c = brightness * saturation
        let x = c * (1 - abs(h.truncatingRemainder(dividingBy: 2) - 1))
        let m = brightness - c
        let rgb: (Double, Double, Double)
        switch Int(h) % 6 {
        case 0: rgb = (c, x, 0)
        case 1: rgb = (x, c, 0)
        case 2: rgb = (0, c, x)
        case 3: rgb = (0, x, c)
        case 4: rgb = (x, 0, c)
        default: rgb = (c, 0, x)
        }
        return (rgb.0 + m, rgb.1 + m, rgb.2 + m)
    }
}
