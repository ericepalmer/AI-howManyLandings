import Foundation

/// One point on the pattern-occupancy chart.
struct PatternOccupancySample: Identifiable, Sendable, Equatable {
    var id: Date { time }
    var time: Date
    /// Live + estimated (lost-but-still-counted) aircraft in the pattern.
    var count: Int
    /// Currently reporting ADS-B and in the pattern.
    var liveCount: Int
    /// Lost contacts still counted via estimated time-to-landing.
    var estimatedCount: Int
}

enum PatternOccupancy {
    /// Max history retained per airport (wall or recording clock).
    static let maxHistory: TimeInterval = 6 * 60 * 60
    static let maxSamples = 4_000
    /// Mini sidebar chart: panel width spans this window.
    static let miniChartWindow: TimeInterval = 10 * 60

    static func recentSamples(
        _ samples: [PatternOccupancySample],
        now: Date,
        window: TimeInterval = miniChartWindow
    ) -> [PatternOccupancySample] {
        let cutoff = now.addingTimeInterval(-window)
        return samples.filter { $0.time >= cutoff }
    }

    /// Typical remaining time in a piston pattern until landing, by last known leg.
    /// Used when ADS-B drops so lost aircraft still count until the ETA elapses.
    /// Departure / Crosswind / Maneuvering: no ETA — only count while ADS-B is live.
    static func estimatedSecondsToLanding(phase: PatternPhase) -> TimeInterval {
        switch phase {
        case .flare: return 25
        case .final: return 70
        case .base: return 110
        case .downwind: return 180
        case .crosswind, .departure, .upwind, .maneuvering, .leaving, .ground: return 0
        }
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
        if snapshot.onGround { return false }
        if flightState?.isGround == true { return false }
        if patternPhase == .ground || patternPhase == .leaving || patternPhase == .maneuvering {
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
