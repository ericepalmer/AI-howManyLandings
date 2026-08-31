import Foundation

/// Exported pattern log (up to 7 days retained in memory).
struct PatternLogExport: Codable, Sendable {
    var airportICAO: String
    var exportedAt: Date
    var retentionDays: Int
    var description: String
    var occupancySamples: [PatternOccupancySample]
    var feedGaps: [PatternFeedGap]
    var landings: [PatternLandingMarker]
    var takeoffs: [PatternTakeoffMarker]
    var presencePolls: [PatternPollPresenceRecord]
    var hourlyStats: [PatternHourlyBucket]
}

enum PatternLogExporter {
    static func defaultFileName(airportICAO: String) -> String {
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "\(airportICAO)-pattern-log-\(stamp).json"
    }

    static func write(_ export: PatternLogExport, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(export)
        try data.write(to: url, options: .atomic)
    }

    static func makeExport(
        airportICAO: String,
        occupancySamples: [PatternOccupancySample],
        feedGaps: [PatternFeedGap],
        landings: [PatternLandingMarker],
        takeoffs: [PatternTakeoffMarker],
        presencePolls: [PatternPollPresenceRecord],
        hourlyStats: [PatternHourlyBucket]
    ) -> PatternLogExport {
        PatternLogExport(
            airportICAO: airportICAO,
            exportedAt: Date(),
            retentionDays: PatternOccupancy.maxRetentionDays,
            description: "Pattern occupancy, landings, departures, aircraft state, and hourly statistics. Retained up to \(PatternOccupancy.maxRetentionDays) days.",
            occupancySamples: occupancySamples,
            feedGaps: feedGaps,
            landings: landings,
            takeoffs: takeoffs,
            presencePolls: presencePolls,
            hourlyStats: hourlyStats
        )
    }
}
