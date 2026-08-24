import CoreLocation
import Foundation

/// Landing / takeoff detection near this airport.
///
/// - Landing: `onGround` false → true while close to the field / runway
/// - Landing (final/flare): AGL < 0, or AGL < 100 ft and GS < 50 kt
/// - Takeoff: `onGround` true → false while close to the field / runway
///
/// First sighting establishes baseline only (no event).
/// Edges far from this airport (e.g. a neighbor inside the coverage ring) are ignored.
/// Live plane trails keep only the last 5 minutes of points (trimmed each poll).
struct LandingDetector: Sendable {
    /// After a landing, keep the map trail visible this long.
    static let postLandingTrailVisible: TimeInterval = 5 * 60

    /// Field-wide active landing direction (`12`, not `12L` / `12R`).
    /// Set from aircraft on final / flare, or from a landing on a different runway.
    private(set) var activeRunwayDirection: String?

    /// Kept for map dump / UI; mapped from the latest `onGround` bit.
    enum FlightState: String, Sendable {
        case initialGround
        case tookOff
        case landed
        case afterFlyingGround

        var isGround: Bool {
            switch self {
            case .initialGround, .landed, .afterFlyingGround: return true
            case .tookOff: return false
            }
        }
    }

    struct Configuration: Sendable {
        /// Treat a target as still live through this many empty polls (ADS-B gaps).
        var missedPollsBeforeCoasting: Int = 1
        /// Keep aircraft identity this long after the last in-range sample.
        var retainAfterLastSeen: TimeInterval = 60 * 60
        /// After a landing, keep the map trail visible this long.
        var postLandingTrailVisible: TimeInterval = LandingDetector.postLandingTrailVisible
        /// Must be this close to a runway of *this* airport to log landing/takeoff.
        var runwayProximityNM: Double = 0.75
        /// When the catalog has no runway geometry, fall back to distance from the field center.
        var airportFallbackNM: Double = 1.0
        /// Safety cap after the 5-minute time window (typical poll yields far fewer).
        var maxTrackPoints: Int = 64
    }

    struct OutputEvent: Sendable {
        var eventID: UUID
        var kind: TrafficEventKind
        var timestamp: Date
        var icao24: String
        var tailNumber: String
        var category: AircraftCategory
        var typeLabel: String
        var altitudeAGLFt: Double?
        var groundSpeedKt: Double?
        var coordinate: CLLocationCoordinate2D
        var track: [TrackPoint]
        var isUpdate: Bool
    }

    struct TrackedAircraft: Identifiable, Sendable {
        var id: String { snapshot.icao24 }
        var snapshot: AircraftSnapshot
        var track: [TrackPoint]
        /// True while the aircraft is inside the coverage ring and still reporting.
        var inRange: Bool
        var lastSeen: Date
        var firstSeen: Date?
        var lastLandingAt: Date?
        var lastTakeoffAt: Date?
        var flightState: FlightState?
        /// Nautical miles from the tracked airport (last known position).
        var distanceNM: Double
        /// Last known position was airborne inside the 5 NM / 2,000 ft AGL pattern.
        var inPattern: Bool
        /// Inferred traffic-pattern leg; `.maneuvering` until geometry is unambiguous.
        var patternPhase: PatternPhase = .maneuvering
        var patternRunwayIdent: String?

        /// Chip next to the callsign (`Ground`, `Base 27`, `Final 09`, `Maneuvering`, …).
        var patternChipText: String? {
            patternPhase.chipText(runwayIdent: patternRunwayIdent)
        }

        /// Lost ADS-B or left the ring, but the engagement track is still retained.
        var isCoasting: Bool { !inRange }

        /// Landing trail still in the post-landing display window.
        var isPostLandingTrail: Bool {
            guard let lastLandingAt else { return false }
            return Date().timeIntervalSince(lastLandingAt) <= LandingDetector.postLandingTrailVisible
        }

        /// Draw a trail when we have points; the map chooses the time window.
        var shouldDrawTrail: Bool {
            track.count >= 2
        }

        /// Pattern tracker: airborne in-pattern only. Surface ops and post-landing
        /// contacts stay off the list; lost airborne contacts stay ≤ 5 minutes.
        var appearsInTracker: Bool {
            if snapshot.onGround { return false }
            if flightState?.isGround == true { return false }
            if patternPhase == .ground { return false }
            if lastLandingAt != nil, isCoasting { return false }
            guard inPattern else { return false }
            if inRange { return true }
            return Date().timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
        }

