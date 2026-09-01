import CoreLocation
import Foundation

/// Pattern tracking and aircraft state near this airport.
///
/// - Landing (1, confirmed): `onGround` false → true while close to the field / runway
/// - Landing (1b, confirmed): Final/Flare approach (pending) ends on the surface near the
///   pending runway (along/cross-track corridor, ADS-B position-error margin) — log at that
///   time even when ADS-B never flips `onGround` or AGL stays above the field
/// - Landing (2, confirmed): Final/Flare, AGL < 0, GS < 1.3×Vso
/// - Landing (deferred): reaching Final or Flare starts a pending approach; the landing
///   is logged when (1) or (2) fires, or when the aircraft reappears on Departure / Upwind
///   (touch-and-go / missed ADS-B touchdown; landing + inferred takeoff), or ADS-B is lost
///   for 60+ seconds on approach. Deferred landings use the lowest AGL time during the
///   approach and are marked unconfirmed.
/// - Takeoff (1, confirmed): `onGround` true → false while close to the field / runway
/// - Takeoff (2, inferred): touch-and-go climb after a logged landing without a ground edge
/// - Takeoff (3, inferred): late ADS-B pickup — first sample airborne in the active-runway
///   departure corridor below 500 ft AGL with climb-out speed (1.1–2.0×Vso, category cap)
///
/// First sighting on the surface establishes baseline only (no landing).
/// Other first sightings are baseline airborne unless takeoff (3) fires.
/// Edges far from this airport (e.g. a neighbor inside the coverage ring) are ignored.
/// Live plane trails keep only the last 5 minutes of points (trimmed each poll).
struct LandingDetector: Sendable {
    /// After a landing, keep the map trail visible this long.
    static let postLandingTrailVisible: TimeInterval = 5 * 60
    /// Pending Final/Flare approach: log unconfirmed landing after this long without ADS-B.
    static let pendingLandingLostSeconds: TimeInterval = 60

    /// Field-wide active landing direction (`12`, not `12L` / `12R`).
    /// Set from METAR guess until the first landing; then from traffic.
    private(set) var activeRunwayDirection: String?
    private var runwayEstablishedByLanding = false
    private var landingMarkersBuffer: [PatternLandingMarker] = []
    private var takeoffMarkersBuffer: [PatternTakeoffMarker] = []
    /// Max time after touchdown to infer a touch-and-go takeoff without an on-ground edge.
    private let touchAndGoTakeoffWindow: TimeInterval = 4 * 60
    /// Minimum seconds on the ground before a climb-out counts as a new takeoff.
    private let touchAndGoMinGroundSeconds: TimeInterval = 8

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
        var patternIsApproach: Bool = false
        var patternHeldLeg: PatternHeldLeg?
        var patternLiberalUncertain: Bool = false
        var patternStatusUnknown: Bool = false
        /// Final/Flare approach waiting for touchdown confirmation.
        var pendingLandingSince: Date?
        var pendingLandingPhase: PatternPhase?
        /// Manual leg or landing override from the pattern tracker.
        var userAssignment: TrackerUserAssignment?
        /// Clock used for visibility / coast windows (wall time live; poll time during replay).
        var asOf: Date = Date()

        var isUserLandedAssignment: Bool {
            userAssignment == .landed
        }

        /// Chip shows Landed (user override or auto-detected touchdown).
        var showsLandedChip: Bool {
            isUserLandedAssignment || isRecentlyLandedForTracker
        }

        /// Display leg: user pattern override when set, otherwise auto classification.
        var displayPatternPhase: PatternPhase {
            if case .patternPhase(let phase) = userAssignment { return phase }
            if pendingLandingSince != nil, patternPhase == .ground,
               let pendingLandingPhase {
                return pendingLandingPhase
            }
            return patternPhase
        }

        var hasPendingLanding: Bool { pendingLandingSince != nil }

        var effectivePatternStatusUnknown: Bool {
            if userAssignment != nil { return false }
            if hasPendingLanding { return false }
            return patternStatusUnknown
        }

        var effectivePatternLiberalUncertain: Bool {
            userAssignment != nil ? false : patternLiberalUncertain
        }

        /// Chip next to the callsign (`Ground`, `Base 27`, `Final 09`, `Maneuvering`, …).
        var patternChipText: String? {
            if showsLandedChip { return "Landed" }
            if case .patternPhase(let user) = userAssignment {
                return user.chipText(
                    runwayIdent: patternRunwayIdent,
                    isApproach: patternIsApproach
                )
            }
            let phase = displayPatternPhase
            if patternStatusUnknown || (patternPhase == .ground && !hasPendingLanding) {
                return patternLiberalUncertain ? "Unknown?" : "Unknown"
            }
            return phase.chipText(
                runwayIdent: patternRunwayIdent,
                isApproach: patternIsApproach,
                heldLeg: patternHeldLeg,
                liberalUncertain: patternLiberalUncertain
            )
        }

        /// Lost ADS-B or left the ring, but the engagement track is still retained.
        var isCoasting: Bool { !inRange }

