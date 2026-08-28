import CoreLocation
import Foundation

/// Where an aircraft sits in this field’s traffic pattern.
///
/// Two independent kinds of labels:
/// - **Sequential** (status + profile): Departure → Upwind → Crosswind → Downwind.
///   Each step needs the previous status *and* the matching flight profile.
///   A 360, a messy pattern, or an ADS-B gap will not invent these.
/// - **Profile-only**: Base, Final, Flare. These depend only on heading,
///   AGL, speed, and geometry — never on the last labeled phase.
/// - **Turns**: while heading is changing toward the next leg and has not
///   arrived, keep the previous label (mid-turn ADS-B headings).
/// - **Maneuvering**: none of the set tests matched (360, offset, or messy).
/// - **Ground**: taxi, run-up, or parked on the surface.
enum PatternPhase: String, Sendable, Equatable {
    case ground
    case maneuvering
    case departure
    case upwind
    case crosswind
    case downwind
    case base
    case final
    case flare
    case leaving

    var title: String {
        switch self {
        case .ground: return "Ground"
        case .maneuvering: return "Maneuvering"
        case .departure: return "Departure"
        case .upwind: return "Upwind"
        case .crosswind: return "Crosswind"
        case .downwind: return "Downwind"
        case .base: return "Base"
        case .final: return "Final"
        case .flare: return "Flare"
        case .leaving: return "Leaving"
        }
    }

    /// Chip text next to the callsign. Runway direction when we know which end.
    func chipText(runwayIdent: String?) -> String? {
        let name = title
        guard !name.isEmpty else { return nil }
        if self == .leaving || self == .maneuvering || self == .ground { return name }
        if let ident = runwayIdent, !ident.isEmpty {
            return "\(name) \(RunwayApproach.directionIdent(ident))"
        }
        return name
    }
}

struct PatternCircuitState: Sendable, Equatable {
    var phase: PatternPhase = .maneuvering
    var runwayIdent: String?
    /// Sequential memory only: Downwind requires a prior Crosswind this circuit.
    /// Base / Final / Flare ignore this flag.
    var sawCrosswind: Bool = false
    var lastAGLFt: Double?
    var lastSpeedKt: Double?
    var lastDistanceNM: Double?
    var lastTrackDeg: Double?
    var lastSignedCrossNM: Double?

    mutating func reset() {
        self = PatternCircuitState()
    }
}

enum PatternClassifier {
    private static let flareAGLFt = 100.0
    private static let baseMaxAGLFt = 1_000.0
    private static let downwindMinNM = 0.3
    private static let downwindMaxNM = 1.5
    /// Departure: runway heading, departure side, within this lateral distance, AGL below band.
    private static let departureLateralMaxNM = 0.5
    private static let departureMaxAGLFt = 500.0
    /// Upwind: same corridor as departure, AGL from 500 through 1,250.
    private static let upwindMaxAGLFt = 1_250.0
    /// Typical piston pattern altitude (AGL). Active-runway downwind uses ± band below.
    private static let patternAltitudeAGLFt = 1_000.0
    private static let patternAltitudeAboveFt = 300.0
    private static let patternAltitudeBelowFt = 500.0
    /// Field distance for active-runway downwind (covers extended legs).
    private static let activeDownwindMaxFieldNM = 3.5
    private static let leavingFieldNM = 2.2
    /// Climb-out turn may briefly show Maneuvering before Crosswind geometry matches.
    private static let recentTakeoffSeconds: TimeInterval = 600
    private static let alignTol = 22.0
    private static let perpTol = 28.0
    private static let runwayHeadingTol = 28.0
    /// Mid-turn hold: heading must have moved, still be short of the next leg,
    /// and not so far that the other 90° (base vs crosswind) could match.
    private static let turnMinChangeDeg = 4.0
    private static let turnArrivalDeg = 24.0
    private static let turnMaxRemainingDeg = 62.0
    private static let turnMinProgressDeg = 12.0

