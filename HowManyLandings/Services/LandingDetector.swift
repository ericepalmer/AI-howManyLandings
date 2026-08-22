import CoreLocation
import Foundation

/// Detects individual landings — including touch-and-goes in the pattern — from sparse ADS-B samples.
///
/// A landing is recorded when an aircraft:
/// 1. Arrives from altitude / outside the runway environment (descends through landing altitude)
/// 2. Gets low and slow near a runway (or hovers there, typical of helicopters)
/// 3. Either climbs away (touch-and-go) or remains on the surface (full stop)
///
/// A takeoff is recorded for a departure from the surface that is not the climb-out of a touch-and-go.
struct LandingDetector: Sendable {
    struct Configuration: Sendable {
        var landingAltitudeAGLFt: Double = 250
        var lowAltitudeAGLFt: Double = 200
        var highAltitudeAGLFt: Double = 350
        var maxLandingSpeedKt: Double = 140
        var taxiSpeedKt: Double = 28
        var minTakeoffSpeedKt: Double = 50
        var minTakeoffAGLGt: Double = 120
        var runwayProximityNM: Double = 0.75
        var airportFallbackNM: Double = 1.0
        var cooldownAfterTouchAndGo: TimeInterval = 90
        var cooldownAfterFullStop: TimeInterval = 120
        var minTouchAndGoRollSeconds: TimeInterval = 12
        var patternClimbOutAGLGt: Double = 300
        var patternMemory: TimeInterval = 10 * 60
        var hoverDuration: TimeInterval = 50
        var missingForFullStop: TimeInterval = 55
        var pendingTimeout: TimeInterval = 180
        var trackWindow: TimeInterval = 10 * 60
        /// Consecutive qualifying ADS-B samples required before logging an event.
        var eventConfirmationSamples: Int = 2
        var fullStopConfirmationSamples: Int = 3
        var minFullStopDwellSeconds: TimeInterval = 50
    }

    struct OutputEvent: Sendable {
        var kind: TrafficEventKind
        var timestamp: Date
        var icao24: String
        var tailNumber: String
        var category: AircraftCategory
        var typeLabel: String
        var altitudeAGLFt: Double?
        var groundSpeedKt: Double?
        var coordinate: CLLocationCoordinate2D
    }

    struct TrackedAircraft: Identifiable, Sendable {
        var id: String { snapshot.icao24 }
        var snapshot: AircraftSnapshot
        var track: [TrackPoint]
        var inRange: Bool
    }

    private var config: Configuration
    private var states: [String: AircraftMemory] = [:]

    init(configuration: Configuration = Configuration()) {
        self.config = configuration
    }

    mutating func ingest(
        snapshots: [AircraftSnapshot],
        airport: Airport,
        now: Date = Date()
    ) -> (aircraft: [TrackedAircraft], events: [OutputEvent]) {
        prune(now: now)

        var seen: Set<String> = []
        var events: [OutputEvent] = []

        for snapshot in snapshots where snapshot.category.isAircraft {
            seen.insert(snapshot.icao24)
            let distanceNM = Geo.distanceNM(snapshot.coordinate, airport.coordinate)
            guard distanceNM <= Geo.trackingRadiusNM else { continue }

            let sample = makeSample(snapshot, airport: airport)
            var memory = states[snapshot.icao24] ?? AircraftMemory(icao24: snapshot.icao24)
            memory.snapshot = snapshot
            memory.lastSeen = now
            memory.track.append(
                TrackPoint(
                    timestamp: snapshot.timestamp,
                    coordinate: snapshot.coordinate,
                    altitudeAGLFt: sample.agl,
                    onGround: snapshot.onGround,
                    groundSpeedKt: snapshot.groundSpeedKt,
                    trackDeg: snapshot.trackDeg,
                    verticalRateFPM: snapshot.verticalRateFPM
                )
            )
            memory.track.removeAll { now.timeIntervalSince($0.timestamp) > config.trackWindow }
            events.append(contentsOf: evaluate(sample: sample, memory: &memory, airport: airport, now: now))
            states[snapshot.icao24] = memory
        }

        for (icao, var memory) in states where !seen.contains(icao) {
            events.append(contentsOf: handleMissing(memory: &memory, now: now))
            states[icao] = memory
        }

        let aircraft: [TrackedAircraft] = states.values.compactMap { memory in
            guard let snapshot = memory.snapshot else { return nil }
            let inRange = Geo.distanceNM(snapshot.coordinate, airport.coordinate) <= Geo.trackingRadiusNM
                && now.timeIntervalSince(memory.lastSeen) < 45
            let clipped = memory.track.filter {
                Geo.distanceNM($0.coordinate, airport.coordinate) <= Geo.trackingRadiusNM
            }
            return TrackedAircraft(snapshot: snapshot, track: clipped, inRange: inRange)
        }
        .sorted { lhs, rhs in
            lhs.snapshot.displayLabel < rhs.snapshot.displayLabel
        }

        return (aircraft, events)
    }