        /// On-ground and in-range aircraft always show; coasting uses short windows.
        var isVisibleOnMap: Bool {
            if snapshot.onGround, inRange { return true }
            if appearsInTracker { return true }
            if isCoasting, lastLandingAt != nil { return isPostLandingTrail }
            if isCoasting {
                return Date().timeIntervalSince(lastSeen) <= 90
            }
            return true
        }

        var trackDuration: TimeInterval? {
            let start = firstSeen ?? track.first?.timestamp
            guard let start else { return nil }
            let end = max(lastSeen, track.last?.timestamp ?? lastSeen)
            return end.timeIntervalSince(start)
        }

        var maxAltitudeAGLFt: Double? {
            track.compactMap(\.altitudeAGLFt).max()
        }

        var maxGroundSpeedKt: Double? {
            track.compactMap(\.groundSpeedKt).max()
        }
    }

    private var config: Configuration
    private var states: [String: AircraftMemory] = [:]

    init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    mutating func ingest(
        snapshots: [AircraftSnapshot],
        airport: Airport,
        trackingRadiusNM: Double = Geo.defaultTrackingRadiusNM,
        now: Date = Date()
    ) -> (aircraft: [TrackedAircraft], events: [OutputEvent], purgedICAO24s: Set<String>) {
        var seen: Set<String> = []
        var events: [OutputEvent] = []
        /// Prefer the final/flare aircraft closest to its threshold when several are present.
        var bestFinalScore = Double.greatestFiniteMagnitude

        for snapshot in snapshots where snapshot.category.isAircraft {
            let distanceNM = Geo.distanceNM(snapshot.coordinate, airport.coordinate)
            guard distanceNM <= trackingRadiusNM else { continue }

            seen.insert(snapshot.icao24)
            var memory = states[snapshot.icao24] ?? AircraftMemory(icao24: snapshot.icao24)

            memory.snapshot = snapshot
            memory.lastSeen = now
            memory.consecutiveMissedPolls = 0
            if memory.firstSeen == nil { memory.firstSeen = now }

            let agl = snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt)
            let point = TrackPoint(
                timestamp: snapshot.timestamp,
                coordinate: snapshot.coordinate,
                altitudeAGLFt: agl,
                onGround: snapshot.onGround,
                groundSpeedKt: snapshot.groundSpeedKt,
                trackDeg: snapshot.trackDeg,
                verticalRateFPM: snapshot.verticalRateFPM
            )
            appendEngagementPoint(point, to: &memory, now: now)

            // Kinematic landing uses the prior Final/Flare chip — must run before
            // PatternClassifier, which would otherwise fold AGL < 0 into Ground with no event.
            if let event = evaluateKinematicLanding(
                snapshot: snapshot,
                agl: agl,
                airport: airport,
                memory: &memory
            ) {
                events.append(event)
            } else if let event = evaluateOnGroundEdge(
                snapshot: snapshot,
                agl: agl,
                airport: airport,
                memory: &memory
            ) {
                events.append(event)
            }
            PatternClassifier.update(
                state: &memory.pattern,
                snapshot: snapshot,
                track: memory.track,
                agl: agl,
                airport: airport,
                lastTakeoffAt: memory.lastTakeoffAt,
                now: now,
                activeRunwayDirection: activeRunwayDirection
            )
            // Kinematic / onGround landings must stay Ground even if ADS-B still looks airborne.
            if memory.flightState?.isGround == true {
                memory.pattern.reset()
                memory.pattern.phase = .ground
            }
            if memory.pattern.phase == .final || memory.pattern.phase == .flare,
               let direction = memory.pattern.runwayIdent {
                let score = nearestThresholdDistanceNM(
                    coordinate: snapshot.coordinate,
                    direction: direction,
                    airport: airport
                )
                if direction != activeRunwayDirection || score <= bestFinalScore {
                    activeRunwayDirection = direction
                    bestFinalScore = score
                }
            }
            states[snapshot.icao24] = memory
        }

        for (icao, var memory) in states where !seen.contains(icao) {
            memory.consecutiveMissedPolls += 1
            trimStoredTrack(&memory, now: now)
            states[icao] = memory
        }

        let purgedICAO24s = prune(now: now)