    /// - Parameter activeRunwayDirection: Field-wide active landing direction (`12`, not `12L`).
    ///   Crosswind / downwind / base use this. Final / flare use any runway and can change it.
    static func update(
        state: inout PatternCircuitState,
        snapshot: AircraftSnapshot,
        track: [TrackPoint],
        agl: Double?,
        airport: Airport,
        lastTakeoffAt: Date?,
        now: Date,
        activeRunwayDirection: String?
    ) {
        if Geo.isSurfaceOps(
            onGround: snapshot.onGround,
            altitudeAGLFt: agl,
            groundSpeedKt: snapshot.groundSpeedKt
        ) {
            state.reset()
            state.phase = .ground
            return
        }

        let point = snapshot.coordinate
        let distanceNM = Geo.distanceNM(point, airport.coordinate)
        let heading = inferredTrack(snapshot: snapshot, track: track)
        let speed = snapshot.groundSpeedKt
        let vs = snapshot.verticalRateFPM
        let approaches = airport.runways.flatMap(\.approaches)
        let activeApproaches = approaches.filter {
            $0.directionIdent == activeRunwayDirection
        }
        let slowing = isSlowing(current: speed, previous: state.lastSpeedKt)
        let descending = isDescending(agl: agl, previous: state.lastAGLFt, vs: vs)
        let previous = state.phase

        // Final / flare / departure geometry: any runway. Pattern legs: active only.
        let chosenAny = pickApproach(
            approaches: approaches,
            point: point,
            track: heading,
            stickyIdent: state.runwayIdent
        )
        let chosenActive = pickApproach(
            approaches: activeApproaches.isEmpty ? [] : activeApproaches,
            point: point,
            track: heading,
            stickyIdent: state.runwayIdent
        )

        let next = classify(
            previous: previous,
            sawCrosswind: state.sawCrosswind,
            lastTakeoffAt: lastTakeoffAt,
            now: now,
            point: point,
            airport: airport,
            distanceNM: distanceNM,
            heading: heading,
            previousHeading: state.lastTrackDeg,
            agl: agl,
            speed: speed,
            vs: vs,
            slowing: slowing,
            descending: descending,
            previousDistanceNM: state.lastDistanceNM,
            previousSignedCross: state.lastSignedCrossNM,
            chosenAny: chosenAny,
            chosenActive: chosenActive,
            activeRunwayDirection: activeRunwayDirection,
            approaches: approaches
        )

        state.phase = next.0
        if let ident = next.1 {
            state.runwayIdent = RunwayApproach.directionIdent(ident)
        } else if next.0 == .maneuvering,
                  !isRecentTakeoff(lastTakeoffAt: lastTakeoffAt, now: now) {
            state.runwayIdent = nil
        }
        if state.phase == .crosswind || state.phase == .downwind {
            state.sawCrosswind = true
        }
        if state.phase == .leaving {
            state.sawCrosswind = false
        }
        if (state.phase == .departure || state.phase == .upwind),
           previous == .flare || previous == .final || previous == .maneuvering || previous == .ground {
            state.sawCrosswind = false
        }

        state.lastAGLFt = agl
        state.lastSpeedKt = speed
        state.lastDistanceNM = distanceNM
        state.lastTrackDeg = heading
        let frameApproach = chosenActive ?? chosenAny
        if let frameApproach {
            state.lastSignedCrossNM = frameApproach.frame(at: point).crossRight
        }
    }

    // MARK: - Classify