        /// Landing trail still in the post-landing display window.
        /// Live ADS-B uses time since touchdown; after signal loss only
        /// `Geo.trackerCoastSeconds` from the last report.
        var isPostLandingTrail: Bool {
            guard lastLandingAt != nil else { return false }
            if isCoasting {
                return asOf.timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
            }
            return asOf.timeIntervalSince(lastLandingAt!) <= LandingDetector.postLandingTrailVisible
        }

        /// On the surface after a landing, still inside the post-landing window.
        var isRecentlyLandedForTracker: Bool {
            guard isPostLandingTrail else { return false }
            return snapshot.onGround
                || flightState?.isGround == true
                || patternPhase == .ground
        }

        /// Draw a trail when we have points; the map chooses the time window.
        var shouldDrawTrail: Bool {
            track.count >= 2
        }

        /// Pattern panel: recently landed, pending approach rollout, or plane glyph in the ring.
        func appearsInPatternPanel(airportElevationFt: Int) -> Bool {
            if isRecentlyLandedForTracker { return true }
            if hasPendingLanding {
                guard distanceNM <= Geo.patternRadiusNM else { return false }
                if inRange { return true }
                return asOf.timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
            }
            if snapshot.onGround || flightState?.isGround == true { return false }
            if lastLandingAt != nil, isCoasting { return false }
            guard showsPatternPlaneGlyph(airportElevationFt: airportElevationFt) else { return false }

            let inRing = distanceNM <= Geo.patternRadiusNM
            let offLeg = displayPatternPhase == .maneuvering
                || displayPatternPhase == .leaving
                || effectivePatternStatusUnknown
                || effectivePatternLiberalUncertain

            // Maneuvering / leaving / uncertain: ring + glyph (not strict inPattern geometry).
            if offLeg {
                guard inRing else { return false }
            } else {
                if displayPatternPhase == .ground { return false }
                guard inPattern else { return false }
            }

            if inRange { return true }
            return asOf.timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
        }

        /// Same glyph rules as the map: colored aircraft symbol, not the enroute arrow.
        func showsPatternPlaneGlyph(airportElevationFt: Int) -> Bool {
            if hasPendingLanding {
                if snapshot.onGround { return false }
                if TrackPalette.isEnroute(snapshot, airportElevationFt: airportElevationFt) { return false }
                return true
            }
            if snapshot.onGround { return false }
            if TrackPalette.isEnroute(snapshot, airportElevationFt: airportElevationFt) { return false }
            if Geo.isSurfaceOps(
                onGround: snapshot.onGround,
                altitudeAGLFt: snapshot.altitudeAGLFt(airportElevationFt: airportElevationFt),
                groundSpeedKt: snapshot.groundSpeedKt
            ) {
                return false
            }
            return true
        }

        /// Pattern tracker: airborne in-pattern, plus recently landed (live ADS-B or ≤ 90s lost).
        /// Lost airborne contacts stay ≤ `Geo.trackerCoastSeconds`.
        var appearsInTracker: Bool {
            if isRecentlyLandedForTracker { return true }
            if hasPendingLanding {
                guard distanceNM <= Geo.patternRadiusNM else { return false }
                if inRange { return true }
                return asOf.timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
            }
            if snapshot.onGround { return false }
            if flightState?.isGround == true { return false }
            if displayPatternPhase == .ground { return false }
            if lastLandingAt != nil, isCoasting { return false }
            guard inPattern else { return false }
            if inRange { return true }
            return asOf.timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
        }