    mutating func reset() {
        states.removeAll()
    }

    // MARK: - Evaluation

    private mutating func evaluate(
        sample: Sample,
        memory: inout AircraftMemory,
        airport: Airport,
        now: Date
    ) -> [OutputEvent] {
        var events: [OutputEvent] = []
        memory.history.append(sample)
        memory.history.removeAll { now.timeIntervalSince($0.time) > 5 * 60 }

        if sample.agl ?? 0 >= config.highAltitudeAGLFt || (!sample.nearRunway && (sample.agl ?? 0) > config.landingAltitudeAGLFt) {
            memory.sawHigh = true
            memory.lastHigh = sample
        }
        if sample.isDescending || (sample.agl ?? .greatestFiniteMagnitude) < config.landingAltitudeAGLFt {
            memory.sawDescent = true
        }
        if sample.onGround {
            memory.lastOnGround = sample.time
        }
        if sample.nearRunway && (sample.onGround || (sample.agl ?? 999) < 60) {
            memory.lastSurfaceNearRunway = sample.time
            memory.maxRunwayRollSpeed = max(memory.maxRunwayRollSpeed ?? 0, sample.speedKt)
        } else if !sample.nearRunway {
            memory.maxRunwayRollSpeed = nil
        }

        let nearSurface = sample.nearSurface
        let lowSlow = nearSurface && sample.nearRunway && sample.speedKt <= config.maxLandingSpeedKt

        if lowSlow {
            if memory.enteredLow == nil {
                memory.enteredLow = sample.time
                memory.minAGL = sample.agl
                memory.minSpeed = sample.speedKt
                memory.aligned = sample.aligned
            } else {
                memory.minAGL = minOptional(memory.minAGL, sample.agl)
                memory.minSpeed = min(memory.minSpeed, sample.speedKt)
                memory.aligned = memory.aligned || sample.aligned
            }
            memory.lastLow = sample
            if let previous = memory.history.dropLast().last {
                memory.lowDwell += max(0, sample.time.timeIntervalSince(previous.time))
            }
            if memory.pending != nil {
                memory.pendingMinAGL = minOptional(memory.pendingMinAGL, sample.agl)
                memory.pendingMaxSpeed = max(memory.pendingMaxSpeed ?? sample.speedKt, sample.speedKt)
                if sample.onGround || (sample.agl ?? 999) <= 35 {
                    memory.touchedSurfaceDuringPending = true
                }
            }
        }

        updateClimbOutState(memory: &memory, sample: sample)
        updateAirborneSinceLanding(memory: &memory, sample: sample)

        if let pending = memory.pending {
            if shouldCancelPending(sample: sample, memory: memory) {
                memory.clearPending()
            }
        }

        if let pending = memory.pending {
            if shouldResolveTouchAndGo(sample: sample, pending: pending, memory: memory) {
                let confirmed = memory.touchAndGoConfirmation.record(
                    sample: sample,
                    required: config.eventConfirmationSamples
                )
                if confirmed != nil {
                    events.append(makeEvent(.touchAndGo, from: pending, memory: memory))
                    memory.noteEmitted(kind: .touchAndGo, at: sample.time)
                    return events
                }
            } else {
                memory.touchAndGoConfirmation.reset()
            }

            if shouldResolveFullStop(sample: sample, pending: pending, memory: memory) {
                let confirmed = memory.fullStopConfirmation.record(
                    sample: sample,
                    required: config.fullStopConfirmationSamples
                )
                if confirmed != nil {
                    events.append(makeEvent(.fullStop, from: pending, memory: memory))
                    memory.noteEmitted(kind: .fullStop, at: sample.time)
                    return events
                }
            } else {
                memory.fullStopConfirmation.reset()
            }
        } else if lowSlow,
                  memory.canEmit(at: sample.time, config: config),
                  memory.completedClimbOutSinceLastEvent,
                  memory.airborneSinceLastLanding,
                  looksLikeLanding(memory: memory, sample: sample) {
            if let anchor = memory.landingConfirmation.record(
                sample: sample,
                required: config.eventConfirmationSamples
            ) {
                memory.pending = anchor
                memory.pendingMinAGL = anchor.agl
                memory.pendingMaxSpeed = anchor.speedKt
                memory.touchedSurfaceDuringPending = anchor.onGround || (anchor.agl ?? 999) <= 35
            }
        } else {
            memory.landingConfirmation.reset()
        }

        if looksLikeTakeoff(memory: memory, sample: sample),
           memory.canEmit(at: sample.time, config: config) {
            if let anchor = memory.takeoffConfirmation.record(
                sample: sample,
                required: config.eventConfirmationSamples
            ) {
                events.append(makeEvent(.takeoff, from: anchor, memory: memory))
                memory.noteEmitted(kind: .takeoff, at: sample.time)
            }
        } else {
            memory.takeoffConfirmation.reset()
        }

        if let entered = memory.enteredLow, !lowSlow, sample.time.timeIntervalSince(entered) > 20 {
            memory.enteredLow = nil
            memory.lowDwell = 0
        }

        return events
    }

