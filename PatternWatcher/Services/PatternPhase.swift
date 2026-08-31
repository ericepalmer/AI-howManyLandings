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

    /// Phases the user can assign from the pattern tracker.
    static let userAssignable: [PatternPhase] = [
        .ground, .maneuvering, .departure, .upwind, .crosswind,
        .downwind, .base, .final, .flare, .leaving
    ]

    /// Chip next to callsign. `heldLeg` adds a stretch marker; `liberalUncertain` appends `?`.
    func chipText(
        runwayIdent: String?,
        isApproach: Bool = false,
        heldLeg: PatternHeldLeg? = nil,
        liberalUncertain: Bool = false
    ) -> String? {
        let name: String
        switch self {
        case .final where isApproach: name = "Approach"
        default: name = title
        }
        guard !name.isEmpty else { return nil }
        var chip: String
        if self == .leaving || self == .maneuvering || self == .ground {
            chip = name
        } else if let ident = runwayIdent, !ident.isEmpty {
            chip = "\(name) \(RunwayApproach.displayIdent(ident))"
        } else {
            chip = name
        }
        if let heldLeg { chip += heldLeg.chipSymbol }
        if liberalUncertain { chip += "?" }
        return chip
    }
}

/// Manual tracker status from double-click picker (pattern leg or landing).
enum TrackerUserAssignment: Equatable, Hashable, Sendable {
    case landed
    case patternPhase(PatternPhase)

    var title: String {
        switch self {
        case .landed: return "Landed"
        case .patternPhase(let phase): return phase.title
        }
    }

    static let landingOptions: [TrackerUserAssignment] = [.landed]

    static var patternOptions: [TrackerUserAssignment] {
        PatternPhase.userAssignable.map { .patternPhase($0) }
    }
}

/// Marker when classification used looser leg-hold criteria (prior same leg).
enum PatternHeldLeg: String, Sendable, Equatable {
    case approach
    case extendedBase
    case wideDownwind

    var chipSymbol: String {
        switch self {
        case .approach: return "↘"
        case .extendedBase: return "↔"
        case .wideDownwind: return "⇉"
        }
    }
}

struct PatternClassifyResult: Sendable, Equatable {
    var phase: PatternPhase
    var runwayIdent: String?
    var isApproach: Bool = false
    var heldLeg: PatternHeldLeg?
    var liberalUncertain: Bool = false
    /// No leg matched — show Unknown in the Maneuvering card.
    var statusUnknown: Bool = false
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
    /// Straight-in / instrument segment beyond close final (chip shows Approach).
    var isApproach: Bool = false
    var heldLeg: PatternHeldLeg?
    var liberalUncertain: Bool = false
    var statusUnknown: Bool = false

    mutating func reset() {
        self = PatternCircuitState()
    }
}