    private static func classify(
        previous: PatternPhase,
        sawCrosswind: Bool,
        lastTakeoffAt: Date?,
        now: Date,
        point: CLLocationCoordinate2D,
        airport: Airport,
        distanceNM: Double,
        heading: Double?,
        previousHeading: Double?,
        agl: Double?,
        speed: Double?,
        vs: Double?,
        slowing: Bool,
        descending: Bool,
        previousDistanceNM: Double?,
        previousSignedCross: Double?,
        chosenAny: RunwayApproach?,
        chosenActive: RunwayApproach?,
        activeRunwayDirection: String?,
        approaches: [RunwayApproach]
    ) -> (PatternPhase, String?) {
        let patternChosen = chosenActive
        let anyChosen = chosenAny

        // MARK: Profile-only Final / Flare — any runway (altitude, speed, location).
        // These set / switch the field active runway when LandingDetector observes them.
        if let anyChosen, isFlare(chosen: anyChosen, point: point, heading: heading, agl: agl, speed: speed) {
            return (.flare, anyChosen.directionIdent)
        }
        if let anyChosen, isFinal(chosen: anyChosen, point: point, heading: heading, agl: agl, slowing: slowing, descending: descending, speed: speed) {
            return (.final, anyChosen.directionIdent)
        }

        // MARK: Base — locked to active runway direction.
        if let patternChosen, isBase(
            chosen: patternChosen,
            point: point,
            heading: heading,
            agl: agl,
            slowing: slowing,
            speed: speed,
            previousSignedCross: previous == .base ? previousSignedCross : nil
        ) {
            return (.base, patternChosen.directionIdent)
        }

        // MARK: Sequential — Departure → Upwind → Crosswind → Downwind.

        // Crosswind after Departure / Upwind (or while already on Crosswind).
        // After a recent takeoff, also accept Crosswind from a brief Maneuvering
        // chip during the climb-out turn (heading leaves the upwind corridor first).
        let sequentialCrosswind = previous == .departure || previous == .upwind || previous == .crosswind
        let climbOutCrosswind = previous == .maneuvering
            && isRecentTakeoff(lastTakeoffAt: lastTakeoffAt, now: now)
        if sequentialCrosswind || climbOutCrosswind,
           let crosswind = matchingCrosswind(
            candidates: crosswindCandidates(
                patternChosen: patternChosen,
                anyChosen: anyChosen,
                activeRunwayDirection: activeRunwayDirection,
                approaches: approaches
            ),
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM
           ) {
            return (.crosswind, crosswind.directionIdent)
        }

        if sawCrosswind,
           let patternChosen,
           isDownwind(chosen: patternChosen, point: point, heading: heading, agl: agl) {
            return (.downwind, patternChosen.directionIdent)
        }

        // Active-runway downwind — no prior Crosswind required. Catches extended
        // downwinds that never got a sequential Crosswind chip before Leaving.
        if let activeDW = activeRunwayDownwind(
            approaches: approaches,
            activeRunwayDirection: activeRunwayDirection,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM
        ) {
            return (.downwind, activeDW.directionIdent)
        }

        // Departure / Upwind corridor: runway heading, departure side, ≤ 0.5 NM.
        // AGL < 500 → Departure; 500…1250 → Upwind; above that or outside → Maneuvering
        // (unless Crosswind already matched above).
        if previous != .crosswind, previous != .downwind, previous != .base {
            let corridorChosen = patternChosen ?? anyChosen
            if let phase = departureOrUpwind(
                chosen: corridorChosen,
                point: point,
                heading: heading,
                agl: agl
            ) {
                return phase
            }
        }

        // Mid-turn: heading is changing toward the *published* next leg
        // (e.g. 070 → 120 → 160) but has not arrived yet. Keep the previous
        // label instead of dropping to Maneuvering / Leaving.
        let turnChosen = patternChosen ?? anyChosen
        if let held = heldPhaseDuringTurn(
            previous: previous,
            heading: heading,
            previousHeading: previousHeading,
            chosen: turnChosen,
            point: point,
            agl: agl
        ) {
            return (held, turnChosen?.directionIdent ?? activeRunwayDirection)
        }

        if isLeaving(
            previous: previous,
            point: point,
            airport: airport,
            distanceNM: distanceNM,
            heading: heading,
            previousDistanceNM: previousDistanceNM,
            chosen: anyChosen,
            activeRunwayDirection: activeRunwayDirection,
            approaches: approaches,
            agl: agl
        ) {
            return (.leaving, anyChosen?.directionIdent ?? activeRunwayDirection)
        }

        let holdChosen = patternChosen ?? anyChosen
        if holds(
            previous,
            chosen: holdChosen,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            sawCrosswind: sawCrosswind,
            speed: speed,
            requiresActive: previous == .crosswind || previous == .downwind || previous == .base,
            hasActive: patternChosen != nil
        ) {
            return (previous, holdChosen?.directionIdent ?? activeRunwayDirection)
        }

        return (.maneuvering, nil)
    }

    // MARK: - Phase tests

    private static func isFlare(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        speed: Double?
    ) -> Bool {
        guard let agl, agl <= flareAGLFt, agl >= 0 else { return false }
        guard let heading, Geo.isAbout(heading, chosen.headingDeg, tolerance: 30) else { return false }
        let frame = chosen.frame(at: point)
        guard abs(frame.crossRight) < 0.12 else { return false }
        guard frame.along > -0.40, frame.along < 0.30 else { return false }
        if let speed, speed > 120 { return false }
        return true
    }