    private func updateClimbOutState(memory: inout AircraftMemory, sample: Sample) {
        guard !memory.completedClimbOutSinceLastEvent else { return }
        let agl = sample.agl ?? 0
        if agl >= config.patternClimbOutAGLGt {
            memory.completedClimbOutSinceLastEvent = true
            return
        }
        if !sample.nearRunway && agl >= config.landingAltitudeAGLFt {
            memory.completedClimbOutSinceLastEvent = true
        }
    }

    private func updateAirborneSinceLanding(memory: inout AircraftMemory, sample: Sample) {
        let agl = sample.agl ?? 0
        if agl >= config.landingAltitudeAGLFt || !sample.nearRunway {
            memory.airborneSinceLastLanding = true
        }
    }

    private func shouldCancelPending(sample: Sample, memory: AircraftMemory) -> Bool {
        guard memory.pending != nil else { return false }
        let elapsed = sample.time.timeIntervalSince(memory.pending?.time ?? sample.time)
        let agl = sample.agl ?? 0

        if elapsed > config.pendingTimeout { return true }

        let climbingAway = agl >= config.landingAltitudeAGLFt
            && (sample.verticalRateFPM ?? 0) > 100
            && sample.speedKt >= 45
        if climbingAway && !shouldResolveTouchAndGo(sample: sample, pending: memory.pending!, memory: memory) {
            return true
        }

        if !sample.nearRunway && agl >= config.lowAltitudeAGLFt && elapsed > 30 {
            return true
        }

        return false
    }

    private func handleMissing(memory: inout AircraftMemory, now: Date) -> [OutputEvent] {
        guard let pending = memory.pending else { return [] }
        let silent = now.timeIntervalSince(memory.lastSeen)
        guard silent >= config.missingForFullStop,
              memory.canEmit(at: now, config: config),
              memory.touchedSurfaceDuringPending else { return [] }

        let hadTouchAndGoEvidence = memory.touchAndGoConfirmation.streak >= config.eventConfirmationSamples - 1
        if (memory.pendingMaxSpeed ?? 0) >= 50,
           (memory.pendingMinAGL ?? 999) <= 40,
           hadTouchAndGoEvidence {
            memory.noteEmitted(kind: .touchAndGo, at: now)
            return [makeEvent(.touchAndGo, from: pending, memory: memory)]
        }

        let hadFullStopEvidence = memory.fullStopConfirmation.streak >= config.fullStopConfirmationSamples - 1
        if hadFullStopEvidence,
           memory.lowDwell >= config.minFullStopDwellSeconds - 10 {
            memory.noteEmitted(kind: .fullStop, at: now)
            return [makeEvent(.fullStop, from: pending, memory: memory)]
        }

        memory.clearPending()
        return []
    }

