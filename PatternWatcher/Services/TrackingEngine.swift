import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TrackingEngine {
    var aircraftByAirport: [String: [LandingDetector.TrackedAircraft]] = [:]
    var statusText = "Waiting to track…"
    var lastError: String?
    var creditsRemaining: Int?
    /// OpenSky credits consumed during this app session (estimated from remaining drops).
    var creditsUsedThisSession: Int = 0
    var lastUpdated: Date?
    var isPolling = false
    var isPollInProgress = false
    var feedName = "ADS-B"
    var lastAircraftCount = 0
    /// Aircraft in range per airport (latest poll).
    var lastAircraftCountByAirport: [String: Int] = [:]
    /// Airports that have received at least one successful live snapshot this session.
    var liveAirportICAOs: Set<String> = []
    var sessionStartedAt: Date?
    /// Pattern-tracker card selection per airport (Mode-S hex); drives map trail emphasis.
    var selectedTrackerByAirport: [String: String] = [:]
    /// Map hover per airport — highlights matching tracker card without selecting.
    var hoveredTrackerByAirport: [String: String] = [:]
    /// Latest decoded ADS-B poll per airport (before pattern filtering).
    var adsLatestPollByAirport: [String: ADSFeedPoll] = [:]
    /// Rolling text log of incoming ADS-B polls per airport.
    var adsLogLinesByAirport: [String: [String]] = [:]
    /// Accumulated ADS-B polls per airport for the Display ADS window (cleared with Clear).
    var adsSavedPollsByAirport: [String: [ADSFeedPoll]] = [:]
    /// Active landing runway direction per airport (`12`, not `12L`/`12R`).
    var activeRunwayByAirport: [String: String] = [:]
    /// Pattern occupancy time series per airport ICAO.
    var patternOccupancyByAirport: [String: [PatternOccupancySample]] = [:]
    /// Intervals without ADS-B polls per airport ICAO.
    var patternFeedGapsByAirport: [String: [PatternFeedGap]] = [:]
    /// Landing markers for the pattern graph per airport ICAO.
    var patternLandingMarkersByAirport: [String: [PatternLandingMarker]] = [:]
    /// Takeoff markers for the pattern graph per airport ICAO.
    var patternTakeoffMarkersByAirport: [String: [PatternTakeoffMarker]] = [:]
    /// Per-poll pattern panel aircraft (tail and leg) per airport ICAO.
    var patternPresenceLogByAirport: [String: [PatternPollPresenceRecord]] = [:]
    /// Hourly average occupancy and landing totals per airport ICAO.
    var patternHourlyStatsByAirport: [String: [PatternHourlyBucket]] = [:]
    /// Airport ICAO targeted by the loaded ADS-B recording replay.
    var recordingAirportICAO: String?
    /// Loaded recording file name, when replaying saved ADS-B data.
    var recordedReplayFileName: String?
    /// Current poll index during file replay (0…count).
    var recordedPollIndex: Int = 0
    /// Total polls in the loaded recording.
    var recordedPollCount: Int = 0
    /// Human-readable recording format after load.
    var recordedFormatDescription: String?
    var isRecordedReplayActive: Bool { recording != nil && AppSettings.feedSource == .recorded }
    var recordedReplayFinished: Bool = false
    /// When false, recorded replay waits for Play or a step.
    var isRecordedReplayPlaying: Bool = false
    /// Wall clock live; latest applied recording poll time during replay (for logs / hour stats).
    var simulationNow: Date {
        if AppSettings.feedSource == .recorded, let recording, !recording.polls.isEmpty {
            if recordedPollIndex > 0 {
                return recording.polls[min(recordedPollIndex, recording.polls.count) - 1].time
            }
            return recording.polls[0].time
        }
        return Date()
    }
    /// First poll timestamp of the loaded recording, if any.
    var recordedReplayOrigin: Date? {
        recording?.polls.first?.time
    }

    @ObservationIgnored
    private var detectors: [String: LandingDetector] = [:]
    @ObservationIgnored
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored
    private var modelContext: ModelContext?
    @ObservationIgnored
    private var knownAirports: [Airport] = []
    @ObservationIgnored
    private var recording: ADSRecordingManifest?
    @ObservationIgnored
    private var recordingAccessURL: URL?
    /// Forces the next recorded `pollOnce` to advance one poll even while paused.
    @ObservationIgnored
    private var recordedStepForwardPending = false

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    /// Sync polling to the airports with open windows.
    func updateTrackedAirports(_ airports: [Airport]) {
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }
        let previouslyTracked = Set(knownAirports.map(\.icao))
        knownAirports = airports
        for airport in airports where detectors[airport.icao] == nil {
            detectors[airport.icao] = LandingDetector()
        }
        let tracked = Set(airports.map(\.icao))
        detectors = detectors.filter { tracked.contains($0.key) }
        aircraftByAirport = aircraftByAirport.filter { tracked.contains($0.key) }
        liveAirportICAOs = liveAirportICAOs.intersection(tracked)
        activeRunwayByAirport = activeRunwayByAirport.filter { tracked.contains($0.key) }
        patternOccupancyByAirport = patternOccupancyByAirport.filter { tracked.contains($0.key) }
        patternFeedGapsByAirport = patternFeedGapsByAirport.filter { tracked.contains($0.key) }
        patternLandingMarkersByAirport = patternLandingMarkersByAirport.filter { tracked.contains($0.key) }
        patternTakeoffMarkersByAirport = patternTakeoffMarkersByAirport.filter { tracked.contains($0.key) }
        patternPresenceLogByAirport = patternPresenceLogByAirport.filter { tracked.contains($0.key) }
        patternHourlyStatsByAirport = patternHourlyStatsByAirport.filter { tracked.contains($0.key) }
        lastAircraftCountByAirport = lastAircraftCountByAirport.filter { tracked.contains($0.key) }
        selectedTrackerByAirport = selectedTrackerByAirport.filter { tracked.contains($0.key) }
        hoveredTrackerByAirport = hoveredTrackerByAirport.filter { tracked.contains($0.key) }
        adsLatestPollByAirport = adsLatestPollByAirport.filter { tracked.contains($0.key) }
        adsLogLinesByAirport = adsLogLinesByAirport.filter { tracked.contains($0.key) }
        adsSavedPollsByAirport = adsSavedPollsByAirport.filter { tracked.contains($0.key) }

        let addedNewField = tracked.contains { !previouslyTracked.contains($0) }
        let newAirports = airports.filter { !previouslyTracked.contains($0.icao) }
        for airport in newAirports {
            Task { await guessInitialRunwayFromMETAR(airport) }
        }
        if airports.isEmpty {
            stop()
            statusText = "Open an airport window to start tracking."
            return
        }
        if pollTask == nil {
            isPolling = true
            pollTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.pollOnce()
                    let delay = self.nextDelay()
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        } else if addedNewField {
            Task { await pollOnce() }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    func aircraft(for airportICAO: String) -> [LandingDetector.TrackedAircraft] {
        aircraftByAirport[airportICAO] ?? []
    }

    func activeRunway(for airportICAO: String) -> String? {
        activeRunwayByAirport[airportICAO]
    }

    func selectedTrackerICAO24(for airportICAO: String) -> String? {
        selectedTrackerByAirport[airportICAO]
    }

    func setSelectedTrackerICAO24(_ icao24: String?, airportICAO: String) {
        if let icao24 {
            selectedTrackerByAirport[airportICAO] = icao24
        } else {
            selectedTrackerByAirport.removeValue(forKey: airportICAO)
        }
    }

    func setUserPatternPhase(
        _ phase: PatternPhase?,
        icao24: String,
        airportICAO: String
    ) {
        setUserTrackerAssignment(phase.map { .patternPhase($0) }, icao24: icao24, airportICAO: airportICAO)
    }

    func setUserTrackerAssignment(
        _ assignment: TrackerUserAssignment?,
        icao24: String,
        airportICAO: String
    ) {
        guard let airport = airport(for: airportICAO),
              var detector = detectors[airportICAO] else { return }
        detector.setUserAssignment(assignment, icao24: icao24)
        detectors[airportICAO] = detector
        let now = simulationNow
        aircraftByAirport[airportICAO] = detector.rebuildTrackedAircraft(
            airport: airport,
            trackingRadiusNM: AppSettings.trackingRadiusNM,
            now: now
        )
    }

    func hoveredTrackerICAO24(for airportICAO: String) -> String? {
        hoveredTrackerByAirport[airportICAO]
    }

    func setHoveredTrackerICAO24(_ icao24: String?, airportICAO: String) {
        if let icao24 {
            hoveredTrackerByAirport[airportICAO] = icao24
        } else {
            hoveredTrackerByAirport.removeValue(forKey: airportICAO)
        }
    }

    func adsLatestPoll(for airportICAO: String) -> ADSFeedPoll? {
        adsLatestPollByAirport[airportICAO]
    }

    func adsSavedPolls(for airportICAO: String) -> [ADSFeedPoll] {
        adsSavedPollsByAirport[airportICAO] ?? []
    }

    func adsLogLines(for airportICAO: String) -> [String] {
        adsLogLinesByAirport[airportICAO] ?? []
    }

    func hasLiveFeed(for icao: String) -> Bool {
        liveAirportICAOs.contains(icao)
    }

    private func airport(for icao: String) -> Airport? {
        knownAirports.first { $0.icao == icao }
    }

    private func recordingAirport() -> Airport? {
        if let recordingAirportICAO {
            return airport(for: recordingAirportICAO)
        }
        return knownAirports.first
    }

    private func nextDelay() -> TimeInterval {
        if AppSettings.feedSource == .recorded, let recording, !recording.polls.isEmpty {
            if recordedReplayFinished || !isRecordedReplayPlaying {
                return 0.25
            }
            let nextIndex = recordedPollIndex
            guard nextIndex < recording.polls.count else {
                return 0.25
            }
            if nextIndex == 0 {
                return 0.05
            }
            let prev = recording.polls[nextIndex - 1].time
            let next = recording.polls[nextIndex].time
            let delta = max(0.05, next.timeIntervalSince(prev))
            return delta / AppSettings.replaySpeedMultiplier
        }
        if case .rateLimited(let retry) = lastRateLimit {
            return min(max(retry, 15), 600)
        }
        return AppSettings.pollIntervalSeconds
    }

    func refreshNow() {
        Task { await pollOnce() }
    }

    private var lastRateLimit: OpenSkyError?

    private func pollOnce() async {
        let airports = knownAirports
        guard !airports.isEmpty else {
            statusText = "Open an airport window to start tracking."
            return
        }

        isPollInProgress = true
        defer { isPollInProgress = false }

        var newestCredits: Int?
        var errors: [String] = []
        var anySuccess = false
        var usedName = AppSettings.feedSource.title
        var totalAircraft = 0

        let airportsToPoll: [Airport]
        var recordedPoll: ADSRecordedPoll?
        if AppSettings.feedSource == .recorded {
            if recordedReplayFinished {
                isRecordedReplayPlaying = false
                lastUpdated = Date()
                statusText = "Recording finished · \(recordedPollIndex)/\(recordedPollCount) polls"
                return
            }
            let shouldAdvance = isRecordedReplayPlaying || recordedStepForwardPending
            recordedStepForwardPending = false
            if !shouldAdvance {
                lastUpdated = Date()
                let progress = "\(recordedPollIndex)/\(recordedPollCount)"
                statusText = "Paused · \(recordedReplayFileName ?? "recording") · \(progress)"
                return
            }
            if let replayAirport = recordingAirport() {
                airportsToPoll = [replayAirport]
            } else {
                airportsToPoll = []
            }
            do {
                recordedPoll = try takeNextRecordedPoll()
                if recordedPollIndex >= recordedPollCount {
                    recordedReplayFinished = true
                    isRecordedReplayPlaying = false
                }
                usedName = recordedReplayFileName.map { "Recorded · \($0)" } ?? "Recorded ADS-B"
            } catch let error as ADSRecordingError {
                errors.append(error.localizedDescription)
            } catch {
                errors.append(error.localizedDescription)
            }
        } else {
            airportsToPoll = airports
        }

        for airport in airportsToPoll {
            if Task.isCancelled { return }
            if !liveAirportICAOs.contains(airport.icao) {
                statusText = AppSettings.feedSource == .recorded
                    ? "Replaying recorded ADS-B…"
                    : "Connecting to \(AppSettings.feedSource.title)…"
            }
            do {
                let fetched = try await fetch(for: airport, recordedPoll: recordedPoll)
                newestCredits = fetched.result.creditsRemaining ?? newestCredits
                lastRateLimit = nil
                anySuccess = true
                usedName = fetched.sourceName
                liveAirportICAOs.insert(airport.icao)
                let preferredICAO = Set((detectors[airport.icao]?.trackedICAO24s) ?? [])
                let snapshots = AircraftSnapshotDeduplicator.deduplicated(
                    fetched.result.snapshots,
                    preferredICAO24: preferredICAO
                )
                recordADSFeed(
                    snapshots: snapshots,
                    airport: airport,
                    sourceName: fetched.sourceName,
                    receivedAt: fetched.result.serverTime
                )
                var detector = detectors[airport.icao] ?? LandingDetector()
                let output = detector.ingest(
                    snapshots: snapshots,
                    airport: airport,
                    trackingRadiusNM: AppSettings.trackingRadiusNM,
                    now: fetched.result.serverTime
                )
                detectors[airport.icao] = detector
                aircraftByAirport[airport.icao] = output.aircraft
                if let active = detector.activeRunwayDirection {
                    activeRunwayByAirport[airport.icao] = active
                }
                recordPatternOccupancy(
                    airportICAO: airport.icao,
                    aircraft: output.aircraft,
                    at: fetched.result.serverTime
                )
                recordLandingMarkers(
                    airportICAO: airport.icao,
                    markers: output.landingMarkers,
                    at: fetched.result.serverTime
                )
                recordTakeoffMarkers(
                    airportICAO: airport.icao,
                    markers: output.takeoffMarkers,
                    at: fetched.result.serverTime
                )
                recordPatternPresenceLog(
                    airportICAO: airport.icao,
                    airportElevationFt: airport.elevationFt,
                    aircraft: output.aircraft,
                    at: fetched.result.serverTime
                )
                let inRange = output.aircraft.filter(\.inRange).count
                lastAircraftCountByAirport[airport.icao] = inRange
                totalAircraft += inRange
            } catch let error as OpenSkyError {
                errors.append(error.localizedDescription)
                if case .rateLimited = error {
                    lastRateLimit = error
                }
            } catch {
                errors.append(error.localizedDescription)
            }
        }

        lastUpdated = Date()
        if let newestCredits {
            if let previous = creditsRemaining, previous > newestCredits {
                creditsUsedThisSession += previous - newestCredits
            }
            creditsRemaining = newestCredits
        }
        feedName = usedName
        lastAircraftCount = totalAircraft
        if anySuccess {
            lastError = nil
            if AppSettings.feedSource == .recorded, isRecordedReplayActive {
                let progress = "\(recordedPollIndex)/\(recordedPollCount)"
                if recordedReplayFinished {
                    statusText = "Recording finished · \(progress) polls"
                } else {
                    statusText = "Replay · \(usedName) · \(progress) · \(totalAircraft) aircraft"
                }
            } else {
                statusText = "\(usedName) · \(totalAircraft) aircraft"
            }
        } else {
            lastError = errors.first
            if errors.first as? ADSRecordingError == .endOfRecording {
                recordedReplayFinished = true
                statusText = "Recording finished · \(recordedPollIndex)/\(recordedPollCount) polls"
                lastError = nil
            } else {
                statusText = errors.first ?? "Unable to reach the live traffic feed."
            }
        }
    }

    func loadRecordedFile(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer {
            if access { url.stopAccessingSecurityScopedResource() }
        }
        let data = try Data(contentsOf: url)
        let manifest = try ADSRecordingLoader.load(data: data, fileName: url.lastPathComponent)
        stopRecordingAccess()
        recordingAccessURL = url
        _ = url.startAccessingSecurityScopedResource()
        recording = manifest
        recordedReplayFileName = manifest.fileName
        recordedFormatDescription = manifest.format
        recordedPollCount = manifest.polls.count
        recordedPollIndex = 0
        recordedReplayFinished = false
        isRecordedReplayPlaying = false
        recordedStepForwardPending = false
        AppSettings.feedSource = .recorded
        if let suggested = manifest.suggestedAirportICAO {
            recordingAirportICAO = suggested
        } else if let first = knownAirports.first {
            recordingAirportICAO = first.icao
        }
        resetReplayDetectors()
        clearADSFeed()
        // Avoid the live-connection overlay while scrubbing a recording.
        if let recordingAirportICAO {
            liveAirportICAOs.insert(recordingAirportICAO)
        }
        feedName = "Recorded ADS-B"
        statusText = "Paused · \(manifest.fileName) · 0/\(manifest.polls.count)"
        if pollTask == nil, !knownAirports.isEmpty {
            isPolling = true
            pollTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.pollOnce()
                    let delay = self.nextDelay()
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        }
    }

    func setRecordedReplayPlaying(_ playing: Bool) {
        guard isRecordedReplayActive else { return }
        if playing, recordedReplayFinished {
            restartRecordedReplay(autoplay: true)
            return
        }
        isRecordedReplayPlaying = playing
        if playing {
            statusText = "Replay · \(recordedReplayFileName ?? "recording") · \(recordedPollIndex)/\(recordedPollCount)"
            Task { await pollOnce() }
        } else {
            statusText = "Paused · \(recordedReplayFileName ?? "recording") · \(recordedPollIndex)/\(recordedPollCount)"
        }
    }

    func toggleRecordedReplayPlaying() {
        setRecordedReplayPlaying(!isRecordedReplayPlaying)
    }

    func stepRecordedReplayForward() {
        guard isRecordedReplayActive, !recordedReplayFinished else { return }
        isRecordedReplayPlaying = false
        recordedStepForwardPending = true
        Task { await pollOnce() }
    }

    func stepRecordedReplayBackward() {
        guard isRecordedReplayActive, recordedPollIndex > 0 else { return }
        isRecordedReplayPlaying = false
        let target = recordedPollIndex - 1
        Task { await seekRecordedReplay(to: target) }
    }

    func restartRecordedReplay(autoplay: Bool = false) {
        guard recording != nil else { return }
        recordedPollIndex = 0
        recordedReplayFinished = false
        recordedStepForwardPending = false
        isRecordedReplayPlaying = autoplay
        resetReplayDetectors()
        clearADSFeed()
        if let recordingAirportICAO {
            liveAirportICAOs.insert(recordingAirportICAO)
        }
        statusText = autoplay
            ? "Replay · \(recordedReplayFileName ?? "recording") · 0/\(recordedPollCount)"
            : "Paused · \(recordedReplayFileName ?? "recording") · 0/\(recordedPollCount)"
        if autoplay {
            Task { await pollOnce() }
        }
    }

    func stopRecordedReplay(restoreLiveSource: TrafficFeedSource = .automatic) {
        stopRecordingAccess()
        recording = nil
        recordedReplayFileName = nil
        recordedFormatDescription = nil
        recordingAirportICAO = nil
        recordedPollCount = 0
        recordedPollIndex = 0
        recordedReplayFinished = false
        isRecordedReplayPlaying = false
        recordedStepForwardPending = false
        if AppSettings.feedSource == .recorded {
            AppSettings.feedSource = restoreLiveSource
        }
        resetReplayDetectors()
        statusText = "Live traffic · \(AppSettings.feedSource.title)"
        Task { await pollOnce() }
    }

    /// Rebuild detector state by replaying polls `[0, targetIndex)`.
    private func seekRecordedReplay(to targetIndex: Int) async {
        guard let recording, isRecordedReplayActive else { return }
        let clamped = max(0, min(targetIndex, recording.polls.count))
        resetReplayDetectors()
        clearADSFeed()
        recordedPollIndex = 0
        recordedReplayFinished = false
        recordedStepForwardPending = false

        guard let airport = recordingAirport() else {
            statusText = "Paused · \(recordedReplayFileName ?? "recording") · 0/\(recordedPollCount)"
            return
        }
        liveAirportICAOs.insert(airport.icao)

        var detector = LandingDetector()
        var lastAircraft: [LandingDetector.TrackedAircraft] = []
        for index in 0..<clamped {
            if Task.isCancelled { return }
            let poll = recording.polls[index]
            let snapshots = AircraftSnapshotDeduplicator.deduplicated(
                poll.snapshots,
                preferredICAO24: detector.trackedICAO24s
            )
            recordADSFeed(
                snapshots: snapshots,
                airport: airport,
                sourceName: recordedReplayFileName.map { "Recorded · \($0)" } ?? "Recorded ADS-B",
                receivedAt: poll.time
            )
            let output = detector.ingest(
                snapshots: snapshots,
                airport: airport,
                trackingRadiusNM: AppSettings.trackingRadiusNM,
                now: poll.time
            )
            lastAircraft = output.aircraft
            recordPatternOccupancy(
                airportICAO: airport.icao,
                aircraft: output.aircraft,
                at: poll.time
            )
            recordLandingMarkers(
                airportICAO: airport.icao,
                markers: output.landingMarkers,
                at: poll.time
            )
            recordTakeoffMarkers(
                airportICAO: airport.icao,
                markers: output.takeoffMarkers,
                at: poll.time
            )
            recordPatternPresenceLog(
                airportICAO: airport.icao,
                airportElevationFt: airport.elevationFt,
                aircraft: output.aircraft,
                at: poll.time
            )
        }

        detectors[airport.icao] = detector
        aircraftByAirport[airport.icao] = lastAircraft
        if let active = detector.activeRunwayDirection {
            activeRunwayByAirport[airport.icao] = active
        } else {
            activeRunwayByAirport.removeValue(forKey: airport.icao)
        }
        recordedPollIndex = clamped
        recordedReplayFinished = clamped >= recording.polls.count
        let inRange = lastAircraft.filter(\.inRange).count
        lastAircraftCountByAirport[airport.icao] = inRange
        lastAircraftCount = inRange
        lastUpdated = Date()
        lastError = nil
        statusText = "Paused · \(recordedReplayFileName ?? "recording") · \(recordedPollIndex)/\(recordedPollCount)"
    }

    private func stopRecordingAccess() {
        if let recordingAccessURL {
            recordingAccessURL.stopAccessingSecurityScopedResource()
            self.recordingAccessURL = nil
        }
    }

    private func resetReplayDetectors() {
        for icao in knownAirports.map(\.icao) {
            detectors[icao] = LandingDetector()
            aircraftByAirport[icao] = []
            activeRunwayByAirport.removeValue(forKey: icao)
            patternOccupancyByAirport[icao] = []
            patternFeedGapsByAirport[icao] = []
            patternLandingMarkersByAirport[icao] = []
            patternTakeoffMarkersByAirport[icao] = []
            patternPresenceLogByAirport[icao] = []
            patternHourlyStatsByAirport[icao] = []
        }
        selectedTrackerByAirport = [:]
        hoveredTrackerByAirport = [:]
    }

    func patternOccupancyHistory(for airportICAO: String) -> [PatternOccupancySample] {
        patternOccupancyByAirport[airportICAO] ?? []
    }

    func patternFeedGaps(for airportICAO: String) -> [PatternFeedGap] {
        patternFeedGapsByAirport[airportICAO] ?? []
    }

    func patternLandingMarkers(for airportICAO: String) -> [PatternLandingMarker] {
        patternLandingMarkersByAirport[airportICAO] ?? []
    }

    func patternTakeoffMarkers(for airportICAO: String) -> [PatternTakeoffMarker] {
        patternTakeoffMarkersByAirport[airportICAO] ?? []
    }

    func patternHourlyStats(for airportICAO: String) -> [PatternHourlyBucket] {
        patternHourlyStatsByAirport[airportICAO] ?? []
    }

    func patternStatsSnapshot(for airportICAO: String, now: Date) -> PatternStatsSnapshot {
        PatternHourlyStats.snapshot(
            occupancySamples: patternOccupancyHistory(for: airportICAO),
            landingMarkers: patternLandingMarkers(for: airportICAO),
            now: now,
            feedGapThreshold: PatternOccupancy.feedGapThreshold(
                pollInterval: AppSettings.pollIntervalSeconds
            )
        )
    }

    func patternHourlyChartSeries(for airportICAO: String, now: Date) -> [PatternHourlyBucket] {
        PatternHourlyStats.chartSeries(
            buckets: patternHourlyStats(for: airportICAO),
            now: now
        )
    }

    func clearPatternOccupancy(for airportICAO: String? = nil) {
        if let airportICAO {
            patternOccupancyByAirport[airportICAO] = []
            patternFeedGapsByAirport[airportICAO] = []
            patternLandingMarkersByAirport[airportICAO] = []
            patternTakeoffMarkersByAirport[airportICAO] = []
            patternPresenceLogByAirport[airportICAO] = []
            patternHourlyStatsByAirport[airportICAO] = []
        } else {
            patternOccupancyByAirport = [:]
            patternFeedGapsByAirport = [:]
            patternLandingMarkersByAirport = [:]
            patternTakeoffMarkersByAirport = [:]
            patternPresenceLogByAirport = [:]
            patternHourlyStatsByAirport = [:]
        }
    }

    func savePatternLog(for airportICAO: String, to url: URL) throws {
        let export = PatternLogExporter.makeExport(
            airportICAO: airportICAO,
            occupancySamples: patternOccupancyByAirport[airportICAO] ?? [],
            feedGaps: patternFeedGapsByAirport[airportICAO] ?? [],
            landings: patternLandingMarkersByAirport[airportICAO] ?? [],
            takeoffs: patternTakeoffMarkersByAirport[airportICAO] ?? [],
            presencePolls: patternPresenceLogByAirport[airportICAO] ?? [],
            hourlyStats: patternHourlyStatsByAirport[airportICAO] ?? []
        )
        try PatternLogExporter.write(export, to: url)
    }

    private func guessInitialRunwayFromMETAR(_ airport: Airport) async {
        guard !airport.runways.isEmpty else { return }
        guard var detector = detectors[airport.icao] else { return }
        guard !detector.hasLandingEstablishedRunway else { return }

        do {
            let metar = try await METARClient.shared.fetch(station: airport.icao)
            guard let direction = RunwayWindSelector.guessDirection(airport: airport, metar: metar) else {
                return
            }
            detector.applyMETARRunwayGuess(direction)
            detectors[airport.icao] = detector
            if let active = detector.activeRunwayDirection {
                activeRunwayByAirport[airport.icao] = active
            }
        } catch {
            // METAR unavailable; runway stays unset until traffic lands
        }
    }

    private func recordPatternOccupancy(
        airportICAO: String,
        aircraft: [LandingDetector.TrackedAircraft],
        at time: Date
    ) {
        let sample = PatternOccupancy.sample(aircraft: aircraft, at: time)
        var series = patternOccupancyByAirport[airportICAO] ?? []
        let gapThreshold = PatternOccupancy.feedGapThreshold(
            pollInterval: AppSettings.pollIntervalSeconds
        )
        if let last = series.last, abs(last.time.timeIntervalSince(time)) < 0.5 {
            let oldCount = last.count
            series[series.count - 1] = sample
            if oldCount != sample.count {
                patternHourlyStatsByAirport[airportICAO] = PatternHourlyStats.adjustOccupancySum(
                    buckets: patternHourlyStatsByAirport[airportICAO] ?? [],
                    delta: sample.count - oldCount,
                    at: time
                )
            }
        } else {
            if let last = series.last {
                let elapsed = time.timeIntervalSince(last.time)
                if elapsed > gapThreshold {
                    recordFeedGap(
                        airportICAO: airportICAO,
                        start: last.time,
                        end: time,
                        now: time
                    )
                }
            }
            series.append(sample)
            patternHourlyStatsByAirport[airportICAO] = PatternHourlyStats.addOccupancySample(
                buckets: patternHourlyStatsByAirport[airportICAO] ?? [],
                count: sample.count,
                at: time
            )
        }
        let cutoff = time.addingTimeInterval(-PatternOccupancy.maxHistory)
        series.removeAll { $0.time < cutoff }
        if series.count > PatternOccupancy.maxSamples {
            series = Array(series.suffix(PatternOccupancy.maxSamples))
        }
        patternOccupancyByAirport[airportICAO] = series
    }

    private func recordFeedGap(
        airportICAO: String,
        start: Date,
        end: Date,
        now: Date
    ) {
        guard end.timeIntervalSince(start) > 1 else { return }
        var gaps = patternFeedGapsByAirport[airportICAO] ?? []
        if let last = gaps.last, last.end >= start {
            gaps[gaps.count - 1].end = max(last.end, end)
        } else {
            gaps.append(PatternFeedGap(start: start, end: end))
        }
        let cutoff = now.addingTimeInterval(-PatternOccupancy.maxHistory)
        gaps.removeAll { $0.end < cutoff }
        patternFeedGapsByAirport[airportICAO] = gaps
    }

    private func recordLandingMarkers(
        airportICAO: String,
        markers: [PatternLandingMarker],
        at time: Date
    ) {
        guard !markers.isEmpty else { return }
        var series = patternLandingMarkersByAirport[airportICAO] ?? []
        series.append(contentsOf: markers)
        var hourly = patternHourlyStatsByAirport[airportICAO] ?? []
        for marker in markers {
            hourly = PatternHourlyStats.addLandings(buckets: hourly, count: 1, at: marker.time)
        }
        patternHourlyStatsByAirport[airportICAO] = hourly
        let cutoff = time.addingTimeInterval(-PatternOccupancy.maxHistory)
        series.removeAll { $0.time < cutoff }
        if series.count > PatternOccupancy.maxSamples {
            series = Array(series.suffix(PatternOccupancy.maxSamples))
        }
        patternLandingMarkersByAirport[airportICAO] = series
    }

    private func recordTakeoffMarkers(
        airportICAO: String,
        markers: [PatternTakeoffMarker],
        at time: Date
    ) {
        guard !markers.isEmpty else { return }
        var series = patternTakeoffMarkersByAirport[airportICAO] ?? []
        series.append(contentsOf: markers)
        let cutoff = time.addingTimeInterval(-PatternOccupancy.maxHistory)
        series.removeAll { $0.time < cutoff }
        if series.count > PatternOccupancy.maxSamples {
            series = Array(series.suffix(PatternOccupancy.maxSamples))
        }
        patternTakeoffMarkersByAirport[airportICAO] = series
    }

    private func recordPatternPresenceLog(
        airportICAO: String,
        airportElevationFt: Int,
        aircraft: [LandingDetector.TrackedAircraft],
        at time: Date
    ) {
        let panel = aircraft.filter {
            $0.appearsInPatternPanel(airportElevationFt: airportElevationFt)
        }
        let entries = panel.map { ac in
            PatternAircraftPresenceEntry(
                icao24: ac.id,
                label: ac.snapshot.mapLabel,
                phase: ac.displayPatternPhase.rawValue,
                chip: ac.patternChipText
            )
        }
        let occupancyCount = PatternOccupancy.sample(aircraft: aircraft, at: time).count
        let record = PatternPollPresenceRecord(
            time: time,
            occupancyCount: occupancyCount,
            aircraft: entries
        )
        var series = patternPresenceLogByAirport[airportICAO] ?? []
        if let last = series.last, abs(last.time.timeIntervalSince(time)) < 0.5 {
            series[series.count - 1] = record
        } else {
            series.append(record)
        }
        let cutoff = time.addingTimeInterval(-PatternOccupancy.maxHistory)
        series.removeAll { $0.time < cutoff }
        if series.count > PatternOccupancy.maxSamples {
            series = Array(series.suffix(PatternOccupancy.maxSamples))
        }
        patternPresenceLogByAirport[airportICAO] = series
    }

    private func takeNextRecordedPoll() throws -> ADSRecordedPoll {
        guard let recording, !recording.polls.isEmpty else {
            throw ADSRecordingError.noFileLoaded
        }
        guard recordedPollIndex < recording.polls.count else {
            throw ADSRecordingError.endOfRecording
        }
        let poll = recording.polls[recordedPollIndex]
        recordedPollIndex += 1
        return poll
    }

    private func fetch(
        for airport: Airport,
        recordedPoll: ADSRecordedPoll? = nil
    ) async throws -> (result: OpenSkyClient.FetchResult, sourceName: String) {
        let radius = AppSettings.trackingRadiusNM
        switch AppSettings.feedSource {
        case .opensky:
            let result = try await OpenSkyClient.shared.fetchStates(
                bbox: airport.boundingBox(radiusNM: radius),
                clientID: AppSettings.clientID,
                clientSecret: AppSettings.clientSecret
            )
            return (result, "OpenSky")
        case .adsbLol:
            let result = try await ADSBLolClient.shared.fetchStates(
                center: airport.coordinate,
                radiusNM: radius
            )
            return (result, "Live ADS-B")
        case .automatic:
            do {
                let result = try await ADSBLolClient.shared.fetchStates(
                    center: airport.coordinate,
                    radiusNM: radius
                )
                return (result, "Live ADS-B")
            } catch {
                let result = try await OpenSkyClient.shared.fetchStates(
                    bbox: airport.boundingBox(radiusNM: radius),
                    clientID: AppSettings.clientID,
                    clientSecret: AppSettings.clientSecret
                )
                return (result, "OpenSky")
            }
        case .recorded:
            guard let poll = recordedPoll else {
                throw ADSRecordingError.noFileLoaded
            }
            let label = recordedReplayFileName.map { "Recorded · \($0)" } ?? "Recorded ADS-B"
            return (
                OpenSkyClient.FetchResult(
                    snapshots: poll.snapshots,
                    serverTime: poll.time,
                    creditsRemaining: nil,
                    retryAfter: nil
                ),
                label
            )
        }
    }

    func clearADSFeed(for airportICAO: String? = nil) {
        if let airportICAO {
            adsLatestPollByAirport.removeValue(forKey: airportICAO)
            adsLogLinesByAirport.removeValue(forKey: airportICAO)
            adsSavedPollsByAirport.removeValue(forKey: airportICAO)
        } else {
            adsLatestPollByAirport = [:]
            adsLogLinesByAirport = [:]
            adsSavedPollsByAirport = [:]
        }
    }

    func saveADSTrack(to url: URL, airportICAO: String, aircraftFilter: String = "") throws {
        let polls = adsSavedPolls(for: airportICAO)
        guard !polls.isEmpty else { throw ADSSavedTrackError.empty }
        let data = try ADSSavedTrackExporter.export(polls: polls, aircraftFilter: aircraftFilter)
        try data.write(to: url, options: .atomic)
    }

    private func recordADSFeed(
        snapshots: [AircraftSnapshot],
        airport: Airport,
        sourceName: String,
        receivedAt: Date
    ) {
        let rows = snapshots
            .map { ADSFeedRow(snapshot: $0, airport: airport) }
            .sorted { $0.distanceNM < $1.distanceNM }
        let poll = ADSFeedPoll(
            id: UUID(),
            receivedAt: receivedAt,
            sourceName: sourceName,
            airportICAO: airport.icao,
            aircraft: rows
        )
        let icao = airport.icao
        adsLatestPollByAirport[icao] = poll
        var saved = adsSavedPollsByAirport[icao] ?? []
        saved.append(poll)
        adsSavedPollsByAirport[icao] = saved
        let stamp = receivedAt.formatted(date: .omitted, time: .standard)
        var lines = adsLogLinesByAirport[icao] ?? []
        lines.append("[\(stamp)] \(sourceName) \(icao)  \(rows.count) aircraft")
        lines.append(contentsOf: rows.map { "  \($0.logLine)" })
        adsLogLinesByAirport[icao] = lines
    }
}

enum AppSettings {
    static let clientIDKey = "opensky.clientID"
    static let clientSecretKey = "opensky.clientSecret"
    static let pollIntervalKey = "opensky.pollInterval"
    static let feedSourceKey = "traffic.feedSource"
    static let mapStyleKey = "map.basemapStyle"
    static let mapOpacityKey = "map.basemapOpacity"
    static let defaultMapOpacity = 0.5
    static let showAirfieldIDKey = "map.showAirfieldID"
    static let trackingRadiusKey = "map.trackingRadiusNM"
    static let debugTrackDumpKey = "debug.trackDump"
    static let replaySpeedKey = "debug.replaySpeed"
    /// Fraction of the ADS-B feed split given to the incoming log (bottom pane).
    static let adsFeedLogFractionKey = "ads.feedLogFraction"
    /// Airport ICAOs whose windows were open when the app last quit.
    static let openAirportICAOsKey = "windows.openAirportICAOs"
    /// 10-minute pattern mini plot in the right panel (default on).
    static let showMiniPatternPlotKey = "ui.showMiniPatternPlot"

    static var showMiniPatternPlot: Bool {
        get {
            if UserDefaults.standard.object(forKey: showMiniPatternPlotKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: showMiniPatternPlotKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: showMiniPatternPlotKey) }
    }

    static var openAirportICAOs: [String] {
        get { UserDefaults.standard.stringArray(forKey: openAirportICAOsKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: openAirportICAOsKey) }
    }

    static var feedSource: TrafficFeedSource {
        get { TrafficFeedSource(rawValue: UserDefaults.standard.string(forKey: feedSourceKey) ?? "") ?? .automatic }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: feedSourceKey) }
    }

    static var clientID: String {
        get { UserDefaults.standard.string(forKey: clientIDKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: clientIDKey) }
    }

    static var clientSecret: String {
        get { UserDefaults.standard.string(forKey: clientSecretKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: clientSecretKey) }
    }

    static var pollIntervalSeconds: TimeInterval {
        let stored = UserDefaults.standard.object(forKey: pollIntervalKey) as? Double
        return stored ?? 10
    }

    /// Traffic fetch / display radius in nautical miles (1…50).
    static var trackingRadiusNM: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: trackingRadiusKey) as? Double
            return min(50, max(1, stored ?? Geo.defaultTrackingRadiusNM))
        }
        set {
            UserDefaults.standard.set(min(50, max(1, newValue)), forKey: trackingRadiusKey)
        }
    }

    static var hasCredentials: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Replay speed for recorded ADS-B files (1 = real time between poll timestamps).
    static var replaySpeedMultiplier: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: replaySpeedKey) as? Double
            return stored ?? 1
        }
        set {
            UserDefaults.standard.set(max(0.1, newValue), forKey: replaySpeedKey)
        }
    }
}

enum MapBasemapStyle: String, CaseIterable, Identifiable {
    case none
    case satellite
    case street

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .satellite: return "Satellite"
        case .street: return "Street"
        }
    }
}