        let aircraft: [TrackedAircraft] = states.values.compactMap { memory in
            guard let snapshot = memory.snapshot else { return nil }
            guard now.timeIntervalSince(memory.lastSeen) <= config.retainAfterLastSeen else { return nil }
            let withinRadius = Geo.distanceNM(snapshot.coordinate, airport.coordinate) <= trackingRadiusNM
            let clipped = memory.track.filter {
                Geo.distanceNM($0.coordinate, airport.coordinate) <= trackingRadiusNM
                    && now.timeIntervalSince($0.timestamp) <= Geo.recentTrailSeconds
            }
            let distance = Geo.distanceNM(snapshot.coordinate, airport.coordinate)
            let agl = snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt)
            let inPattern = Geo.isInPattern(
                coordinate: snapshot.coordinate,
                onGround: snapshot.onGround,
                altitudeAGLFt: agl,
                groundSpeedKt: snapshot.groundSpeedKt,
                airport: airport
            )
            return TrackedAircraft(
                snapshot: snapshot,
                track: clipped,
                inRange: withinRadius && memory.consecutiveMissedPolls <= config.missedPollsBeforeCoasting,
                lastSeen: memory.lastSeen,
                firstSeen: memory.firstSeen,
                lastLandingAt: memory.lastLandingAt,
                lastTakeoffAt: memory.lastTakeoffAt,
                flightState: memory.flightState,
                distanceNM: distance,
                inPattern: inPattern,
                patternPhase: memory.pattern.phase,
                patternRunwayIdent: memory.pattern.runwayIdent
            )
        }
        .sorted { $0.snapshot.displayLabel < $1.snapshot.displayLabel }

        return (aircraft, events, purgedICAO24s)
    }

    mutating func reset() {
        states.removeAll()
        activeRunwayDirection = nil
    }

    // MARK: - Landing / takeoff detection

    /// Final / flare only: AGL < 0, or AGL < 100 ft with GS < 50 kt.
    private mutating func evaluateKinematicLanding(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) -> OutputEvent? {
        guard memory.pattern.phase == .final || memory.pattern.phase == .flare else { return nil }
        if memory.flightState?.isGround == true { return nil }
        if memory.lastOnGround == true { return nil }

        guard let agl else { return nil }
        let speed = snapshot.groundSpeedKt ?? .greatestFiniteMagnitude
        let belowField = agl < 0
        let lowAndSlow = agl < 100 && speed < 50
        guard belowField || lowAndSlow else { return nil }
        guard isCloseEnoughForEvent(coordinate: snapshot.coordinate, airport: airport) else {
            return nil
        }

        return recordLanding(
            snapshot: snapshot,
            agl: agl,
            airport: airport,
            memory: &memory,
            inferredGround: true
        )
    }

    /// Landing = false→true, takeoff = true→false. First sample sets baseline only.
    /// Events require proximity to this airport / its runways.
    private mutating func evaluateOnGroundEdge(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) -> OutputEvent? {
        let onGround = snapshot.onGround

        guard let previous = memory.lastOnGround else {
            memory.lastOnGround = onGround
            memory.flightState = onGround ? .initialGround : .tookOff
            return nil
        }

        // After a kinematic landing, ADS-B may still report airborne — stay on the ground
        // until speed/altitude clearly show a takeoff.
        if memory.groundInferred, previous, !onGround {
            let aglFt = agl ?? 0
            let speed = snapshot.groundSpeedKt ?? 0
            if aglFt < 100 || speed < 50 {
                memory.lastOnGround = true
                memory.flightState = .landed
                return nil
            }
            memory.groundInferred = false
        }

        memory.lastOnGround = onGround
        memory.flightState = onGround ? .landed : .tookOff

        guard previous != onGround else { return nil }
        guard isCloseEnoughForEvent(coordinate: snapshot.coordinate, airport: airport) else {
            return nil
        }

        if onGround {
            return recordLanding(
                snapshot: snapshot,
                agl: agl,
                airport: airport,
                memory: &memory,
                inferredGround: false
            )
        }

        memory.lastTakeoffAt = snapshot.timestamp
        memory.lastLandingAt = nil
        memory.groundInferred = false
        memory.pattern.phase = .departure
        memory.pattern.sawCrosswind = false
        return OutputEvent(
            eventID: UUID(),
            kind: .takeoff,
            timestamp: snapshot.timestamp,
            icao24: snapshot.icao24,
            tailNumber: memory.snapshot?.displayLabel ?? snapshot.displayLabel,
            category: memory.snapshot?.category ?? snapshot.category,
            typeLabel: memory.snapshot?.typeDisplay ?? snapshot.category.displayName,
            altitudeAGLFt: agl,
            groundSpeedKt: snapshot.groundSpeedKt,
            coordinate: snapshot.coordinate,
            track: TrackPoint.detachedCopy(memory.track),
            isUpdate: false
        )
    }

    private mutating func recordLanding(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory,
        inferredGround: Bool
    ) -> OutputEvent {
        memory.lastOnGround = true
        memory.flightState = .landed
        memory.lastLandingAt = snapshot.timestamp
        memory.groundInferred = inferredGround
        memory.pattern.reset()
        memory.pattern.phase = .ground
        if let direction = landingRunwayDirection(
            coordinate: snapshot.coordinate,
            heading: snapshot.trackDeg,
            airport: airport
        ) {
            activeRunwayDirection = direction
        }
        return OutputEvent(
            eventID: UUID(),
            kind: .fullStop,
            timestamp: snapshot.timestamp,
            icao24: snapshot.icao24,
            tailNumber: memory.snapshot?.displayLabel ?? snapshot.displayLabel,
            category: memory.snapshot?.category ?? snapshot.category,
            typeLabel: memory.snapshot?.typeDisplay ?? snapshot.category.displayName,
            altitudeAGLFt: agl,
            groundSpeedKt: snapshot.groundSpeedKt,
            coordinate: snapshot.coordinate,
            track: TrackPoint.detachedCopy(memory.track),
            isUpdate: false
        )
    }

    /// Geographic gate: near *this* airport's runways (or the field if no runway data).
    /// A wide circle around the field was letting neighboring airports count as landings.
    private func isCloseEnoughForEvent(coordinate: CLLocationCoordinate2D, airport: Airport) -> Bool {
        if airport.runways.isEmpty {
            return Geo.distanceNM(coordinate, airport.coordinate) <= config.airportFallbackNM
        }
        return airport.runways.contains {
            Geo.distanceNM(from: coordinate, to: $0) <= config.runwayProximityNM
        }
    }

    /// Landing direction for the runway end closest to the touchdown (parallels → shared direction).
    private func landingRunwayDirection(
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        airport: Airport
    ) -> String? {
        let approaches = airport.runways.flatMap(\.approaches)
        guard !approaches.isEmpty else { return nil }
        var best: RunwayApproach?
        var bestScore = Double.greatestFiniteMagnitude
        for approach in approaches {
            let frame = approach.frame(at: coordinate)
            var score = abs(frame.crossRight) * 4 + abs(min(0, frame.along)) + max(0, frame.along - approach.lengthNM)
            score += approach.distanceToRunwayNM(from: coordinate)
            if let heading, Geo.isAbout(heading, approach.headingDeg, tolerance: 40) {
                score -= 0.35
            }
            if score < bestScore {
                bestScore = score
                best = approach
            }
        }
        return best?.directionIdent
    }

    private func nearestThresholdDistanceNM(
        coordinate: CLLocationCoordinate2D,
        direction: String,
        airport: Airport
    ) -> Double {
        let matches = airport.runways.flatMap(\.approaches).filter { $0.directionIdent == direction }
        guard !matches.isEmpty else {
            return Geo.distanceNM(coordinate, airport.coordinate)
        }
        return matches.map { $0.distanceToThresholdNM(from: coordinate) }.min() ?? .greatestFiniteMagnitude
    }

    /// Keep only the last 5 minutes of samples; coalesce parked chatter.
    private func appendEngagementPoint(_ point: TrackPoint, to memory: inout AircraftMemory, now: Date) {
        if let last = memory.track.last, shouldCoalesce(existing: last, incoming: point) {
            memory.track[memory.track.count - 1] = point
            trimStoredTrack(&memory, now: now)
            return
        }
        memory.track.append(point)
        trimStoredTrack(&memory, now: now)
        if memory.track.count > config.maxTrackPoints {
            memory.track = Self.thinTrack(memory.track, maxPoints: config.maxTrackPoints)
        }
    }

    private func trimStoredTrack(_ memory: inout AircraftMemory, now: Date) {
        let cutoff = now.addingTimeInterval(-Geo.recentTrailSeconds)
        guard let oldest = memory.track.first, oldest.timestamp < cutoff else { return }
        memory.track.removeAll { $0.timestamp < cutoff }
    }

    private func shouldCoalesce(existing: TrackPoint, incoming: TrackPoint) -> Bool {
        let dt = incoming.timestamp.timeIntervalSince(existing.timestamp)
        guard dt >= 0 else { return false }
        guard existing.onGround == incoming.onGround else { return false }
        let dist = Geo.distanceMeters(existing.coordinate, incoming.coordinate)
        let speedDelta = abs((existing.groundSpeedKt ?? 0) - (incoming.groundSpeedKt ?? 0))
        let altDelta = abs((existing.altitudeAGLFt ?? 0) - (incoming.altitudeAGLFt ?? 0))

        // Parked / taxi: coalesce aggressively — this is the main memory/UI blow-up.
        if existing.onGround {
            return dt < 120 && dist < 40 && speedDelta < 8
        }
        // Airborne: only merge near-duplicates from the same poll burst.
        return dt < 12 && dist < 25 && speedDelta < 8 && altDelta < 80
    }

    /// Uniformly keeps endpoints so long engagements stay drawable without thousands of points.
    static func thinTrack(_ points: [TrackPoint], maxPoints: Int) -> [TrackPoint] {
        guard points.count > maxPoints, maxPoints >= 3 else { return points }
        let last = points.count - 1
        let step = Double(last) / Double(maxPoints - 1)
        var seen = Set<Int>()
        var result: [TrackPoint] = []
        result.reserveCapacity(maxPoints)
        for index in 0..<maxPoints {
            let source = min(last, Int((Double(index) * step).rounded()))
            guard seen.insert(source).inserted else { continue }
            result.append(points[source])
        }
        return result
    }

    /// Drops engagement memory older than `retainAfterLastSeen`. Returns purged Mode-S IDs.
    private mutating func prune(now: Date) -> Set<String> {
        let stale = now.addingTimeInterval(-config.retainAfterLastSeen)
        var purged: Set<String> = []
        states = states.filter { icao24, memory in
            if memory.lastSeen > stale { return true }
            purged.insert(icao24)
            return false
        }
        return purged
    }
}

