import Foundation

/// One point on the pattern-occupancy chart.
struct PatternOccupancySample: Identifiable, Sendable, Equatable, Codable {
    var id: Date { time }
    var time: Date
    /// Live + estimated (lost-but-still-counted) aircraft in the pattern.
    var count: Int
    /// Currently reporting ADS-B and in the pattern.
    var liveCount: Int
    /// Lost contacts still counted via estimated time-to-landing.
    var estimatedCount: Int
}

/// Interval with no ADS-B polls (sleep, offline, failed fetches).
struct PatternFeedGap: Identifiable, Sendable, Equatable, Codable {
    var id: Date { start }
    var start: Date
    var end: Date
}

/// Landing tick on the pattern graph (confirmed ADS-B/kinematic or deferred from Final/Flare).
struct PatternLandingMarker: Identifiable, Sendable, Equatable, Codable {
    var id = UUID()
    var time: Date
    /// ADS-B on-ground or AGL<0 kinematic; false = deferred (Departure/Upwind or 60s lost).
    var confirmed: Bool
    /// Callsign or tail shown on the chart.
    var label: String
}

/// Takeoff tick on the pattern graph (ADS-B ground→airborne or inferred touch-and-go climb-out).
struct PatternTakeoffMarker: Identifiable, Sendable, Equatable, Codable {
    var id = UUID()
    var time: Date
    /// ADS-B left-ground edge; false = inferred after a recent landing.
    var confirmed: Bool
    /// Callsign or tail shown on the chart.
    var label: String
}

/// One aircraft listed in the pattern panel at a poll instant.
struct PatternAircraftPresenceEntry: Sendable, Equatable, Codable {
    var icao24: String
    /// Callsign or tail.
    var label: String
    var phase: String
    var chip: String?
}

/// Per-poll snapshot of who was in the pattern and their labeled state.
struct PatternPollPresenceRecord: Identifiable, Sendable, Equatable, Codable {
    var id: Date { time }
    var time: Date
    var occupancyCount: Int
    var aircraft: [PatternAircraftPresenceEntry]
}

enum PatternOccupancy {
    /// Max history retained per airport (wall or recording clock).
    static let maxHistory: TimeInterval = 7 * 24 * 60 * 60
    static let maxRetentionDays = 7
    /// Cap samples per series (~7 days at a 10 s poll interval).
    static let maxSamples = 65_000
    /// Full pattern graph: maximum zoom-out on the time axis.
    static let fullChartWindow: TimeInterval = 4 * 60 * 60
    /// Default visible range when the pattern graph opens.
    static let defaultChartWindow: TimeInterval = 20 * 60
    /// Minimum zoom-in on the time axis.
    static let minChartWindow: TimeInterval = 5 * 60
    /// Mini sidebar chart: panel width spans this window.
    static let miniChartWindow: TimeInterval = 10 * 60
    /// Pattern plot vertical grid lines and time labels.
    static let chartQuarterHourInterval: TimeInterval = 15 * 60

    /// Quarter-hour timestamps from the first tick on or after `start` through `end`.
    static func quarterHourTicks(from start: Date, through end: Date) -> [Date] {
        let calendar = Calendar.current
        let interval = chartQuarterHourInterval
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        components.second = 0
        let minute = components.minute ?? 0
        components.minute = (minute / 15) * 15
        guard var tick = calendar.date(from: components) else { return [] }
        if tick < start {
            tick = tick.addingTimeInterval(interval)
        }
        var ticks: [Date] = []
        while tick <= end {
            ticks.append(tick)
            tick = tick.addingTimeInterval(interval)
        }
        return ticks
    }

    /// Elapsed time after the last poll before treating the gap as missing data.
    static func feedGapThreshold(pollInterval: TimeInterval) -> TimeInterval {
        max(30, pollInterval * 2.5)
    }

    static func recentSamples(
        _ samples: [PatternOccupancySample],
        now: Date,
        window: TimeInterval = miniChartWindow
    ) -> [PatternOccupancySample] {
        let cutoff = now.addingTimeInterval(-window)
        return samples.filter { $0.time >= cutoff }
    }

    static func gapsInRange(_ gaps: [PatternFeedGap], from start: Date, to end: Date) -> [PatternFeedGap] {
        gaps.filter { $0.end > start && $0.start < end }
    }

    /// Split samples so chart lines do not connect across feed gaps.
    static func contiguousSampleSegments(
        samples: [PatternOccupancySample],
        gaps: [PatternFeedGap]
    ) -> [[PatternOccupancySample]] {
        guard !samples.isEmpty else { return [] }
        var segments: [[PatternOccupancySample]] = []
        var current: [PatternOccupancySample] = []
        for sample in samples {
            if let last = current.last, intervalOverlapsGap(from: last.time, to: sample.time, gaps: gaps) {
                if !current.isEmpty {
                    segments.append(current)
                }
                current = [sample]
            } else {
                current.append(sample)
            }
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private static func intervalOverlapsGap(from start: Date, to end: Date, gaps: [PatternFeedGap]) -> Bool {
        guard end > start else { return false }
        for gap in gaps where gap.start < end && gap.end > start {
            return true
        }
        return false
    }

    /// Typical remaining time in a piston pattern until landing, by last known leg.
    /// Used when ADS-B drops so lost aircraft still count until the ETA elapses.
    /// Leg coast windows are stretched ~35% for pattern legs.
    private static let legCoastStretch = 1.35

    static func estimatedSecondsToLanding(phase: PatternPhase) -> TimeInterval {
        let base: TimeInterval
        switch phase {
        case .flare: base = 25
        case .final: base = 70
        case .base: base = 110
        case .downwind: base = 180
        case .crosswind: base = 120
        case .departure, .upwind, .maneuvering, .leaving, .ground: return 0
        }
        return base * legCoastStretch
    }

    static func sample(
        aircraft: [LandingDetector.TrackedAircraft],
        at time: Date
    ) -> PatternOccupancySample {
        var live = 0
        var estimated = 0
        for ac in aircraft where ac.countsTowardPatternOccupancy(at: time) {
            if ac.isCoasting {
                estimated += 1
            } else {
                live += 1
            }
        }
        return PatternOccupancySample(
            time: time,
            count: live + estimated,
            liveCount: live,
            estimatedCount: estimated
        )
    }
}

extension LandingDetector.TrackedAircraft {
    /// Airborne pattern legs (≤ 5 NM, ≤ 2,000 ft AGL). Excludes Ground, Leaving,
    /// and Maneuvering. Lost contacts stay counted until the phase-based landing ETA.
    func countsTowardPatternOccupancy(at now: Date) -> Bool {
        if hasPendingLanding { return inPattern || distanceNM <= Geo.patternRadiusNM }
        if snapshot.onGround { return false }
        if flightState?.isGround == true { return false }
        if patternPhase == .ground || patternPhase == .leaving || patternPhase == .maneuvering {
            return false
        }
        if let agl = track.last?.altitudeAGLFt, agl > Geo.patternHighAGLFt {
            return false
        }
        if lastLandingAt != nil, isCoasting { return false }
        guard inPattern else { return false }
        if !isCoasting { return true }
        let eta = PatternOccupancy.estimatedSecondsToLanding(phase: patternPhase)
        guard eta > 0 else { return false }
        return now.timeIntervalSince(lastSeen) <= eta
    }
}