enum PatternClassifier {
    private static let flareAGLFt = 100.0
    private static let baseMaxAGLFt = 1_000.0
    private static let downwindMinNM = 0.25
    private static let downwindMaxNM = 2.0
    /// Behind the landing threshold along the downwind leg.
    private static let downwindAlongBehindNM = 0.8
    /// Past the departure end — extended downwinds for traffic (≈1 NM beyond prior limit).
    private static let downwindAlongPastFarNM = 1.8
    /// Departure: runway heading, departure side, within this lateral distance, AGL below band.
    private static let departureLateralMaxNM = 0.65
    private static let departureMaxAGLFt = 500.0
    /// Upwind: same corridor as departure, AGL from 500 through 1,250.
    private static let upwindMaxAGLFt = 1_250.0
    /// Typical piston pattern altitude (AGL). Active-runway downwind uses ± band below.
    private static let patternAltitudeAGLFt = 1_000.0
    private static let patternAltitudeAboveFt = 300.0
    private static let patternAltitudeBelowFt = 500.0
    /// Field distance for active-runway downwind (covers extended legs).
    private static let activeDownwindMaxFieldNM = 4.0
    private static let leavingFieldNM = 2.2
    /// Min increase in field distance before Leaving (or to keep holding Leaving).
    private static let leavingStretchNM = 0.08
    private static let approachingShrinkNM = 0.05
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
    /// Extra tolerance while holding Crosswind / Downwind / Base / Final.
    private static let legHoldStretch = 1.35
    /// Bonus when within 4 NM and ≤ 1,200 ft AGL for pattern-leg matching.
    private static let liberalCriteriaBoost = 1.20
    /// Tier 3 downwind: wider lateral than generic liberal (wide / offset downwinds).
    private static let liberalDownwindStretch = 1.50
    private static let longFinalNearAlongNM = -0.6
    /// Outermost Approach segment (~ILS FAF is often 4–7 NM; we allow up to 6 NM).
    private static let longFinalFarAlongNM = -6.0
    /// ILS glideslope is typically 3° (~300 ft/NM). Band allows CAT-I style and slightly steeper.
    private static let longFinalGlideSlopeMinDeg = 2.2
    private static let longFinalGlideSlopeMaxDeg = 3.6
    /// Half-angle cone from runway centerline for lateral offset on Approach.
    private static let longFinalConeDeg = 10.0
    private static let feetPerNM = Geo.metersPerNauticalMile * Geo.feetPerMeter

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
        let distanceNM = Geo.distanceToAirfieldNM(from: point, airport: airport)
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
            approaches: approaches,
            category: snapshot.category
        )

        state.phase = next.phase
        state.isApproach = next.isApproach
        state.heldLeg = next.heldLeg
        state.liberalUncertain = next.liberalUncertain
        state.statusUnknown = next.statusUnknown
        if let ident = next.runwayIdent {
            state.runwayIdent = RunwayApproach.displayIdent(ident)
        } else if next.phase == .maneuvering,
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

    private static func legStretchModifiers(
        previous: PatternPhase,
        leg: PatternPhase,
        liberal: Bool
    ) -> (stretch: Double, legHold: Bool, liberalBoost: Bool) {
        if previous == leg { return (legHoldStretch, true, false) }
        if liberal { return (liberalCriteriaBoost, false, true) }
        return (1.0, false, false)
    }

    private static func heldLegMarker(phase: PatternPhase, isApproach: Bool) -> PatternHeldLeg? {
        switch phase {
        case .final where isApproach: return .approach
        case .base: return .extendedBase
        case .downwind: return .wideDownwind
        default: return nil
        }
    }

    private static func classifyResult(
        phase: PatternPhase,
        runway: String?,
        isApproach: Bool = false,
        legHold: Bool = false,
        liberalBoost: Bool = false,
        statusUnknown: Bool = false
    ) -> PatternClassifyResult {
        PatternClassifyResult(
            phase: phase,
            runwayIdent: runway,
            isApproach: isApproach,
            heldLeg: legHold ? heldLegMarker(phase: phase, isApproach: isApproach) : nil,
            liberalUncertain: liberalBoost,
            statusUnknown: statusUnknown
        )
    }

    /// Max GS for approach / final matching by ADS-B emitter category.
    private static func maxApproachSpeedKt(category: AircraftCategory) -> Double {
        switch category {
        case .light, .ultralight, .glider, .lighterThanAir:
            return 130
        case .heavy, .space:
            return 180
        case .small, .large, .highVortexLarge, .highPerformance, .rotorcraft,
             .unknown, .noInfo, .reserved, .uav, .emergencyVehicle, .serviceVehicle,
             .pointObstacle, .clusterObstacle, .lineObstacle, .parachutist:
            return 150
        }
    }

    private static func approachSpeedOk(speed: Double?, slowing: Bool, category: AircraftCategory) -> Bool {
        slowing || (speed ?? 999) < maxApproachSpeedKt(category: category)
    }

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
        approaches: [RunwayApproach],
        category: AircraftCategory
    ) -> PatternClassifyResult {
        let patternChosen = chosenActive
        let anyChosen = chosenAny
        let liberal = Geo.isNearFieldLiberal(distanceNM: distanceNM, altitudeAGLFt: agl)

        if let anyChosen, isFlare(chosen: anyChosen, point: point, heading: heading, agl: agl, speed: speed) {
            return classifyResult(phase: .flare, runway: anyChosen.ident)
        }

        let finalMods = legStretchModifiers(previous: previous, leg: .final, liberal: liberal)
        if let anyChosen, isLongFinal(
            chosen: anyChosen,
            point: point,
            heading: heading,
            agl: agl,
            speed: speed,
            category: category,
            slowing: slowing,
            stretch: finalMods.stretch
        ) {
            return classifyResult(
                phase: .final,
                runway: anyChosen.ident,
                isApproach: true,
                legHold: finalMods.legHold,
                liberalBoost: finalMods.liberalBoost
            )
        }
        if let anyChosen, isFinal(
            chosen: anyChosen,
            point: point,
            heading: heading,
            agl: agl,
            slowing: slowing,
            descending: descending,
            speed: speed,
            category: category,
            stretch: finalMods.stretch
        ) {
            return classifyResult(
                phase: .final,
                runway: anyChosen.ident,
                legHold: finalMods.legHold,
                liberalBoost: finalMods.liberalBoost
            )
        }

        let baseMods = legStretchModifiers(previous: previous, leg: .base, liberal: liberal)
        if let patternChosen, isBase(
            chosen: patternChosen,
            point: point,
            heading: heading,
            agl: agl,
            slowing: slowing,
            speed: speed,
            previousSignedCross: previous == .base ? previousSignedCross : nil,
            stretch: baseMods.stretch
        ) {
            return classifyResult(
                phase: .base,
                runway: patternChosen.ident,
                legHold: baseMods.legHold,
                liberalBoost: baseMods.liberalBoost
            )
        }

        let climbOut = isClimbOutContext(
            previous: previous,
            lastTakeoffAt: lastTakeoffAt,
            now: now
        )
        if climbOut,
           previous != .crosswind, previous != .downwind, previous != .base,
           let phase = matchDepartureOrUpwind(
               approaches: approaches,
               patternChosen: patternChosen,
               anyChosen: anyChosen,
               point: point,
               heading: heading,
               agl: agl,
               stretch: legHoldStretch
           ) {
            return classifyResult(phase: phase.0, runway: phase.1)
        }

        let crosswindMods: (stretch: Double, legHold: Bool, liberalBoost: Bool) = {
            if previous == .crosswind {
                return (legHoldStretch, true, false)
            }
            if liberal {
                return (liberalCriteriaBoost, false, true)
            }
            return (1.0, false, false)
        }()
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
            distanceNM: distanceNM,
            stretch: crosswindMods.stretch
           ) {
            return classifyResult(
                phase: .crosswind,
                runway: crosswind.ident,
                legHold: crosswindMods.legHold,
                liberalBoost: crosswindMods.liberalBoost
            )
        }

        let downwindMods = legStretchModifiers(previous: previous, leg: .downwind, liberal: liberal)
        if sawCrosswind,
           let patternChosen,
           isDownwind(
            chosen: patternChosen,
            point: point,
            heading: heading,
            agl: agl,
            stretch: downwindMods.stretch
           ) {
            return classifyResult(
                phase: .downwind,
                runway: patternChosen.ident,
                legHold: downwindMods.legHold,
                liberalBoost: downwindMods.liberalBoost
            )
        }

        let activeDWMods = liberal
            ? (liberalDownwindStretch, false, true)
            : (1.0, false, false)
        if let activeDW = activeRunwayDownwind(
            approaches: approaches,
            activeRunwayDirection: activeRunwayDirection,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            stretch: activeDWMods.0
        ) {
            return classifyResult(
                phase: .downwind,
                runway: activeDW.ident,
                legHold: false,
                liberalBoost: activeDWMods.2
            )
        }

        if previous != .crosswind, previous != .downwind, previous != .base {
            let stretch = departureStretch(
                previous: previous,
                lastTakeoffAt: lastTakeoffAt,
                now: now,
                liberal: liberal
            )
            if let phase = matchDepartureOrUpwind(
                approaches: approaches,
                patternChosen: patternChosen,
                anyChosen: anyChosen,
                point: point,
                heading: heading,
                agl: agl,
                stretch: stretch
            ) {
                return classifyResult(phase: phase.0, runway: phase.1)
            }
        }

        let turnChosen = patternChosen ?? anyChosen
        if let held = heldPhaseDuringTurn(
            previous: previous,
            heading: heading,
            previousHeading: previousHeading,
            chosen: turnChosen,
            point: point,
            agl: agl
        ) {
            return classifyResult(
                phase: held,
                runway: turnChosen?.ident ?? activeRunwayDirection
            )
        }

        if let agl, agl > Geo.patternHighAGLFt {
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
                return classifyResult(
                    phase: .leaving,
                    runway: anyChosen?.ident ?? activeRunwayDirection
                )
            }
            return classifyResult(phase: .maneuvering, runway: nil)
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
            return classifyResult(
                phase: .leaving,
                runway: anyChosen?.ident ?? activeRunwayDirection
            )
        }

        let holdChosen = patternChosen ?? anyChosen
        if holds(
            previous,
            chosen: holdChosen,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            previousDistanceNM: previousDistanceNM,
            sawCrosswind: sawCrosswind,
            speed: speed,
            requiresActive: previous == .crosswind || previous == .downwind || previous == .base,
            hasActive: patternChosen != nil,
            category: category,
            slowing: slowing,
            descending: descending
        ) {
            let approachHold = previous == .final
                && holdChosen.map {
                    isLongFinal(
                        chosen: $0,
                        point: point,
                        heading: heading,
                        agl: agl,
                        speed: speed,
                        category: category,
                        slowing: true,
                        stretch: legHoldStretch
                    )
                } == true
            return PatternClassifyResult(
                phase: previous,
                runwayIdent: holdChosen?.ident ?? activeRunwayDirection,
                isApproach: approachHold,
                heldLeg: heldLegMarker(phase: previous, isApproach: approachHold),
                liberalUncertain: false
            )
        }

        if let liberalMatch = liberalPatternMatch(
            approaches: approaches,
            activeRunwayDirection: activeRunwayDirection,
            patternChosen: patternChosen,
            anyChosen: anyChosen,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            speed: speed,
            slowing: slowing,
            descending: descending,
            sawCrosswind: sawCrosswind,
            category: category
        ) {
            return liberalMatch
        }

        return classifyResult(phase: .maneuvering, runway: nil, statusUnknown: true)
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
        speed: Double?,
        category: AircraftCategory,
        stretch: Double = 1.0
    ) -> Bool {
        guard let agl, agl < baseMaxAGLFt else { return false }
        guard let heading, Geo.isAbout(heading, chosen.headingDeg, tolerance: alignTol * stretch) else { return false }
        let frame = chosen.frame(at: point)
        guard abs(frame.crossRight) < 0.22 * stretch else { return false }
        guard frame.along > longFinalNearAlongNM / stretch, frame.along < 0.20 * stretch else { return false }
        guard approachSpeedOk(speed: speed, slowing: slowing, category: category) else { return false }
        let lowEnough = descending || agl < 600
        return lowEnough
    }

    private static func isLongFinal(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        speed: Double?,
        category: AircraftCategory,
        slowing: Bool,
        stretch: Double = 1.0
    ) -> Bool {
        guard let agl, let heading else { return false }
        let frame = chosen.frame(at: point)
        guard let distNM = longFinalDistanceNM(frame: frame) else { return false }
        guard distNM >= (-longFinalNearAlongNM) / stretch,
              distNM <= (-longFinalFarAlongNM) * stretch else { return false }

        guard Geo.isAbout(heading, chosen.headingDeg, tolerance: alignTol * stretch) else { return false }

        let maxCross = longFinalMaxCrossNM(distanceNM: distNM, coneDeg: longFinalConeDeg, stretch: stretch)
        guard abs(frame.crossRight) <= maxCross else { return false }

        let glideBand = longFinalGlideSlopeAGLBand(
            distanceNM: distNM,
            minDeg: longFinalGlideSlopeMinDeg,
            maxDeg: longFinalGlideSlopeMaxDeg,
            stretch: stretch
        )
        guard agl >= glideBand.min, agl <= glideBand.max else { return false }

        return approachSpeedOk(speed: speed, slowing: slowing, category: category)
    }

    /// Horizontal distance before the threshold along the runway axis (approach side only).
    private static func longFinalDistanceNM(frame: (along: Double, crossRight: Double)) -> Double? {
        guard frame.along < 0 else { return nil }
        return -frame.along
    }

    /// Expected AGL band from glide slope 2.2°–3.6° at this distance; stretch widens the band.
    private static func longFinalGlideSlopeAGLBand(
        distanceNM: Double,
        minDeg: Double,
        maxDeg: Double,
        stretch: Double
    ) -> (min: Double, max: Double) {
        let distFt = distanceNM * feetPerNM
        let minAlt = distFt * tan(minDeg * .pi / 180) / stretch
        let maxAlt = distFt * tan(maxDeg * .pi / 180) * stretch
        return (minAlt, maxAlt)
    }

    /// Max lateral offset for a 10° cone from the runway at this downwind distance.
    private static func longFinalMaxCrossNM(distanceNM: Double, coneDeg: Double, stretch: Double) -> Double {
        distanceNM * tan((coneDeg * stretch) * .pi / 180)
    }

    private static func isBase(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        slowing: Bool,
        speed: Double?,
        previousSignedCross: Double?,
        stretch: Double = 1.0
    ) -> Bool {
        guard let agl, agl < baseMaxAGLFt, agl > flareAGLFt else { return false }
        guard let heading else { return false }
        let frame = chosen.frame(at: point)
        let cross = abs(frame.crossRight)
        guard cross >= 0.20 / stretch, cross <= 1.70 * stretch else { return false }
        guard frame.along > -2.8 / stretch, frame.along < 0.25 * stretch else { return false }
        let towardHeading = chosen.headingDeg + (frame.crossRight >= 0 ? -90 : 90)
        let onBaseHeading = Geo.isAbout(heading, towardHeading, tolerance: perpTol * stretch)
            || Geo.isPerpendicular(heading, to: chosen.headingDeg, tolerance: perpTol * stretch)
        guard onBaseHeading else { return false }
        let slowEnough = slowing || (speed ?? 999) < 95
        guard slowEnough else { return false }
        if let previousSignedCross, abs(frame.crossRight) > abs(previousSignedCross) + 0.12 / stretch {
            return false
        }
        return true
    }

    /// Runway-heading climb-out on the departure side within the lateral corridor.
    /// AGL < 500 → Departure; 500…1250 → Upwind; above band or outside corridor → nil.
    private static func departureOrUpwind(
        chosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        stretch: Double = 1.0
    ) -> (PatternPhase, String?)? {
        guard let chosen, let heading, let agl, agl >= 0 else { return nil }
        guard Geo.isAbout(heading, chosen.headingDeg, tolerance: runwayHeadingTol * stretch) else { return nil }
        let frame = chosen.frame(at: point)
        let lateral = abs(frame.crossRight)
        guard lateral <= departureLateralMaxNM * stretch else { return nil }
        // Departure / upwind side: past the landing threshold along runway heading (not on final).
        guard frame.along > -0.15 / stretch else { return nil }
        let upwindMax = upwindMaxAGLFt + (stretch > 1 ? 250 : 0)
        if agl < departureMaxAGLFt {
            return (.departure, chosen.ident)
        }
        if agl <= upwindMax {
            return (.upwind, chosen.ident)
        }
        return nil
    }

    private static func isClimbOutContext(
        previous: PatternPhase,
        lastTakeoffAt: Date?,
        now: Date
    ) -> Bool {
        isRecentTakeoff(lastTakeoffAt: lastTakeoffAt, now: now)
            || previous == .ground
            || previous == .departure
            || previous == .upwind
    }

    private static func departureStretch(
        previous: PatternPhase,
        lastTakeoffAt: Date?,
        now: Date,
        liberal: Bool
    ) -> Double {
        if isClimbOutContext(previous: previous, lastTakeoffAt: lastTakeoffAt, now: now) {
            return legHoldStretch
        }
        if liberal { return liberalCriteriaBoost }
        return 1.0
    }

    /// Match climb-out on any runway aligned with the track, not only the active pattern runway.
    private static func matchDepartureOrUpwind(
        approaches: [RunwayApproach],
        patternChosen: RunwayApproach?,
        anyChosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        stretch: Double
    ) -> (PatternPhase, String?)? {
        guard let heading else { return nil }
        var candidates: [RunwayApproach] = []
        if let patternChosen { candidates.append(patternChosen) }
        if let anyChosen, !candidates.contains(where: { $0.ident == anyChosen.ident }) {
            candidates.append(anyChosen)
        }
        for approach in approaches where !candidates.contains(where: { $0.ident == approach.ident }) {
            if Geo.isAbout(heading, approach.headingDeg, tolerance: runwayHeadingTol * stretch) {
                candidates.append(approach)
            }
        }
        for approach in candidates {
            if let match = departureOrUpwind(
                chosen: approach,
                point: point,
                heading: heading,
                agl: agl,
                stretch: stretch
            ) {
                return match
            }
        }
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
        distanceNM: Double,
        stretch: Double = 1.0
    ) -> RunwayApproach? {
        var best: RunwayApproach?
        var bestScore = -1.0
        for approach in candidates {
            guard isCrosswind(
                chosen: approach,
                point: point,
                heading: heading,
                agl: agl,
                distanceNM: distanceNM,
                stretch: stretch
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
        distanceNM: Double,
        stretch: Double = 1.0
    ) -> Bool {
        guard let heading else { return false }
        guard distanceNM < 2.4 * stretch else { return false }
        guard (agl ?? 0) < 1_800 + (stretch > 1 ? 250 : 0) else { return false }
        guard Geo.isPerpendicular(heading, to: chosen.headingDeg, tolerance: perpTol * stretch) else {
            return false
        }
        let frame = chosen.frame(at: point)
        // Departure side only. Approach-side perpendicular is base, not crosswind.
        return frame.along > 0.15 / stretch && abs(frame.crossRight) < 1.8 * stretch
    }

    private static func isDownwind(
        chosen: RunwayApproach,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        stretch: Double = 1.0
    ) -> Bool {
        guard let heading else { return false }
        guard (agl ?? 2_000) < 1_800 + (stretch > 1 ? 300 : 0) else { return false }
        let opposite = Geo.normalizeHeading(chosen.headingDeg + 180)
        guard Geo.isAbout(heading, opposite, tolerance: 25 * stretch) else { return false }
        let frame = chosen.frame(at: point)
        let lateral = abs(frame.crossRight)
        guard lateral >= downwindMinNM / stretch, lateral <= downwindMaxNM * stretch else { return false }
        return isDownwindAlongRange(chosen: chosen, along: frame.along, stretch: stretch)
    }

    private static func isDownwindAlongRange(
        chosen: RunwayApproach,
        along: Double,
        stretch: Double = 1.0
    ) -> Bool {
        along > -downwindAlongBehindNM * stretch
            && along < chosen.lengthNM + downwindAlongPastFarNM * stretch
    }

    private static func isStretchingAway(distanceNM: Double, previousDistanceNM: Double?) -> Bool {
        guard let previous = previousDistanceNM else { return false }
        return distanceNM > previous + leavingStretchNM
    }

    private static func isApproachingField(distanceNM: Double, previousDistanceNM: Double?) -> Bool {
        guard let previous = previousDistanceNM else { return false }
        return distanceNM < previous - approachingShrinkNM
    }

    /// Downwind from active runway alone (no Crosswind memory). Extended legs OK within 3.5 NM.
    private static func activeRunwayDownwind(
        approaches: [RunwayApproach],
        activeRunwayDirection: String?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double,
        stretch: Double = 1.0
    ) -> RunwayApproach? {
        guard let activeRunwayDirection, let heading, let agl else { return nil }
        guard distanceNM <= activeDownwindMaxFieldNM * stretch else { return nil }
        let minAGL = patternAltitudeAGLFt - patternAltitudeBelowFt - (stretch > 1 ? 200 : 0)
        let maxAGL = patternAltitudeAGLFt + patternAltitudeAboveFt + (stretch > 1 ? 300 : 0)
        guard agl >= minAGL, agl <= maxAGL else { return nil }

        let candidates = approaches.filter { $0.directionIdent == activeRunwayDirection }
        guard !candidates.isEmpty else { return nil }

        var best: RunwayApproach?
        var bestScore = Double.greatestFiniteMagnitude
        for approach in candidates {
            let opposite = Geo.normalizeHeading(approach.headingDeg + 180)
            guard Geo.isAbout(heading, opposite, tolerance: 25 * stretch) else { continue }
            let frame = approach.frame(at: point)
            let lateral = abs(frame.crossRight)
            guard lateral >= downwindMinNM / stretch, lateral <= downwindMaxNM * stretch else { continue }
            let rightTraffic = approach.runway.usesRightTraffic(forApproachIdent: approach.ident)
            let onPatternSide = rightTraffic ? frame.crossRight > 0.05 : frame.crossRight < -0.05
            guard onPatternSide else { continue }
            guard isDownwindAlongRange(chosen: approach, along: frame.along, stretch: stretch) else { continue }
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
        distanceNM: Double,
        stretch: Double = 1.0
    ) -> Bool {
        activeRunwayDownwind(
            approaches: [chosen],
            activeRunwayDirection: chosen.directionIdent,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            stretch: stretch
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
        if isApproachingField(distanceNM: distanceNM, previousDistanceNM: previousDistanceNM) {
            return false
        }

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
        let stretching = isStretchingAway(distanceNM: distanceNM, previousDistanceNM: previousDistanceNM)

        guard stretching || previousDistanceNM == nil else { return false }

        if distanceNM > leavingFieldNM, headingAway { return true }
        if distanceNM > 1.8, headingAway, previous == .departure || previous == .upwind || previous == .leaving {
            return true
        }
        if previous == .downwind, let chosen {
            let lateral = abs(chosen.frame(at: point).crossRight)
            if lateral > downwindMaxNM * liberalDownwindStretch + 0.15, headingAway { return true }
        }
        return distanceNM > 3.2 && headingAway
    }

    private static func holds(
        _ phase: PatternPhase,
        chosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double,
        previousDistanceNM: Double?,
        sawCrosswind: Bool,
        speed: Double?,
        requiresActive: Bool,
        hasActive: Bool,
        category: AircraftCategory,
        slowing: Bool,
        descending: Bool
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
                agl: agl,
                stretch: legHoldStretch
            ) else { return false }
            return match.0 == phase
        case .crosswind:
            guard let chosen, let heading else { return false }
            let along = chosen.frame(at: point).along
            return Geo.isPerpendicular(heading, to: chosen.headingDeg, tolerance: perpTol * legHoldStretch)
                && along > 0.15 / legHoldStretch
                && distanceNM < 2.6 * legHoldStretch
                && (agl ?? 0) < 1_900 + (legHoldStretch > 1 ? 200 : 0)
        case .downwind:
            guard let chosen else { return false }
            if isActiveRunwayDownwindMatch(
                chosen: chosen,
                point: point,
                heading: heading,
                agl: agl,
                distanceNM: distanceNM,
                stretch: legHoldStretch
            ) {
                return true
            }
            guard sawCrosswind else { return false }
            let lateral = abs(chosen.frame(at: point).crossRight)
            return isDownwind(
                chosen: chosen,
                point: point,
                heading: heading,
                agl: agl,
                stretch: legHoldStretch
            )
                || (lateral >= downwindMinNM / legHoldStretch
                    && lateral <= downwindMaxNM * legHoldStretch
                    && isDownwindAlongRange(
                        chosen: chosen,
                        along: chosen.frame(at: point).along,
                        stretch: legHoldStretch
                    )
                    && heading.map {
                        Geo.isAbout($0, chosen.headingDeg + 180, tolerance: 30 * legHoldStretch)
                    } == true)
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
                previousSignedCross: nil,
                stretch: legHoldStretch
            ) || ((agl ?? 0) < 1_100 + (legHoldStretch > 1 ? 150 : 0)
                && frame.along < 0.4 * legHoldStretch
                && abs(frame.crossRight) > 0.15 / legHoldStretch)
        case .final:
            guard let chosen else { return false }
            return isFinal(
                chosen: chosen,
                point: point,
                heading: heading,
                agl: agl,
                slowing: slowing,
                descending: descending,
                speed: speed,
                category: category,
                stretch: legHoldStretch
            )
                || isLongFinal(
                    chosen: chosen,
                    point: point,
                    heading: heading,
                    agl: agl,
                    speed: speed,
                    category: category,
                    slowing: slowing,
                    stretch: legHoldStretch
                )
        case .flare:
            guard let chosen else { return false }
            return isFlare(chosen: chosen, point: point, heading: heading, agl: agl, speed: speed)
                || ((agl ?? 0) < 160 && chosen.distanceToThresholdNM(from: point) < 0.55)
        case .leaving:
            if isApproachingField(distanceNM: distanceNM, previousDistanceNM: previousDistanceNM) {
                return false
            }
            return distanceNM > 1.7
                && (previousDistanceNM == nil
                    || isStretchingAway(distanceNM: distanceNM, previousDistanceNM: previousDistanceNM)
                    || distanceNM > leavingFieldNM)
        }
    }

  /// Last-chance pattern match for low, near-field tracks before Maneuvering.
    private static func liberalPatternMatch(
        approaches: [RunwayApproach],
        activeRunwayDirection: String?,
        patternChosen: RunwayApproach?,
        anyChosen: RunwayApproach?,
        point: CLLocationCoordinate2D,
        heading: Double?,
        agl: Double?,
        distanceNM: Double,
        speed: Double?,
        slowing: Bool,
        descending: Bool,
        sawCrosswind: Bool,
        category: AircraftCategory
    ) -> PatternClassifyResult? {
        guard Geo.isNearFieldLiberal(distanceNM: distanceNM, altitudeAGLFt: agl) else { return nil }
        let stretch = liberalCriteriaBoost
        let downwindStretch = liberalDownwindStretch

        if let anyChosen, isLongFinal(
            chosen: anyChosen,
            point: point,
            heading: heading,
            agl: agl,
            speed: speed,
            category: category,
            slowing: slowing,
            stretch: stretch
        ) {
            return classifyResult(
                phase: .final,
                runway: anyChosen.ident,
                isApproach: true,
                liberalBoost: true
            )
        }
        if let anyChosen, isFinal(
            chosen: anyChosen,
            point: point,
            heading: heading,
            agl: agl,
            slowing: slowing,
            descending: descending,
            speed: speed,
            category: category,
            stretch: stretch
        ) {
            return classifyResult(phase: .final, runway: anyChosen.ident, liberalBoost: true)
        }
        if let patternChosen, isBase(
            chosen: patternChosen,
            point: point,
            heading: heading,
            agl: agl,
            slowing: slowing,
            speed: speed,
            previousSignedCross: nil,
            stretch: stretch
        ) {
            return classifyResult(phase: .base, runway: patternChosen.ident, liberalBoost: true)
        }
        if let crosswind = matchingCrosswind(
            candidates: crosswindCandidates(
                patternChosen: patternChosen,
                anyChosen: anyChosen,
                activeRunwayDirection: activeRunwayDirection,
                approaches: approaches
            ),
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            stretch: stretch
        ) {
            return classifyResult(phase: .crosswind, runway: crosswind.ident, liberalBoost: true)
        }
        if sawCrosswind,
           let patternChosen,
           isDownwind(
            chosen: patternChosen,
            point: point,
            heading: heading,
            agl: agl,
            stretch: downwindStretch
           ) {
            return classifyResult(phase: .downwind, runway: patternChosen.ident, liberalBoost: true)
        }
        if let activeDW = activeRunwayDownwind(
            approaches: approaches,
            activeRunwayDirection: activeRunwayDirection,
            point: point,
            heading: heading,
            agl: agl,
            distanceNM: distanceNM,
            stretch: downwindStretch
        ) {
            return classifyResult(phase: .downwind, runway: activeDW.ident, liberalBoost: true)
        }
        return nil
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