    private static func isFinal(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        slowing: Bool,
        descending: Bool,
        speed: Double?
    ) -> Bool {
        guard let agl, agl < baseMaxAGLFt else { return false }
        guard let heading, Geo.isAbout(heading, chosen.headingDeg, tolerance: alignTol) else { return false }
        let frame = chosen.frame(at: point)
        guard abs(frame.crossRight) < 0.22 else { return false }
        guard frame.along > -2.8, frame.along < 0.20 else { return false }
        let slowEnough = slowing || (speed ?? 999) < 110
        let lowEnough = descending || agl < 600
        return slowEnough && lowEnough
    }

    private static func isBase(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        slowing: Bool,
        speed: Double?,
        previousSignedCross: Double?
    ) -> Bool {
        guard let agl, agl < baseMaxAGLFt, agl > flareAGLFt else { return false }
        guard let heading else { return false }
        let frame = chosen.frame(at: point)
        let cross = abs(frame.crossRight)
        guard cross >= 0.20, cross <= 1.70 else { return false }
        guard frame.along > -2.8, frame.along < 0.25 else { return false }
        let towardHeading = chosen.headingDeg + (frame.crossRight >= 0 ? -90 : 90)
        let onBaseHeading = Geo.isAbout(heading, towardHeading, tolerance: perpTol)
            || Geo.isPerpendicular(heading, to: chosen.headingDeg, tolerance: perpTol)
        guard onBaseHeading else { return false }
        let slowEnough = slowing || (speed ?? 999) < 95
        guard slowEnough else { return false }
        if let previousSignedCross, abs(frame.crossRight) > abs(previousSignedCross) + 0.12 {
            return false
        }
        return true
    }

    /// Runway-heading climb-out on the departure side within ½ NM.
    /// AGL < 500 → Departure; 500…1250 → Upwind; above 1250 or outside corridor → nil (Maneuvering).
    private static func departureOrUpwind(
        chosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?
    ) -> (PatternPhase, String?)? {
        guard let chosen, let heading, let agl, agl >= 0 else { return nil }
        guard Geo.isAbout(heading, chosen.headingDeg, tolerance: runwayHeadingTol) else { return nil }
        let lateral = chosen.distanceToRunwayNM(from: point)
        guard lateral <= departureLateralMaxNM else { return nil }
        let frame = chosen.frame(at: point)
        // Departure / upwind side: past the landing threshold along runway heading (not on final).
        guard frame.along > -0.1 else { return nil }
        if agl < departureMaxAGLFt {
            return (.departure, chosen.directionIdent)
        }
        if agl <= upwindMaxAGLFt {
            return (.upwind, chosen.directionIdent)
        }
        // Above 1,250 AGL in the corridor → Maneuvering.
        return nil
    }

    private static func isRecentTakeoff(lastTakeoffAt: Date?, now: Date) -> Bool {
        guard let lastTakeoffAt else { return false }
        return now.timeIntervalSince(lastTakeoffAt) <= recentTakeoffSeconds
    }

    /// Keep Departure / Upwind / Crosswind / Downwind / Base while the track is
    /// rotating toward the published next leg and has not reached that heading yet.
    private static func heldPhaseDuringTurn(
        previous: PatternPhase,
        heading: Double?,
        previousHeading: Double?,
        chosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        agl: Double?
    ) -> PatternPhase? {
        guard let heading, let previousHeading, let chosen else { return nil }
        guard Geo.headingDelta(previousHeading, heading) >= turnMinChangeDeg else { return nil }
        guard let target = nextLegHeading(from: previous, approach: chosen) else { return nil }
        let remainingBefore = Geo.headingDelta(previousHeading, target)
        let remainingNow = Geo.headingDelta(heading, target)
        let progress = remainingBefore - remainingNow
        guard progress >= turnMinProgressDeg else { return nil }
        guard remainingNow > turnArrivalDeg else { return nil }
        guard remainingNow < turnMaxRemainingDeg else { return nil }
        guard turnGeometryAllowsHold(previous, chosen: chosen, point: point) else { return nil }

        if previous == .departure || previous == .upwind, let agl {
            if agl >= departureMaxAGLFt, agl <= upwindMaxAGLFt { return .upwind }
            if agl < departureMaxAGLFt { return .departure }
        }
        return previous
    }