    private func inPattern(_ memory: AircraftMemory, at time: Date) -> Bool {
        guard memory.lastKind == .touchAndGo, let last = memory.lastEventTime else { return false }
        return time.timeIntervalSince(last) <= config.patternMemory
    }

    private func looksLikeLanding(memory: AircraftMemory, sample: Sample) -> Bool {
        if sample.speedKt > config.maxLandingSpeedKt { return false }
        if sample.category == .rotorcraft {
            return sample.nearRunway && (sample.agl ?? 0) < 200
        }

        if inPattern(memory, at: sample.time), sample.nearRunway, sample.nearSurface {
            return memory.completedClimbOutSinceLastEvent
        }

        guard memory.sawHigh || (memory.lastHigh?.agl ?? 0) >= config.landingAltitudeAGLFt else {
            return false
        }

        let descendedThroughLandingAlt: Bool = {
            guard let high = memory.lastHigh?.agl, let low = sample.agl else {
                return sample.onGround && memory.sawDescent
            }
            return high >= config.landingAltitudeAGLFt && low <= config.lowAltitudeAGLFt
        }()

        return sample.nearRunway
            && sample.nearSurface
            && (descendedThroughLandingAlt || sample.onGround)
    }

    private func shouldResolveTouchAndGo(sample: Sample, pending: Sample, memory: AircraftMemory) -> Bool {
        let elapsed = sample.time.timeIntervalSince(pending.time)
        guard elapsed >= config.minTouchAndGoRollSeconds, elapsed <= 4 * 60 else { return false }

        let minAGL = memory.pendingMinAGL ?? pending.agl ?? 999
        guard minAGL <= 50 || memory.touchedSurfaceDuringPending else { return false }

        let currentAGL = sample.agl ?? 0
        let climbedFromTouch = currentAGL >= minAGL + 80
        let climbing = currentAGL >= config.highAltitudeAGLFt
            || climbedFromTouch
            || ((sample.verticalRateFPM ?? 0) > 180 && currentAGL > 100)

        let baseSpeed = memory.pendingMaxSpeed ?? pending.speedKt
        let accelerating = sample.speedKt >= max(50, baseSpeed + 15)

        return climbing && accelerating
    }

    private func shouldResolveFullStop(sample: Sample, pending: Sample, memory: AircraftMemory) -> Bool {
        if sample.category == .rotorcraft {
            let hovered = (sample.time.timeIntervalSince(pending.time) >= config.hoverDuration) && sample.nearRunway
            if hovered, (sample.agl ?? 0) < 80, memory.touchedSurfaceDuringPending { return true }
        }

        guard memory.touchedSurfaceDuringPending else { return false }

        let minAGL = memory.pendingMinAGL ?? pending.agl ?? 999
        guard minAGL <= 50 else { return false }

        let elapsed = sample.time.timeIntervalSince(pending.time)
        guard elapsed >= config.minFullStopDwellSeconds else { return false }

        let slowOnSurface = sample.nearRunway
            && (sample.onGround || (sample.agl ?? 0) < 25)
            && sample.speedKt <= config.taxiSpeedKt
        let stillRolling = sample.speedKt > config.taxiSpeedKt + 5 && elapsed < 100
        if stillRolling { return false }

        let sustainedSlow = memory.history.suffix(4).filter {
            $0.time >= pending.time && $0.nearRunway && $0.speedKt <= config.taxiSpeedKt + 3
        }.count >= 2

        return slowOnSurface && sustainedSlow
    }

    private func looksLikeTakeoff(memory: AircraftMemory, sample: Sample) -> Bool {
        if memory.pending != nil { return false }

        if memory.lastKind == .touchAndGo,
           sample.time.timeIntervalSince(memory.lastEventTime ?? .distantPast) < 90 {
            return false
        }
        if memory.lastKind == .takeoff { return false }

        if isTaxiing(memory: memory, sample: sample) { return false }

        guard let surfaceTime = memory.lastSurfaceNearRunway,
              sample.time.timeIntervalSince(surfaceTime) < 5 * 60 else { return false }

        let rollSpeed = memory.maxRunwayRollSpeed ?? 0
        guard rollSpeed >= config.taxiSpeedKt else { return false }

        let recentSlowOnRunway = memory.history.suffix(12).contains {
            $0.nearRunway && $0.speedKt <= config.taxiSpeedKt + 12
        }

        let agl = sample.agl ?? 0
        let verticalRate = sample.verticalRateFPM ?? 0

        let departureRoll = sample.nearRunway
            && sample.speedKt >= config.minTakeoffSpeedKt
            && (sample.onGround || agl < 80)
        let airborneClimb = sample.speedKt >= config.minTakeoffSpeedKt - 5
            && agl >= 50
            && (verticalRate > 120 || agl >= 70)
        let patternClimb = agl >= config.minTakeoffAGLGt
            && sample.speedKt >= config.minTakeoffSpeedKt
            && verticalRate > 80

        guard recentSlowOnRunway || departureRoll else { return false }
        guard departureRoll || airborneClimb || patternClimb else { return false }

        let accelerated = sample.speedKt >= max(config.minTakeoffSpeedKt, rollSpeed + 8)
            || (verticalRate > 180 && agl >= 40)

        return accelerated
    }

