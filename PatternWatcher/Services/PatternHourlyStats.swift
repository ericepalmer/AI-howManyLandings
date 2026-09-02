import Foundation

/// One hour of aggregated pattern statistics (retained up to 7 days).
struct PatternHourlyBucket: Identifiable, Sendable, Equatable, Codable {
    var id: Date { hourStart }
    /// Start of the hour bucket (local calendar).
    var hourStart: Date
    var occupancySum: Int = 0
    var occupancySampleCount: Int = 0
    var landingCount: Int = 0

    var averageOccupancy: Double {
        guard occupancySampleCount > 0 else { return 0 }
        return Double(occupancySum) / Double(occupancySampleCount)
    }
}

/// Live summary values for the stats window. Nil when the window has not elapsed yet.
struct PatternStatsSnapshot: Sendable, Equatable {
    var avgLast5Min: Double?
    var avgLast30Min: Double?
    var avgLastHour: Double?
    var avgLast24Hours: Double?
    var peakOccupancy: Int?
    var landingsLast5Min: Int?
    var landingsLast30Min: Int?
    var landingsLastHour: Int?
    var landingsLast24Hours: Int?
}

enum PatternHourlyStats {
    static let hourInterval: TimeInterval = 60 * 60

    static func hourStart(for date: Date, calendar: Calendar = .current) -> Date {
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: components) ?? date
    }

    static func prune(
        buckets: [PatternHourlyBucket],
        now: Date,
        calendar: Calendar = .current
    ) -> [PatternHourlyBucket] {
        let cutoff = now.addingTimeInterval(-PatternOccupancy.maxHistory)
        return buckets.filter { $0.hourStart >= hourStart(for: cutoff, calendar: calendar) }
    }

    static func addOccupancySample(
        buckets: [PatternHourlyBucket],
        count: Int,
        at time: Date,
        calendar: Calendar = .current
    ) -> [PatternHourlyBucket] {
        var buckets = buckets
        let hour = hourStart(for: time, calendar: calendar)
        if let index = buckets.lastIndex(where: { $0.hourStart == hour }) {
            buckets[index].occupancySum += count
            buckets[index].occupancySampleCount += 1
        } else {
            buckets.append(
                PatternHourlyBucket(
                    hourStart: hour,
                    occupancySum: count,
                    occupancySampleCount: 1
                )
            )
        }
        buckets.sort { $0.hourStart < $1.hourStart }
        return prune(buckets: buckets, now: time, calendar: calendar)
    }

    static func adjustOccupancySum(
        buckets: [PatternHourlyBucket],
        delta: Int,
        at time: Date,
        calendar: Calendar = .current
    ) -> [PatternHourlyBucket] {
        guard delta != 0 else { return buckets }
        var buckets = buckets
        let hour = hourStart(for: time, calendar: calendar)
        if let index = buckets.lastIndex(where: { $0.hourStart == hour }) {
            buckets[index].occupancySum += delta
        } else {
            buckets.append(
                PatternHourlyBucket(
                    hourStart: hour,
                    occupancySum: delta,
                    occupancySampleCount: 1
                )
            )
            buckets.sort { $0.hourStart < $1.hourStart }
        }
        return prune(buckets: buckets, now: time, calendar: calendar)
    }

    static func addLandings(
        buckets: [PatternHourlyBucket],
        count: Int,
        at time: Date,
        calendar: Calendar = .current
    ) -> [PatternHourlyBucket] {
        guard count > 0 else { return buckets }
        var buckets = buckets
        let hour = hourStart(for: time, calendar: calendar)
        if let index = buckets.lastIndex(where: { $0.hourStart == hour }) {
            buckets[index].landingCount += count
        } else {
            buckets.append(PatternHourlyBucket(hourStart: hour, landingCount: count))
            buckets.sort { $0.hourStart < $1.hourStart }
        }
        return prune(buckets: buckets, now: time, calendar: calendar)
    }

    /// Hourly series for charting, including empty hours as zero.
    static func chartSeries(
        buckets: [PatternHourlyBucket],
        now: Date,
        calendar: Calendar = .current
    ) -> [PatternHourlyBucket] {
        let endHour = hourStart(for: now, calendar: calendar)
        let startHour = hourStart(
            for: now.addingTimeInterval(-PatternOccupancy.maxHistory),
            calendar: calendar
        )
        let map = Dictionary(uniqueKeysWithValues: buckets.map { ($0.hourStart, $0) })
        var result: [PatternHourlyBucket] = []
        var hour = startHour
        while hour <= endHour {
            result.append(map[hour] ?? PatternHourlyBucket(hourStart: hour))
            guard let next = calendar.date(byAdding: .hour, value: 1, to: hour) else { break }
            hour = next
        }
        return result
    }

    static func snapshot(
        occupancySamples: [PatternOccupancySample],
        landingMarkers: [PatternLandingMarker],
        now: Date,
        feedGapThreshold: TimeInterval
    ) -> PatternStatsSnapshot {
        let span = collectionSpan(
            occupancySamples: occupancySamples,
            landingMarkers: landingMarkers,
            now: now
        )
        let fiveMin: TimeInterval = 5 * 60
        let thirtyMin: TimeInterval = 30 * 60
        return PatternStatsSnapshot(
            avgLast5Min: optionalAverage(
                samples: occupancySamples,
                window: fiveMin,
                span: span,
                now: now,
                feedGapThreshold: feedGapThreshold
            ),
            avgLast30Min: optionalAverage(
                samples: occupancySamples,
                window: thirtyMin,
                span: span,
                now: now,
                feedGapThreshold: feedGapThreshold
            ),
            avgLastHour: optionalAverage(
                samples: occupancySamples,
                window: hourInterval,
                span: span,
                now: now,
                feedGapThreshold: feedGapThreshold
            ),
            avgLast24Hours: optionalAverage(
                samples: occupancySamples,
                window: 24 * hourInterval,
                span: span,
                now: now,
                feedGapThreshold: feedGapThreshold
            ),
            peakOccupancy: occupancySamples.isEmpty
                ? nil
                : peakOccupancy(samples: occupancySamples, now: now),
            landingsLast5Min: optionalLandingCount(
                markers: landingMarkers,
                window: fiveMin,
                span: span,
                now: now
            ),
            landingsLast30Min: optionalLandingCount(
                markers: landingMarkers,
                window: thirtyMin,
                span: span,
                now: now
            ),
            landingsLastHour: optionalLandingCount(
                markers: landingMarkers,
                window: hourInterval,
                span: span,
                now: now
            ),
            landingsLast24Hours: optionalLandingCount(
                markers: landingMarkers,
                window: 24 * hourInterval,
                span: span,
                now: now
            )
        )
    }

    /// Time since the first occupancy or landing record through `now`.
    static func collectionSpan(
        occupancySamples: [PatternOccupancySample],
        landingMarkers: [PatternLandingMarker],
        now: Date
    ) -> TimeInterval {
        var earliest: Date?
        if let sampleStart = occupancySamples.map(\.time).min() {
            earliest = sampleStart
        }
        if let landingStart = landingMarkers.map(\.time).min() {
            if let existing = earliest {
                earliest = min(existing, landingStart)
            } else {
                earliest = landingStart
            }
        }
        guard let earliest else { return 0 }
        return max(0, now.timeIntervalSince(earliest))
    }

    private static func optionalAverage(
        samples: [PatternOccupancySample],
        window: TimeInterval,
        span: TimeInterval,
        now: Date,
        feedGapThreshold: TimeInterval
    ) -> Double? {
        guard span >= window else { return nil }
        let windowed = samplesInWindow(samples, window: window, now: now)
        guard !windowed.isEmpty else { return nil }
        if let latest = windowed.map(\.time).max(),
           now.timeIntervalSince(latest) > feedGapThreshold {
            return nil
        }
        return averageOccupancy(samples: samples, window: window, now: now)
    }

    private static func optionalLandingCount(
        markers: [PatternLandingMarker],
        window: TimeInterval,
        span: TimeInterval,
        now: Date
    ) -> Int? {
        guard span >= window else { return nil }
        return landingCount(markers: markers, window: window, now: now)
    }

    private static func samplesInWindow(
        _ samples: [PatternOccupancySample],
        window: TimeInterval,
        now: Date
    ) -> [PatternOccupancySample] {
        let cutoff = now.addingTimeInterval(-window)
        return samples.filter { $0.time >= cutoff && $0.time <= now }
    }

    static func averageOccupancy(
        samples: [PatternOccupancySample],
        window: TimeInterval,
        now: Date
    ) -> Double {
        let windowed = samplesInWindow(samples, window: window, now: now)
        guard !windowed.isEmpty else { return 0 }
        let total = windowed.reduce(0) { $0 + $1.count }
        return Double(total) / Double(windowed.count)
    }

    static func peakOccupancy(
        samples: [PatternOccupancySample],
        now: Date
    ) -> Int {
        let cutoff = now.addingTimeInterval(-PatternOccupancy.maxHistory)
        return samples
            .filter { $0.time >= cutoff && $0.time <= now }
            .map(\.count)
            .max() ?? 0
    }

    static func landingCount(
        markers: [PatternLandingMarker],
        window: TimeInterval,
        now: Date
    ) -> Int {
        let cutoff = now.addingTimeInterval(-window)
        return markers.filter { $0.time >= cutoff && $0.time <= now }.count
    }
}