    /// Only the published next heading — the opposite 90° is the other end of
    /// the pattern (base vs crosswind) and must not keep the previous label.
    private static func nextLegHeading(from phase: PatternPhase, approach: RunwayApproach) -> Double? {
        let runway = approach.headingDeg
        let right = approach.runway.usesRightTraffic(forApproachIdent: approach.ident)
        switch phase {
        case .departure, .upwind:
            return Geo.normalizeHeading(runway + (right ? 90 : -90))
        case .crosswind:
            return Geo.normalizeHeading(runway + 180)
        case .downwind:
            return Geo.normalizeHeading(runway + (right ? -90 : 90))
        case .base:
            return Geo.normalizeHeading(runway)
        default:
            return nil
        }
    }

    private static func turnGeometryAllowsHold(
        _ phase: PatternPhase,
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D
    ) -> Bool {
        let along = chosen.frame(at: point).along
        switch phase {
        case .departure, .upwind, .crosswind:
            // Approach side is base / final — do not keep a departure-end label.
            return along > 0.15
        case .downwind:
            return true
        case .base:
            return along < 0.35
        default:
            return false
        }
    }

    /// Active-runway parallels first; otherwise the best-matching approach for this point.
    private static func crosswindCandidates(
        patternChosen: RunwayApproach?,
        anyChosen: RunwayApproach?,
        activeRunwayDirection: String?,
        approaches: [RunwayApproach]
    ) -> [RunwayApproach] {
        if let activeRunwayDirection {
            let active = approaches.filter { $0.directionIdent == activeRunwayDirection }
            if !active.isEmpty { return active }
        }
        if let patternChosen { return [patternChosen] }
        if let anyChosen { return [anyChosen] }
        return []
    }

    private static func matchingCrosswind(
        candidates: [RunwayApproach],
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double
    ) -> RunwayApproach? {
        var best: RunwayApproach?
        var bestScore = -1.0
        for approach in candidates {
            guard isCrosswind(
                chosen: approach,
                point: point,
                heading: heading,
                agl: agl,
                distanceNM: distanceNM
            ) else { continue }
            let score = 8.0 / (1 + approach.distanceToRunwayNM(from: point) * 2)
            if score > bestScore {
                bestScore = score
                best = approach
            }
        }
        return best
    }

    private static func isCrosswind(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double
    ) -> Bool {
        guard let heading else { return false }
        guard distanceNM < 2.4 else { return false }
        guard (agl ?? 0) < 1_800 else { return false }
        guard Geo.isPerpendicular(heading, to: chosen.headingDeg, tolerance: perpTol) else { return false }
        let frame = chosen.frame(at: point)
        // Departure side only. Approach-side perpendicular is base, not crosswind.
        return frame.along > 0.15 && abs(frame.crossRight) < 1.8
    }

    private static func isDownwind(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?
    ) -> Bool {
        guard let heading else { return false }
        guard (agl ?? 2_000) < 1_800 else { return false }
        let opposite = Geo.normalizeHeading(chosen.headingDeg + 180)
        guard Geo.isAbout(heading, opposite, tolerance: 25) else { return false }
        let lateral = chosen.distanceToRunwayNM(from: point)
        guard lateral >= downwindMinNM, lateral <= downwindMaxNM else { return false }
        let frame = chosen.frame(at: point)
        return frame.along > -0.6 && frame.along < chosen.lengthNM + 0.8
    }

