import CoreLocation
import Foundation
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Copy/paste friendly ADS-B track dump for debugging detection.
struct TrackDumpPayload: Identifiable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String
    let airportICAO: String
    let airportElevationFt: Int
    let icao24: String?
    let reportedKind: String?
    let reportedTime: Date?
    let points: [TrackPoint]

    var text: String {
        TrackDumpFormatter.text(for: self)
    }
}

extension TrackDumpPayload {
    /// Last `window` seconds of the aircraft trail (default 5 minutes).
    static func forTrackerAircraft(
        _ aircraft: LandingDetector.TrackedAircraft,
        airportICAO: String,
        airportElevationFt: Int,
        now: Date,
        window: TimeInterval = Geo.recentTrailSeconds
    ) -> TrackDumpPayload {
        let cutoff = now.addingTimeInterval(-window)
        let points = aircraft.track.filter { $0.timestamp >= cutoff }
        let state = aircraft.flightState?.rawValue ?? aircraft.displayPatternPhase.rawValue
        let coast = aircraft.isCoasting ? " · coasting" : ""
        let minutes = max(1, Int(window / 60))
        return TrackDumpPayload(
            id: UUID(),
            title: aircraft.snapshot.displayLabel,
            subtitle: "Pattern track · last \(minutes) min\(coast)",
            airportICAO: airportICAO,
            airportElevationFt: airportElevationFt,
            icao24: aircraft.snapshot.icao24,
            reportedKind: "flightState=\(state)",
            reportedTime: aircraft.lastSeen,
            points: points
        )
    }
}

enum Clipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }

    static func pasteboardString() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string
        #else
        nil
        #endif
    }
}

enum TrackDumpFormatter {
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoBasic: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func text(for dump: TrackDumpPayload) -> String {
        let sorted = dump.points.sorted { $0.timestamp < $1.timestamp }
        var lines: [String] = []
        lines.append("# \(AppIdentity.name) ADS-B track dump")
        lines.append("title: \(dump.title)")
        if !dump.subtitle.isEmpty {
            lines.append("subtitle: \(dump.subtitle)")
        }
        lines.append("airport: \(dump.airportICAO) elevFt=\(dump.airportElevationFt)")
        if let icao = dump.icao24, !icao.isEmpty {
            lines.append("icao24: \(icao)")
        }
        if let kind = dump.reportedKind {
            lines.append("appReported: \(kind)")
        }
        if let time = dump.reportedTime {
            lines.append("appReportedTime: \(format(time))")
        }
        lines.append("pointCount: \(sorted.count)")
        if let first = sorted.first, let last = sorted.last {
            lines.append("trackStart: \(format(first.timestamp))")
            lines.append("trackEnd: \(format(last.timestamp))")
            lines.append(String(format: "durationSec: %.1f", last.timestamp.timeIntervalSince(first.timestamp)))
        }
        lines.append("")
        lines.append("# time_iso\tlat\tlon\tagl_ft\ton_ground\tgs_kt\ttrack_deg\tvs_fpm")
        for point in sorted {
            let agl = point.altitudeAGLFt.map { String(format: "%.0f", $0) } ?? "-"
            let gs = point.groundSpeedKt.map { String(format: "%.0f", $0) } ?? "-"
            let trk = point.trackDeg.map { String(format: "%.0f", $0) } ?? "-"
            let vs = point.verticalRateFPM.map { String(format: "%.0f", $0) } ?? "-"
            lines.append(
                [
                    format(point.timestamp),
                    String(format: "%.6f", point.coordinate.latitude),
                    String(format: "%.6f", point.coordinate.longitude),
                    agl,
                    point.onGround ? "true" : "false",
                    gs,
                    trk,
                    vs,
                ].joined(separator: "\t")
            )
        }
        lines.append("")
        lines.append("# json")
        lines.append(json(for: dump, points: sorted))
        return lines.joined(separator: "\n")
    }

    private static func format(_ date: Date) -> String {
        iso.string(from: date).isEmpty ? isoBasic.string(from: date) : iso.string(from: date)
    }

    private static func json(for dump: TrackDumpPayload, points: [TrackPoint]) -> String {
        struct Row: Encodable {
            var time: String
            var lat: Double
            var lon: Double
            var aglFt: Double?
            var onGround: Bool
            var gsKt: Double?
            var trackDeg: Double?
            var vsFpm: Double?
        }
        struct Envelope: Encodable {
            var title: String
            var airport: String
            var elevFt: Int
            var icao24: String?
            var appReported: String?
            var appReportedTime: String?
            var points: [Row]
        }

        let envelope = Envelope(
            title: dump.title,
            airport: dump.airportICAO,
            elevFt: dump.airportElevationFt,
            icao24: dump.icao24,
            appReported: dump.reportedKind,
            appReportedTime: dump.reportedTime.map(format),
            points: points.map { p in
                Row(
                    time: format(p.timestamp),
                    lat: p.coordinate.latitude,
                    lon: p.coordinate.longitude,
                    aglFt: p.altitudeAGLFt,
                    onGround: p.onGround,
                    gsKt: p.groundSpeedKt,
                    trackDeg: p.trackDeg,
                    vsFpm: p.verticalRateFPM
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(envelope),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