    private func isTaxiing(memory: AircraftMemory, sample: Sample) -> Bool {
        if sample.nearRunway && sample.speedKt >= config.minTakeoffSpeedKt {
            return false
        }
        if sample.onGround && sample.speedKt <= config.taxiSpeedKt {
            return true
        }

        let recent = memory.history.suffix(10)
        let groundSamples = recent.filter { $0.onGround || ($0.agl ?? 999) < 40 }
        guard groundSamples.count >= 4 else {
            return sample.onGround && sample.speedKt <= config.taxiSpeedKt + 8
        }

        let avgGroundSpeed = groundSamples.map(\.speedKt).reduce(0, +) / Double(groundSamples.count)
        let maxGroundAGL = groundSamples.compactMap(\.agl).max() ?? 0
        let stillOnSurface = sample.onGround
            || ((sample.agl ?? 0) < 40 && sample.speedKt <= config.taxiSpeedKt + 15)
        let slowGroundRoll = avgGroundSpeed <= config.taxiSpeedKt + 8 && maxGroundAGL < 50

        return stillOnSurface && slowGroundRoll
    }

    private func makeSample(_ snapshot: AircraftSnapshot, airport: Airport) -> Sample {
        let agl = snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt)
        let speed = snapshot.groundSpeedKt ?? (snapshot.onGround ? 0 : 80)
        let runwayDistance = nearestRunwayDistance(snapshot.coordinate, airport: airport)
        let nearRunway = runwayDistance <= (airport.runways.isEmpty ? config.airportFallbackNM : config.runwayProximityNM)
        let aligned: Bool = {
            guard let track = snapshot.trackDeg else { return false }
            return airport.runways.contains { Geo.isAligned(track: track, runwayHeading: $0.headingTrue) }
        }()
        let nearSurface = snapshot.onGround || (agl ?? 9999) <= config.lowAltitudeAGLFt
            || (agl ?? 9999) <= config.landingAltitudeAGLFt
        let descending = (snapshot.verticalRateFPM ?? 0) < -120
            || ((agl ?? 0) > 0 && (agl ?? 0) < config.landingAltitudeAGLFt && !snapshot.onGround)

        return Sample(
            time: snapshot.timestamp,
            icao24: snapshot.icao24,
            displayLabel: snapshot.displayLabel,
            category: snapshot.category,
            coordinate: snapshot.coordinate,
            agl: agl,
            speedKt: speed,
            onGround: snapshot.onGround,
            verticalRateFPM: snapshot.verticalRateFPM,
            distanceNM: Geo.distanceNM(snapshot.coordinate, airport.coordinate),
            nearRunway: nearRunway,
            nearSurface: nearSurface,
            aligned: aligned,
            isDescending: descending
        )
    }

    private func nearestRunwayDistance(_ point: CLLocationCoordinate2D, airport: Airport) -> Double {
        if airport.runways.isEmpty {
            return Geo.distanceNM(point, airport.coordinate)
        }
        return airport.runways.map { Geo.distanceNM(from: point, to: $0) }.min() ?? Geo.distanceNM(point, airport.coordinate)
    }

    private func makeEvent(_ kind: TrafficEventKind, from sample: Sample, memory: AircraftMemory) -> OutputEvent {
        OutputEvent(
            kind: kind,
            timestamp: sample.time,
            icao24: sample.icao24,
            tailNumber: memory.snapshot?.displayLabel ?? sample.displayLabel,
            category: memory.snapshot?.category ?? sample.category,
            typeLabel: memory.snapshot?.typeDisplay ?? sample.category.displayName,
            altitudeAGLFt: sample.agl,
            groundSpeedKt: sample.speedKt,
            coordinate: sample.coordinate
        )
    }

    private mutating func prune(now: Date) {
        let stale = now.addingTimeInterval(-15 * 60)
        states = states.filter { _, memory in memory.lastSeen > stale }
    }

    private func minOptional(_ a: Double?, _ b: Double?) -> Double? {
        switch (a, b) {
        case let (a?, b?): return min(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        default: return nil
        }
    }
}