    /// Downwind from active runway alone (no Crosswind memory). Extended legs OK within 3.5 NM.
    private static func activeRunwayDownwind(
        approaches: [RunwayApproach],
        activeRunwayDirection: String?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double
    ) -> RunwayApproach? {
        guard let activeRunwayDirection, let heading, let agl else { return nil }
        guard distanceNM <= activeDownwindMaxFieldNM else { return nil }
        let minAGL = patternAltitudeAGLFt - patternAltitudeBelowFt
        let maxAGL = patternAltitudeAGLFt + patternAltitudeAboveFt
        guard agl >= minAGL, agl <= maxAGL else { return nil }

        let candidates = approaches.filter { $0.directionIdent == activeRunwayDirection }
        guard !candidates.isEmpty else { return nil }

        var best: RunwayApproach?
        var bestScore = Double.greatestFiniteMagnitude
        for approach in candidates {
            let opposite = Geo.normalizeHeading(approach.headingDeg + 180)
            guard Geo.isAbout(heading, opposite, tolerance: 25) else { continue }
            let frame = approach.frame(at: point)
            let lateral = abs(frame.crossRight)
            guard lateral >= downwindMinNM, lateral <= downwindMaxNM else { continue }
            let rightTraffic = approach.runway.usesRightTraffic(forApproachIdent: approach.ident)
            let onPatternSide = rightTraffic ? frame.crossRight > 0.05 : frame.crossRight < -0.05
            guard onPatternSide else { continue }
            let ideal = TrafficPattern.downwindOffsetNM
            let score = abs(lateral - ideal)
            if score < bestScore {
                bestScore = score
                best = approach
            }
        }
        return best
    }

    /// Looser hold match for an already-labeled Downwind on the active approach.
    private static func isActiveRunwayDownwindMatch(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double
    ) -> Bool {
        activeRunwayDownwind(
            approaches: [chosen],
            activeRunwayDirection: chosen.directionIdent,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM
        ) != nil
    }

    private static func isLeaving(
        previous: PatternPhase,
        point: CLLocationCoordinate2D,
        airport: Airport,
        distanceNM: Double,
        heading: Double?,
        previousDistanceNM: Double?,
        chosen: RunwayApproach?,
        activeRunwayDirection: String?,
        approaches: [RunwayApproach],
        agl: Double?
    ) -> Bool {
        // Still on an active-runway downwind (including extended) — not leaving.
        if activeRunwayDownwind(
            approaches: approaches,
            activeRunwayDirection: activeRunwayDirection,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM
        ) != nil {
            return false
        }
        if let chosen, let heading, Geo.isAbout(heading, chosen.headingDeg, tolerance: 25) {
            let frame = chosen.frame(at: point)
            if abs(frame.crossRight) < 0.35, frame.along < 0, frame.along > -3.5 {
                return false
            }
        }
        let bearingFromField = Geo.bearing(from: airport.coordinate, to: point)
        let headingAway = heading.map { Geo.isAbout($0, bearingFromField, tolerance: 55) } ?? false
        let stretching = previousDistanceNM.map { distanceNM > $0 + 0.08 } ?? false
        if distanceNM > leavingFieldNM, headingAway { return true }
        if distanceNM > 1.8, headingAway, stretching, previous == .departure || previous == .upwind || previous == .leaving {
            return true
        }
        if previous == .downwind, let chosen {
            let lateral = chosen.distanceToRunwayNM(from: point)
            if lateral > downwindMaxNM + 0.15, headingAway { return true }
        }
        return distanceNM > 3.2
    }

