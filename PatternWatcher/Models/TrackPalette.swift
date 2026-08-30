import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

enum TrackPalette {
    static let enrouteAGLFt: Double = 2_000
    static let enrouteTrailOpacity = 0.5
    static let enrouteTrailWidth: CGFloat = 0.65
    /// Unselected post-landing trails stay faintly visible for a few minutes.
    static let postLandingUnselectedOpacity = 0.28
    static let postLandingUnselectedWidth: CGFloat = 1.5
    /// Shared light blue for airplanes above pattern altitude.
    static let enroute = Color(red: 0.55, green: 0.78, blue: 1.0)
    /// Aircraft reporting on ground via ADS-B (non-tracker contexts).
    static let ground = Color(white: 0.68)

    /// 32 distinct tracker / trail swatches (stable index from Mode-S).
    static let swatches: [Color] = [
        Color(red: 0.95, green: 0.32, blue: 0.32),
        Color(red: 0.98, green: 0.55, blue: 0.18),
        Color(red: 0.98, green: 0.78, blue: 0.16),
        Color(red: 0.72, green: 0.88, blue: 0.20),
        Color(red: 0.35, green: 0.82, blue: 0.38),
        Color(red: 0.18, green: 0.78, blue: 0.58),
        Color(red: 0.16, green: 0.80, blue: 0.82),
        Color(red: 0.25, green: 0.62, blue: 0.98),
        Color(red: 0.38, green: 0.45, blue: 0.98),
        Color(red: 0.58, green: 0.38, blue: 0.98),
        Color(red: 0.78, green: 0.35, blue: 0.95),
        Color(red: 0.95, green: 0.35, blue: 0.78),
        Color(red: 0.92, green: 0.28, blue: 0.52),
        Color(red: 0.85, green: 0.45, blue: 0.35),
        Color(red: 0.70, green: 0.55, blue: 0.28),
        Color(red: 0.55, green: 0.70, blue: 0.28),
        Color(red: 0.28, green: 0.70, blue: 0.45),
        Color(red: 0.22, green: 0.68, blue: 0.70),
        Color(red: 0.30, green: 0.52, blue: 0.82),
        Color(red: 0.48, green: 0.40, blue: 0.85),
        Color(red: 0.70, green: 0.35, blue: 0.75),
        Color(red: 0.88, green: 0.40, blue: 0.60),
        Color(red: 0.98, green: 0.45, blue: 0.45),
        Color(red: 0.98, green: 0.68, blue: 0.35),
        Color(red: 0.88, green: 0.88, blue: 0.30),
        Color(red: 0.55, green: 0.90, blue: 0.55),
        Color(red: 0.35, green: 0.90, blue: 0.85),
        Color(red: 0.45, green: 0.75, blue: 0.98),
        Color(red: 0.65, green: 0.60, blue: 0.98),
        Color(red: 0.90, green: 0.55, blue: 0.95),
        Color(red: 0.95, green: 0.60, blue: 0.75),
        Color(red: 0.80, green: 0.55, blue: 0.45),
    ]

    static func swatchIndex(for icao24: String) -> Int {
        let hash = icao24.lowercased().unicodeScalars.reduce(UInt64(2_166_136_261)) { partial, scalar in
            (partial &* 16_777_619) ^ UInt64(scalar.value)
        }
        return Int(hash % UInt64(swatches.count))
    }

    /// Tracker card + map trail color for a Mode-S identity.
    static func swatch(for icao24: String) -> Color {
        swatches[swatchIndex(for: icao24)]
    }

    /// Mix toward white so a selected aircraft/track reads on a dark map.
    static func emphasized(_ color: Color, lift: Double = 0.48) -> Color {
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 1
        #if os(macOS)
        NSColor(color).usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        #endif
        let amount = min(1, max(0, lift))
        return Color(
            red: Double(r + (1 - r) * amount),
            green: Double(g + (1 - g) * amount),
            blue: Double(b + (1 - b) * amount),
            opacity: Double(a == 0 ? 1 : a)
        )
    }

    static func trailColor(forICAO24 icao24: String) -> Color {
        swatch(for: icao24)
    }

    static func isEnroute(_ snapshot: AircraftSnapshot, airportElevationFt: Int) -> Bool {
        !snapshot.onGround && (snapshot.altitudeAGLFt(airportElevationFt: airportElevationFt) ?? 0) > enrouteAGLFt
    }

    static func color(for snapshot: AircraftSnapshot, airportElevationFt: Int) -> Color {
        let agl = snapshot.altitudeAGLFt(airportElevationFt: airportElevationFt)
        if Geo.isSurfaceOps(
            onGround: snapshot.onGround,
            altitudeAGLFt: agl,
            groundSpeedKt: snapshot.groundSpeedKt
        ) {
            return ground
        }
        if isEnroute(snapshot, airportElevationFt: airportElevationFt) {
            return enroute
        }
        return swatch(for: snapshot.icao24)
    }

    /// Stable per-aircraft color (same as tracker swatch).
    static func color(for icao24: String) -> Color {
        swatch(for: icao24)
    }

    /// Prefer aircraft swatch when an event is tied to a Mode-S id.
    static func color(forEventID id: UUID, icao24: String? = nil) -> Color {
        if let icao24, !icao24.isEmpty {
            return swatch(for: icao24)
        }
        var hash: UInt64 = 2_166_136_261
        withUnsafeBytes(of: id.uuid) { buffer in
            for byte in buffer {
                hash = (hash &* 16_777_619) ^ UInt64(byte)
            }
        }
        return swatches[Int(hash % UInt64(swatches.count))]
    }
}