        /// On-ground and in-range aircraft always show; coasting uses short windows.
        var isVisibleOnMap: Bool {
            if snapshot.onGround, inRange { return true }
            if appearsInTracker { return true }
            if isCoasting, lastLandingAt != nil { return isPostLandingTrail }
            if isCoasting {
                return asOf.timeIntervalSince(lastSeen) <= Geo.trackerCoastSeconds
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

    var trackedICAO24s: Set<String> { Set(states.keys) }

    mutating func ingest(
        snapshots: [AircraftSnapshot],
        airport: Airport,
        trackingRadiusNM: Double = Geo.defaultTrackingRadiusNM,
        now: Date = Date()
    ) -> (
        aircraft: [TrackedAircraft],
        purgedICAO24s: Set<String>,
        landingMarkers: [PatternLandingMarker],
        takeoffMarkers: [PatternTakeoffMarker]
    ) {
        landingMarkersBuffer = []
        takeoffMarkersBuffer = []
        let snapshots = AircraftSnapshotDeduplicator.deduplicated(
            snapshots,
            preferredICAO24: trackedICAO24s
        )
        var seen: Set<String> = []
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

            applyOnGroundEdge(
                snapshot: snapshot,
                agl: agl,
                airport: airport,
                memory: &memory
            )
            if !memory.landingMarkerRecorded {
                processPendingLanding(
                    snapshot: snapshot,
                    agl: agl,
                    airport: airport,
                    memory: &memory
                )
            }
            if !memory.landingMarkerRecorded {
                applyApproachToGroundLanding(
                    snapshot: snapshot,
                    agl: agl,
                    airport: airport,
                    memory: &memory
                )
            }
            if !memory.landingMarkerRecorded {
                applyLowAndSlowLanding(
                    snapshot: snapshot,
                    agl: agl,
                    airport: airport,
                    memory: &memory
                )
            }

            // Confirmed / full-stop landings must stay Ground even if ADS-B still looks airborne.
            if memory.flightState?.isGround == true {
                memory.pattern.reset()
                memory.pattern.phase = .ground
            }
            if memory.userAssignment != nil,
               shouldClearUserOverride(memory: memory, snapshot: snapshot) {
                memory.userAssignment = nil
            }
            applyInferredTakeoff(
                snapshot: snapshot,
                agl: agl,
                airport: airport,
                memory: &memory
            )
            if memory.pattern.phase == .final || memory.pattern.phase == .flare,
               let ident = memory.pattern.runwayIdent {
                let direction = RunwayApproach.directionIdent(ident)
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

        collapseDuplicateStates()

        for (icao, var memory) in states where !seen.contains(icao) {
            memory.consecutiveMissedPolls += 1
            trimStoredTrack(&memory, now: now)
            if !memory.landingMarkerRecorded,
               memory.pendingLandingSince != nil,
               now.timeIntervalSince(memory.lastSeen) > Self.pendingLandingLostSeconds,
               let snapshot = memory.snapshot {
                resolvePendingLanding(
                    snapshot: snapshot,
                    airport: airport,
                    memory: &memory
                )
            }
            states[icao] = memory
        }

        let purgedICAO24s = prune(now: now)

        let aircraft = buildTrackedAircraftList(
            airport: airport,
            trackingRadiusNM: trackingRadiusNM,
            now: now
        )

        let landingMarkers = landingMarkersBuffer
        let takeoffMarkers = takeoffMarkersBuffer
        landingMarkersBuffer = []
        takeoffMarkersBuffer = []
        return (aircraft, purgedICAO24s, landingMarkers, takeoffMarkers)
    }

    mutating func setUserAssignment(_ assignment: TrackerUserAssignment?, icao24: String) {
        guard var memory = states[icao24] else { return }
        memory.userAssignment = assignment
        states[icao24] = memory
    }

    /// Backward-compatible leg-only setter.
    mutating func setUserPatternPhase(_ phase: PatternPhase?, icao24: String) {
        setUserAssignment(phase.map { .patternPhase($0) }, icao24: icao24)
    }

    func rebuildTrackedAircraft(
        airport: Airport,
        trackingRadiusNM: Double,
        now: Date
    ) -> [TrackedAircraft] {
        buildTrackedAircraftList(
            airport: airport,
            trackingRadiusNM: trackingRadiusNM,
            now: now
        )
    }

    private func buildTrackedAircraftList(
        airport: Airport,
        trackingRadiusNM: Double,
        now: Date
    ) -> [TrackedAircraft] {
        states.values.compactMap { memory in
            guard let snapshot = memory.snapshot else { return nil }
            guard now.timeIntervalSince(memory.lastSeen) <= config.retainAfterLastSeen else { return nil }
            let withinRadius = Geo.distanceNM(snapshot.coordinate, airport.coordinate) <= trackingRadiusNM
            let clipped = memory.track.filter {
                Geo.distanceNM($0.coordinate, airport.coordinate) <= trackingRadiusNM
                    && now.timeIntervalSince($0.timestamp) <= Geo.recentTrailSeconds
            }
            let distance = Geo.distanceToAirfieldNM(from: snapshot.coordinate, airport: airport)
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
                patternRunwayIdent: memory.pattern.runwayIdent,
                patternIsApproach: memory.pattern.isApproach,
                patternHeldLeg: memory.pattern.heldLeg,
                patternLiberalUncertain: memory.pattern.liberalUncertain,
                patternStatusUnknown: memory.pattern.statusUnknown,
                pendingLandingSince: memory.pendingLandingSince,
                pendingLandingPhase: memory.pendingLandingPhase,
                userAssignment: memory.userAssignment,
                asOf: now
            )
        }
        .sorted { $0.snapshot.displayLabel < $1.snapshot.displayLabel }
    }

    private func shouldClearUserOverride(
        memory: AircraftMemory,
        snapshot: AircraftSnapshot
    ) -> Bool {
        guard let assignment = memory.userAssignment else { return false }
        switch assignment {
        case .landed:
            if memory.flightState == .tookOff { return true }
            if !snapshot.onGround, memory.flightState?.isGround != true {
                return true
            }
            return false
        case .patternPhase(let phase):
            if snapshot.onGround || memory.flightState?.isGround == true { return true }
            if memory.pattern.phase == .flare,
               !memory.pattern.liberalUncertain,
               !memory.pattern.statusUnknown {
                return true
            }
            if !memory.pattern.statusUnknown, !memory.pattern.liberalUncertain,
               phase != memory.pattern.phase {
                return true
            }
            return false
        }
    }

    private mutating func collapseDuplicateStates() {
        var keys = Array(states.keys)
        var index = 0
        while index < keys.count {
            guard let snapA = states[keys[index]]?.snapshot else {
                index += 1
                continue
            }
            var merged = false
            for other in (index + 1)..<keys.count {
                guard let snapB = states[keys[other]]?.snapshot else { continue }
                guard AircraftSnapshotDeduplicator.areColocatedDuplicates(snapA, snapB) else { continue }
                let keep = pickStateWinnerICAO(keys[index], keys[other])
                let drop = keep == keys[index] ? keys[other] : keys[index]
                states.removeValue(forKey: drop)
                keys.removeAll { $0 == drop }
                merged = true
                break
            }
            if !merged { index += 1 }
        }
    }

    private func pickStateWinnerICAO(_ a: String, _ b: String) -> String {
        guard let snapA = states[a]?.snapshot, let snapB = states[b]?.snapshot else { return a }
        let scoreA = AircraftSnapshotDeduplicator.qualityScore(snapA, preferredICAO24: trackedICAO24s)
        let scoreB = AircraftSnapshotDeduplicator.qualityScore(snapB, preferredICAO24: trackedICAO24s)
        if scoreA != scoreB { return scoreA > scoreB ? a : b }
        let seenA = states[a]?.lastSeen ?? .distantPast
        let seenB = states[b]?.lastSeen ?? .distantPast
        return seenA >= seenB ? a : b
    }

    mutating func reset() {
        states.removeAll()
        activeRunwayDirection = nil
        runwayEstablishedByLanding = false
        landingMarkersBuffer = []
        takeoffMarkersBuffer = []
    }

    /// METAR-based guess before any landing. Ignored after the first touchdown or if runway already set.
    mutating func applyMETARRunwayGuess(_ direction: String?) {
        guard !runwayEstablishedByLanding else { return }
        guard activeRunwayDirection == nil else { return }
        guard let direction else { return }
        activeRunwayDirection = RunwayApproach.directionIdent(direction)
    }

    var hasLandingEstablishedRunway: Bool { runwayEstablishedByLanding }

    // MARK: - Surface state (no event log)

    private static let nearGroundAGLFt = 100.0
    /// ~300 ft horizontal ADS-B uncertainty on/near the surface, plus a little slack.
    private static let adsbPositionErrorMarginNM = 0.05
    /// Half-width when strip width is not in the dataset (~75 ft each side).
    private static let runwayHalfWidthNM = 0.02
    /// Along-runway slack before the threshold (approach path) and through rollout.
    private static let runwayApproachAlongMarginNM = 0.10
    private static let runwayRolloutAlongMarginNM = 0.08
    /// First ADS-B sample must be below this AGL to infer a late-pickup takeoff.
    private static let latePickupMaxAGLFt = 500.0
    private static let latePickupMinAlongFraction = 0.08
    private static let latePickupHeadingToleranceDeg = 40.0
    private static let latePickupAllowedPhases: Set<PatternPhase> = [
        .departure, .upwind, .maneuvering,
    ]

    /// Criterion 2: below field (AGL < 0) on approach, GS below 1.3×Vso.
    /// Fires on Final/Flare, pending approach, or negative AGL near the runway (rollout join).
    @discardableResult
    private mutating func applyLowAndSlowLanding(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) -> Bool {
        guard isInKinematicLandingContext(
            memory: memory,
            agl: agl,
            airport: airport,
            coordinate: snapshot.coordinate
        ) else { return false }
        if memory.pendingLandingSince == nil,
           memory.pattern.phase != .final,
           memory.pattern.phase != .flare {
            guard let agl, agl < 0 else { return false }
        } else if memory.pendingLandingSince == nil {
            guard hasTrackedApproachDescent(memory: memory) else { return false }
        }
        guard !kinematicLandingBlocked(memory: memory) else { return false }
        guard let agl, agl < 0 else { return false }

        let speed = snapshot.groundSpeedKt ?? .greatestFiniteMagnitude
        let limit = kinematicLandingSpeedLimitKnots(agl: agl, snapshot: snapshot)
        guard speed < limit else { return false }
        guard isCloseEnoughForSurfaceOps(coordinate: snapshot.coordinate, airport: airport) else {
            return false
        }

        applyLandingState(
            snapshot: snapshot,
            airport: airport,
            memory: &memory,
            landingTime: memory.pendingLandingBestTime ?? snapshot.timestamp,
            confirmed: true,
            inferGroundState: true
        )
        return true
    }

    /// Criterion 1b: pending Final/Flare approach reaches the surface — log at touchdown time.
    @discardableResult
    private mutating func applyApproachToGroundLanding(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) -> Bool {
        guard memory.pendingLandingSince != nil else { return false }
        guard isOnSurfaceAfterApproach(snapshot: snapshot, agl: agl, memory: memory) else {
            return false
        }
        if isColdStartClimbOut(memory: memory) { return false }
        guard isNearRunwayForApproachLanding(
            coordinate: snapshot.coordinate,
            airport: airport,
            memory: memory
        ) else {
            return false
        }

        applyLandingState(
            snapshot: snapshot,
            airport: airport,
            memory: &memory,
            landingTime: snapshot.timestamp,
            confirmed: true,
            inferGroundState: !snapshot.onGround,
            setGroundPhase: true
        )
        return true
    }

    private func isOnSurfaceAfterApproach(
        snapshot: AircraftSnapshot,
        agl: Double?,
        memory: AircraftMemory
    ) -> Bool {
        if memory.pattern.phase == .ground { return true }
        if snapshot.onGround { return true }
        if memory.flightState?.isGround == true { return true }
        return Geo.isSurfaceOps(
            onGround: snapshot.onGround,
            altitudeAGLFt: agl,
            groundSpeedKt: snapshot.groundSpeedKt
        )
    }

    /// Runway corridor for criterion 1b: on the pending approach strip, within ADS-B error.
    private func isNearRunwayForApproachLanding(
        coordinate: CLLocationCoordinate2D,
        airport: Airport,
        memory: AircraftMemory
    ) -> Bool {
        if airport.runways.isEmpty {
            return Geo.distanceNM(coordinate, airport.coordinate) <= config.airportFallbackNM
        }

        let approaches = airport.runways.flatMap(\.approaches)
        let crossLimit = Self.runwayHalfWidthNM + Self.adsbPositionErrorMarginNM
        let preferred = memory.pendingLandingRunwayIdent.map(RunwayApproach.displayIdent)

        let candidates: [RunwayApproach]
        if let preferred,
           let match = approaches.first(where: { approachMatchesPreferred($0, preferred: preferred) }) {
            candidates = [match]
        } else {
            candidates = approaches
        }

        for approach in candidates {
            let frame = approach.frame(at: coordinate)
            guard abs(frame.crossRight) <= crossLimit else { continue }

            let alongMin = -(Self.runwayApproachAlongMarginNM + Self.adsbPositionErrorMarginNM)
            let alongMax = approach.lengthNM + Self.runwayRolloutAlongMarginNM + Self.adsbPositionErrorMarginNM
            guard frame.along >= alongMin, frame.along <= alongMax else { continue }

            return true
        }
        return false
    }

    private func isInKinematicLandingContext(
        memory: AircraftMemory,
        agl: Double?,
        airport: Airport,
        coordinate: CLLocationCoordinate2D
    ) -> Bool {
        if memory.pendingLandingSince != nil { return true }
        if memory.pattern.phase == .final || memory.pattern.phase == .flare { return true }
        if let agl, agl < 0,
           isCloseEnoughForSurfaceOps(coordinate: coordinate, airport: airport) {
            return true
        }
        return false
    }

    /// Below-field rollout can exceed 1.3×Vso briefly; deep negative AGL is definitive.
    private func kinematicLandingSpeedLimitKnots(agl: Double, snapshot: AircraftSnapshot) -> Double {
        let threshold = AircraftStallSpeed.patternApproachSpeedKnots(for: snapshot)
        guard agl < 0 else { return threshold }
        if agl < -30 { return .greatestFiniteMagnitude }
        return max(threshold, 85)
    }

    private mutating func updatePendingLandingBestAGL(
        agl: Double?,
        timestamp: Date,
        memory: inout AircraftMemory
    ) {
        guard let agl else { return }
        let best = memory.pendingLandingBestAGL ?? .greatestFiniteMagnitude
        if agl < best {
            memory.pendingLandingBestAGL = agl
            memory.pendingLandingBestTime = timestamp
        }
    }

    private func hasTrackedApproachDescent(memory: AircraftMemory) -> Bool {
        let agls = memory.track.compactMap(\.altitudeAGLFt)
        guard !agls.isEmpty else { return false }
        let maxAGL = agls.max() ?? 0
        let minAGL = agls.min() ?? 0
        if maxAGL - minAGL >= 100 { return true }
        if maxAGL >= 400 { return true }
        if agls.count >= 2, (agls.first ?? 0) - (agls.last ?? 0) >= 40 { return true }
        return false
    }

    /// Joined already low on climb-out with no descent in our track window.
    private func isColdStartClimbOut(memory: AircraftMemory) -> Bool {
        guard memory.pendingLandingSince != nil else { return false }
        let agls = memory.track.compactMap(\.altitudeAGLFt)
        guard agls.count >= 2, let first = agls.first, let last = agls.last else { return false }
        guard first < 200, last >= first - 10 else { return false }
        return (agls.max() ?? 0) - (agls.min() ?? 0) < 100
    }

    /// Final/Flare starts a pending landing; resolve on criteria 1/1b/2 or Departure/Upwind climb-out.
    private mutating func processPendingLanding(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) {
        guard !memory.landingMarkerRecorded else { return }

        switch memory.pattern.phase {
        case .final, .flare:
            if memory.pendingLandingSince == nil {
                guard hasTrackedApproachDescent(memory: memory) else { return }
                memory.pendingLandingSince = snapshot.timestamp
                memory.pendingLandingPhase = memory.pattern.phase
                memory.pendingLandingRunwayIdent = memory.pattern.runwayIdent
                memory.pendingLandingBestTime = snapshot.timestamp
                memory.pendingLandingBestAGL = agl
            } else {
                if let ident = memory.pattern.runwayIdent {
                    memory.pendingLandingRunwayIdent = ident
                }
                updatePendingLandingBestAGL(
                    agl: agl,
                    timestamp: snapshot.timestamp,
                    memory: &memory
                )
            }
        case .ground:
            // Negative AGL is classified as Ground before climb-out; keep or open a pending approach.
            if memory.pendingLandingSince == nil,
               let agl, agl < 0,
               isCloseEnoughForSurfaceOps(coordinate: snapshot.coordinate, airport: airport),
               !isColdStartClimbOut(memory: memory) {
                memory.pendingLandingSince = snapshot.timestamp
                memory.pendingLandingPhase = .flare
                memory.pendingLandingRunwayIdent = memory.pattern.runwayIdent
                    ?? bestRunwayApproach(
                        coordinate: snapshot.coordinate,
                        heading: snapshot.trackDeg,
                        airport: airport
                    )?.ident
                memory.pendingLandingBestTime = snapshot.timestamp
                memory.pendingLandingBestAGL = agl
            } else if memory.pendingLandingSince != nil {
                updatePendingLandingBestAGL(
                    agl: agl,
                    timestamp: snapshot.timestamp,
                    memory: &memory
                )
            }
        case .departure, .upwind, .crosswind:
            resolvePendingLanding(
                snapshot: snapshot,
                airport: airport,
                memory: &memory,
                recordTakeoff: true
            )
        case .base, .downwind:
            clearPendingLanding(&memory)
        default:
            break
        }

        tryResolvePendingAfterRollout(
            snapshot: snapshot,
            agl: agl,
            airport: airport,
            memory: &memory
        )
    }

    /// Touch-and-go climb after sub-field rollout before Departure geometry matches.
    private mutating func tryResolvePendingAfterRollout(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) {
        guard memory.pendingLandingSince != nil else { return }
        guard !memory.landingMarkerRecorded else { return }
        guard let bestAGL = memory.pendingLandingBestAGL, bestAGL < 30 else { return }
        guard let agl, agl > bestAGL + 20 else { return }
        guard !snapshot.onGround else { return }

        let phase = memory.pattern.phase
        let climbingOut = phase == .departure
            || phase == .upwind
            || phase == .crosswind
            || (agl >= 40 && (snapshot.groundSpeedKt ?? 0) >= 35)
        guard climbingOut else { return }

        resolvePendingLanding(
            snapshot: snapshot,
            airport: airport,
            memory: &memory,
            recordTakeoff: true
        )
    }

    private mutating func resolvePendingLanding(
        snapshot: AircraftSnapshot,
        airport: Airport,
        memory: inout AircraftMemory,
        recordTakeoff: Bool = false
    ) {
        guard memory.pendingLandingSince != nil else { return }
        if isColdStartClimbOut(memory: memory) {
            clearPendingLanding(&memory)
            return
        }
        let landingTime = memory.pendingLandingBestTime
            ?? memory.pendingLandingSince
            ?? snapshot.timestamp
        applyLandingState(
            snapshot: snapshot,
            airport: airport,
            memory: &memory,
            landingTime: landingTime,
            confirmed: false,
            inferGroundState: false,
            setGroundPhase: false
        )
        if recordTakeoff {
            recordInferredTakeoffMarker(
                snapshot: snapshot,
                airport: airport,
                memory: &memory
            )
        }
    }

    private func clearPendingLanding(_ memory: inout AircraftMemory) {
        memory.pendingLandingSince = nil
        memory.pendingLandingPhase = nil
        memory.pendingLandingRunwayIdent = nil
        memory.pendingLandingBestTime = nil
        memory.pendingLandingBestAGL = nil
    }

    private func kinematicLandingBlocked(memory: AircraftMemory) -> Bool {
        if memory.flightState?.isGround == true { return true }
        if memory.lastOnGround == true { return true }
        return false
    }

    /// First contact already on the runway (missed the airborne rollout in ADS-B).
    /// First ADS-B sample: on the surface → baseline ground state only (never a landing).
    private func isFirstContactOnSurface(
        snapshot: AircraftSnapshot,
        agl: Double?
    ) -> Bool {
        if snapshot.onGround { return true }
        return Geo.isSurfaceOps(
            onGround: false,
            altitudeAGLFt: agl,
            groundSpeedKt: snapshot.groundSpeedKt
        )
    }

    /// Landing = false→true, takeoff = true→false. First sample sets baseline only.
    private mutating func applyOnGroundEdge(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) {
        let onGround = snapshot.onGround

        guard let previous = memory.lastOnGround else {
            memory.lastOnGround = onGround
            if isFirstContactOnSurface(snapshot: snapshot, agl: agl) {
                memory.flightState = .initialGround
            } else {
                memory.flightState = .tookOff
                applyLatePickupTakeoffIfEligible(
                    snapshot: snapshot,
                    agl: agl,
                    airport: airport,
                    memory: &memory
                )
            }
            return
        }

        // After a kinematic landing, ADS-B may still report airborne — stay on the ground
        // until speed/altitude clearly show a takeoff.
        if memory.groundInferred, previous, !onGround {
            let aglFt = agl ?? 0
            let speed = snapshot.groundSpeedKt ?? 0
            let approachKt = AircraftStallSpeed.patternApproachSpeedKnots(for: snapshot)
            if aglFt < Self.nearGroundAGLFt || speed < approachKt {
                memory.lastOnGround = true
                memory.flightState = .landed
                return
            }
            memory.groundInferred = false
        }

        memory.lastOnGround = onGround

        guard previous != onGround else {
            // Still on ground or still airborne — do not promote initialGround → landed.
            if !onGround {
                memory.flightState = .tookOff
            }
            return
        }

        guard isCloseEnoughForSurfaceOps(coordinate: snapshot.coordinate, airport: airport) else {
            memory.lastOnGround = onGround
            return
        }

        memory.lastOnGround = onGround
        memory.flightState = onGround ? .landed : .tookOff

        if onGround {
            let landingTime = memory.pendingLandingBestTime ?? memory.pendingLandingSince
            applyLandingState(
                snapshot: snapshot,
                airport: airport,
                memory: &memory,
                landingTime: landingTime,
                confirmed: true,
                inferGroundState: false,
                setGroundPhase: true
            )
            return
        }

        clearPendingLanding(&memory)
        memory.lastTakeoffAt = snapshot.timestamp
        memory.lastLandingAt = nil
        memory.groundInferred = false
        memory.landingMarkerRecorded = false
        memory.takeoffMarkerRecorded = true
        memory.pattern.phase = .departure
        memory.pattern.sawCrosswind = false
        if !takeoffMarkersBuffer.contains(where: { abs($0.time.timeIntervalSince(snapshot.timestamp)) < 1 }) {
            takeoffMarkersBuffer.append(
                PatternTakeoffMarker(
                    time: snapshot.timestamp,
                    confirmed: true,
                    label: labelForMarker(snapshot: snapshot)
                )
            )
        }
        if let direction = landingRunwayDirection(
            coordinate: snapshot.coordinate,
            heading: snapshot.trackDeg,
            airport: airport
        ) {
            activeRunwayDirection = direction
        }
    }

    private mutating func applyLandingState(
        snapshot: AircraftSnapshot,
        airport: Airport,
        memory: inout AircraftMemory,
        landingTime: Date? = nil,
        confirmed: Bool,
        inferGroundState: Bool = false,
        setGroundPhase: Bool = true
    ) {
        let time = landingTime ?? snapshot.timestamp
        if !memory.landingMarkerRecorded {
            memory.landingMarkerRecorded = true
            landingMarkersBuffer.append(
                PatternLandingMarker(
                    time: time,
                    confirmed: confirmed,
                    label: labelForMarker(snapshot: snapshot)
                )
            )
        }
        memory.takeoffMarkerRecorded = false
        memory.lastLandingAt = time
        clearPendingLanding(&memory)

        if setGroundPhase || inferGroundState {
            memory.lastOnGround = true
            memory.flightState = .landed
            memory.groundInferred = inferGroundState && !snapshot.onGround
        }

        if setGroundPhase {
            memory.pattern.reset()
            memory.pattern.phase = .ground
        }

        runwayEstablishedByLanding = true
        if let direction = landingRunwayDirection(
            coordinate: snapshot.coordinate,
            heading: snapshot.trackDeg,
            airport: airport
        ) {
            activeRunwayDirection = direction
        }
    }

    /// Geographic gate: near *this* airport's runways (or the field if no runway data).
    private func isCloseEnoughForSurfaceOps(coordinate: CLLocationCoordinate2D, airport: Airport) -> Bool {
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
        bestRunwayApproach(coordinate: coordinate, heading: heading, airport: airport)?.directionIdent
    }

    private func approachMatchesPreferred(_ approach: RunwayApproach, preferred: String) -> Bool {
        let normalized = RunwayApproach.displayIdent(preferred)
        if RunwayApproach.displayIdent(approach.ident) == normalized { return true }
        return approach.directionIdent == RunwayApproach.directionIdent(normalized)
    }

    private func bestRunwayApproach(
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        airport: Airport
    ) -> RunwayApproach? {
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
        return best
    }

    /// Climb-out after a recent touchdown when ADS-B never reports a clean ground→airborne edge (touch-and-go).
    private mutating func applyInferredTakeoff(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) {
        guard !memory.takeoffMarkerRecorded else { return }
        guard let landingAt = memory.lastLandingAt else { return }
        guard memory.landingMarkerRecorded else { return }

        let sinceLanding = snapshot.timestamp.timeIntervalSince(landingAt)
        guard sinceLanding >= touchAndGoMinGroundSeconds else { return }
        guard sinceLanding <= touchAndGoTakeoffWindow else { return }

        if let lastTakeoff = memory.lastTakeoffAt, lastTakeoff >= landingAt { return }

        guard !snapshot.onGround else { return }
        if memory.flightState?.isGround == true { return }

        let phase = memory.pattern.phase
        guard phase == .departure || phase == .upwind || phase == .crosswind else { return }

        guard let aglFt = agl, aglFt >= 80 else { return }
        let speed = snapshot.groundSpeedKt ?? 0
        guard speed >= 35 else { return }

        recordInferredTakeoffMarker(
            snapshot: snapshot,
            airport: airport,
            memory: &memory
        )
    }

    /// Touch-and-go takeoff without an ADS-B ground→airborne edge.
    private mutating func recordInferredTakeoffMarker(
        snapshot: AircraftSnapshot,
        airport: Airport,
        memory: inout AircraftMemory,
        time: Date? = nil
    ) {
        guard !memory.takeoffMarkerRecorded else { return }
        guard isCloseEnoughForSurfaceOps(coordinate: snapshot.coordinate, airport: airport) else {
            return
        }

        let takeoffTime = time ?? snapshot.timestamp
        memory.lastTakeoffAt = takeoffTime
        memory.lastLandingAt = nil
        memory.groundInferred = false
        memory.landingMarkerRecorded = false
        memory.takeoffMarkerRecorded = true
        memory.flightState = .tookOff
        if !takeoffMarkersBuffer.contains(where: { abs($0.time.timeIntervalSince(takeoffTime)) < 1 }) {
            takeoffMarkersBuffer.append(
                PatternTakeoffMarker(
                    time: takeoffTime,
                    confirmed: false,
                    label: labelForMarker(snapshot: snapshot)
                )
            )
        }
        if let direction = landingRunwayDirection(
            coordinate: snapshot.coordinate,
            heading: snapshot.trackDeg,
            airport: airport
        ) {
            activeRunwayDirection = direction
        }
    }

    /// First contact already airborne in the departure corridor (late ADS-B pickup).
    private mutating func applyLatePickupTakeoffIfEligible(
        snapshot: AircraftSnapshot,
        agl: Double?,
        airport: Airport,
        memory: inout AircraftMemory
    ) {
        guard !memory.takeoffMarkerRecorded else { return }
        guard !snapshot.onGround else { return }
        guard memory.flightState?.isGround != true else { return }
        guard Self.latePickupAllowedPhases.contains(memory.pattern.phase) else { return }

        guard let aglFt = agl, aglFt >= 0, aglFt < Self.latePickupMaxAGLFt else { return }
        guard isLatePickupTakeoffSpeed(snapshot: snapshot) else { return }
        guard isInLatePickupDepartureCorridor(
            coordinate: snapshot.coordinate,
            heading: snapshot.trackDeg,
            airport: airport
        ) else { return }

        memory.pattern.phase = .departure
        recordInferredTakeoffMarker(
            snapshot: snapshot,
            airport: airport,
            memory: &memory,
            time: snapshot.timestamp
        )
    }

    private func isLatePickupTakeoffSpeed(snapshot: AircraftSnapshot) -> Bool {
        let speed = snapshot.groundSpeedKt ?? 0
        let minKt = AircraftStallSpeed.latePickupTakeoffMinSpeedKnots(for: snapshot)
        let maxKt = AircraftStallSpeed.latePickupTakeoffMaxSpeedKnots(for: snapshot)
        return speed >= minKt && speed <= maxKt
    }

    /// Active-runway departure corridor: midfield through past the departure end, near centerline.
    private func isInLatePickupDepartureCorridor(
        coordinate: CLLocationCoordinate2D,
        heading: Double?,
        airport: Airport
    ) -> Bool {
        guard let heading else { return false }

        if airport.runways.isEmpty {
            return Geo.distanceNM(coordinate, airport.coordinate) <= config.airportFallbackNM
        }

        let approaches = airport.runways.flatMap(\.approaches)
        let candidates: [RunwayApproach]
        if let active = activeRunwayDirection {
            let matched = approaches.filter { approachMatchesPreferred($0, preferred: active) }
            candidates = matched.isEmpty ? approaches : matched
        } else {
            candidates = approaches
        }

        let crossLimit = Self.runwayHalfWidthNM + Self.adsbPositionErrorMarginNM
        for approach in candidates {
            guard Geo.isAbout(
                heading,
                approach.headingDeg,
                tolerance: Self.latePickupHeadingToleranceDeg
            ) else { continue }

            let frame = approach.frame(at: coordinate)
            guard abs(frame.crossRight) <= crossLimit else { continue }
            // Departure side (not on approach/final past the threshold).
            guard frame.along > -Self.adsbPositionErrorMarginNM else { continue }

            let alongMin = max(
                Self.latePickupMinAlongFraction * approach.lengthNM,
                Self.adsbPositionErrorMarginNM
            )
            let alongMax = approach.lengthNM
                + Self.runwayRolloutAlongMarginNM
                + Self.adsbPositionErrorMarginNM
            guard frame.along >= alongMin, frame.along <= alongMax else { continue }
            return true
        }
        return false
    }

    private func labelForMarker(snapshot: AircraftSnapshot) -> String {
        snapshot.mapLabel
    }

    private func labelForMarker(memory: AircraftMemory) -> String {
        if let snapshot = memory.snapshot {
            return snapshot.mapLabel
        }
        return memory.icao24.uppercased()
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
    /// Landing was inferred from AGL/speed (criterion 2) while ADS-B still shows airborne.
    var groundInferred: Bool = false
    /// Final/Flare seen; landing deferred until criteria 1/1b/2, Departure/Upwind, or 60s lost.
    var pendingLandingSince: Date?
    var pendingLandingPhase: PatternPhase?
    var pendingLandingRunwayIdent: String?
    var pendingLandingBestTime: Date?
    var pendingLandingBestAGL: Double?
    /// One graph marker per landing episode until the next takeoff.
    var landingMarkerRecorded: Bool = false
    /// One graph marker per takeoff episode until the next landing.
    var takeoffMarkerRecorded: Bool = false
    var pattern = PatternCircuitState()
    var userAssignment: TrackerUserAssignment?
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