// MARK: - Private types

private struct AircraftMemory: Sendable {
    var icao24: String
    var snapshot: AircraftSnapshot?
    var firstSeen: Date?
    var lastSeen: Date = .distantPast
    var consecutiveMissedPolls: Int = 0
    var track: [TrackPoint] = []
    /// Last ADS-B `onGround` value; nil until first sighting.
    var lastOnGround: Bool?
    var lastLandingAt: Date?
    var lastTakeoffAt: Date?
    var flightState: LandingDetector.FlightState?
    /// Landing was inferred from final/flare AGL/speed (ADS-B `onGround` may still be false).
    var groundInferred: Bool = false
    var pattern = PatternCircuitState()
}

/*
 // =============================================================================
 // PREVIOUS state-machine landing/takeoff logic (commented out for A/B).
 // Landing was multi-sample ground evidence while airborne; takeoff was multi-sample
 // airborne evidence while on ground, with init consensus, demotion, proximity gates.
 // =============================================================================

    private mutating func evaluate(
        sample: Sample,
        memory: inout AircraftMemory,
        now: Date
    ) -> [OutputEvent] {
        if memory.flightState == nil {
            gatherInitialConsensus(sample: sample, memory: &memory)
            return []
        }

        var events: [OutputEvent] = []
        let kind = classify(sample)
        guard let phase = memory.flightState else { return [] }

        switch kind {
        case .ambiguous:
            return []

        case .ground:
            if phase.isGround {
                memory.matchingStateCount += 1
                memory.mismatchStateCount = 0
                // … settle to afterFlyingGround …
            } else if memory.awaitingAirborneConfirmation, isClearlyOnSurface(sample) {
                // demote wrong airborne init after repeated surface reports
            } else {
                // accumulate ground evidence → emit fullStop landing
            }

        case .flying:
            if !phase.isGround {
                // confirm airborne / landingEligible
            } else {
                // accumulate airborne evidence → emit takeoff
            }
        }

        return events
    }

    // Also previously: gatherInitialConsensus, lockInitialGround/Airborne, initVote,
    // isClearlyOnSurface, hasEnoughAirborneEvidence, hasEnoughGroundEvidence, classify,
    // isCloseEnoughForEvent, canAcceptTakeoff, canAcceptLanding, emit, makeSample.
 */