private struct Sample: Sendable {
    var time: Date
    var icao24: String
    var displayLabel: String
    var category: AircraftCategory
    var coordinate: CLLocationCoordinate2D
    var agl: Double?
    var speedKt: Double
    var onGround: Bool
    var verticalRateFPM: Double?
    var distanceNM: Double
    var nearRunway: Bool
    var nearSurface: Bool
    var aligned: Bool
    var isDescending: Bool
}

private struct AircraftMemory: Sendable {
    var icao24: String
    var snapshot: AircraftSnapshot?
    var lastSeen: Date = .distantPast
    var track: [TrackPoint] = []
    var history: [Sample] = []
    var sawHigh = false
    var sawDescent = false
    var lastHigh: Sample?
    var lastLow: Sample?
    var enteredLow: Date?
    var minAGL: Double?
    var minSpeed: Double = .greatestFiniteMagnitude
    var aligned = false
    var lowDwell: TimeInterval = 0
    var pending: Sample?
    var pendingMinAGL: Double?
    var pendingMaxSpeed: Double?
    var touchedSurfaceDuringPending = false
    var completedClimbOutSinceLastEvent = true
    var airborneSinceLastLanding = true
    var lastEventTime: Date?
    var lastKind: TrafficEventKind?
    var lastOnGround: Date?
    var lastSurfaceNearRunway: Date?
    var maxRunwayRollSpeed: Double?
    var landingConfirmation = ConfirmationTracker()
    var touchAndGoConfirmation = ConfirmationTracker()
    var fullStopConfirmation = ConfirmationTracker()
    var takeoffConfirmation = ConfirmationTracker()

    func canEmit(at time: Date, config: LandingDetector.Configuration) -> Bool {
        guard let lastEventTime, let lastKind else { return true }
        let elapsed = time.timeIntervalSince(lastEventTime)
        let required: TimeInterval = switch lastKind {
        case .touchAndGo, .takeoff: config.cooldownAfterTouchAndGo
        case .fullStop: config.cooldownAfterFullStop
        }
        return elapsed >= required
    }

    mutating func noteEmitted(kind: TrafficEventKind, at time: Date) {
        lastEventTime = time
        lastKind = kind
        pending = nil
        pendingMinAGL = nil
        pendingMaxSpeed = nil
        touchedSurfaceDuringPending = false
        enteredLow = nil
        lowDwell = 0
        maxRunwayRollSpeed = nil
        landingConfirmation.reset()
        touchAndGoConfirmation.reset()
        fullStopConfirmation.reset()
        takeoffConfirmation.reset()
        switch kind {
        case .touchAndGo, .takeoff:
            completedClimbOutSinceLastEvent = false
            airborneSinceLastLanding = true
        case .fullStop:
            sawHigh = false
            sawDescent = false
            completedClimbOutSinceLastEvent = true
            airborneSinceLastLanding = false
        }
    }

    mutating func clearPending() {
        pending = nil
        pendingMinAGL = nil
        pendingMaxSpeed = nil
        touchedSurfaceDuringPending = false
        landingConfirmation.reset()
        touchAndGoConfirmation.reset()
        fullStopConfirmation.reset()
    }
}

/// Waits for several consecutive qualifying samples before an event is logged.
private struct ConfirmationTracker: Sendable {
    var streak: Int = 0
    var anchor: Sample?

    /// Returns the anchor sample from the first qualifying observation once confirmed.
    mutating func record(sample: Sample, required: Int) -> Sample? {
        streak += 1
        if anchor == nil { anchor = sample }
        guard streak >= required else { return nil }
        let confirmed = anchor
        reset()
        return confirmed
    }

    mutating func reset() {
        streak = 0
        anchor = nil
    }
}