    private static func holds(
        _ phase: PatternPhase,
        chosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double,
        sawCrosswind: Bool,
        speed: Double?,
        requiresActive: Bool,
        hasActive: Bool
    ) -> Bool {
        if requiresActive, !hasActive { return false }
        switch phase {
        case .ground, .maneuvering:
            return false
        case .departure, .upwind:
            // Hold only while still in the same altitude band of the departure corridor.
            // Outside ½ NM (and not Crosswind — checked earlier) falls through to Maneuvering.
            guard let match = departureOrUpwind(
                chosen: chosen,
                point: point,
                heading: heading,
                agl: agl
            ) else { return false }
            return match.0 == phase
        case .crosswind:
            guard let chosen, let heading else { return false }
            let along = chosen.frame(at: point).along
            return Geo.isPerpendicular(heading, to: chosen.headingDeg, tolerance: 35)
                && along > 0.15
                && distanceNM < 2.6
                && (agl ?? 0) < 1_900
        case .downwind:
            guard let chosen else { return false }
            if isActiveRunwayDownwindMatch(
                chosen: chosen,
                point: point,
                heading: heading,
                agl: agl,
                distanceNM: distanceNM
            ) {
                return true
            }
            guard sawCrosswind else { return false }
            let lateral = chosen.distanceToRunwayNM(from: point)
            return isDownwind(chosen: chosen, point: point, heading: heading, agl: agl)
                || (lateral >= 0.22 && lateral <= 1.7
                    && heading.map { Geo.isAbout($0, chosen.headingDeg + 180, tolerance: 30) } == true)
        case .base:
            guard let chosen else { return false }
            let frame = chosen.frame(at: point)
            return isBase(
                chosen: chosen,
                point: point,
                heading: heading,
                agl: agl,
                slowing: true,
                speed: speed,
                previousSignedCross: nil
            ) || ((agl ?? 0) < 1_100 && frame.along < 0.4 && abs(frame.crossRight) > 0.15)
        case .final:
            guard let chosen else { return false }
            let frame = chosen.frame(at: point)
            return abs(frame.crossRight) < 0.40
                && frame.along > -3.2
                && frame.along < 0.35
                && (agl ?? 0) < 1_200
        case .flare:
            guard let chosen else { return false }
            return isFlare(chosen: chosen, point: point, heading: heading, agl: agl, speed: speed)
                || ((agl ?? 0) < 160 && chosen.distanceToThresholdNM(from: point) < 0.55)
        case .leaving:
            return distanceNM > 1.7
        }
    }

    // MARK: - Runway pick

    private static func pickApproach(
        approaches: [RunwayApproach],
        point: CLLocationCoordinate2D,
        track: Double?,
        stickyIdent: String?
    ) -> RunwayApproach? {
        guard !approaches.isEmpty else { return nil }
        var best: RunwayApproach?
        var bestScore = -1.0
        for approach in approaches {
            let value = score(approach, point: point, track: track, stickyIdent: stickyIdent)
            if value > bestScore {
                bestScore = value
                best = approach
            }
        }
        if let stickyIdent, let sticky = approaches.first(where: {
            $0.ident == stickyIdent || $0.directionIdent == RunwayApproach.directionIdent(stickyIdent)
        }) {
            if bestScore < 18 { return sticky }
            let stickyScore = score(sticky, point: point, track: track, stickyIdent: stickyIdent)
            if stickyScore >= bestScore * 0.72 { return sticky }
        }
        return best
    }

    private static func score(
        _ approach: RunwayApproach,
        point: CLLocationCoordinate2D,
        track: Double?,
        stickyIdent: String?
    ) -> Double {
        var value = 8.0 / (1 + approach.distanceToRunwayNM(from: point) * 2)
        let frame = approach.frame(at: point)
        let cross = abs(frame.crossRight)
        if let track {
            if Geo.isAbout(track, approach.headingDeg, tolerance: 24) {
                value += 50 / (1 + cross * 10)
                if frame.along < 0.25, frame.along > -3 { value += 22 }
                if frame.along > -0.1 { value += 12 / (1 + cross * 4) }
            }
            if Geo.isPerpendicular(track, to: approach.headingDeg, tolerance: 30) {
                value += 18
                if frame.along < 0.4 { value += 14 }
            }
            if Geo.isAbout(track, approach.headingDeg + 180, tolerance: 25) {
                value += 8
            }
        }
        if approach.ident == stickyIdent
            || approach.directionIdent == stickyIdent.map(RunwayApproach.directionIdent) {
            value += 14
        }
        return value
    }

    // MARK: - Kinematics

    private static func inferredTrack(snapshot: AircraftSnapshot, track: [TrackPoint]) -> Double? {
        if let t = snapshot.trackDeg { return t }
        let points = Array(track.suffix(8))
        guard let last = points.last else { return nil }
        for prior in points.dropLast().reversed() {
            if Geo.distanceMeters(prior.coordinate, last.coordinate) > 40 {
                return Geo.bearing(from: prior.coordinate, to: last.coordinate)
            }
        }
        return last.trackDeg
    }

    private static func isSlowing(current: Double?, previous: Double?) -> Bool {
        guard let current, let previous else { return false }
        return current <= previous - 4
    }

    private static func isDescending(agl: Double?, previous: Double?, vs: Double?) -> Bool {
        if let vs, vs < -100 { return true }
        if let agl, let previous, agl + 20 < previous { return true }
        return false
    }
}
