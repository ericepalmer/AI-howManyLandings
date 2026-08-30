import Foundation
import Observation
import SwiftData

@MainActor
@Observable
final class TrackingEngine {
    var selectedICAO: String?
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
    /// Airports that have received at least one successful live snapshot this session.
    var liveAirportICAOs: Set<String> = []
    var showingAddAirport = false
    var showingSettings = false
    var sessionStartedAt: Date?
    /// Pattern-tracker card selection (Mode-S hex); drives map trail emphasis.
    var selectedTrackerICAO24: String?
    /// Map hover — highlights matching tracker card without selecting.
    var hoveredTrackerICAO24: String?
    /// Latest decoded ADS-B poll for the selected airport (before pattern filtering).
    var adsLatestPoll: ADSFeedPoll?
    /// Rolling text log of incoming ADS-B polls.
    var adsLogLines: [String] = []
    /// Accumulated ADS-B polls for the Display ADS window (cleared with Clear).
    var adsSavedPolls: [ADSFeedPoll] = []
    var adsSavedPollCount: Int { adsSavedPolls.count }
    /// Active landing runway direction per airport (`12`, not `12L`/`12R`).
    var activeRunwayByAirport: [String: String] = [:]
    /// Pattern occupancy time series per airport ICAO.
    var patternOccupancyByAirport: [String: [PatternOccupancySample]] = [:]
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

    func start(airports: [Airport]) {
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

        if selectedICAO == nil {
            selectedICAO = airports.first?.icao
        } else if let selectedICAO, !tracked.contains(selectedICAO) {
            self.selectedICAO = airports.first?.icao
        }

        let addedNewField = tracked.contains { !previouslyTracked.contains($0) }
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

    var selectedAircraft: [LandingDetector.TrackedAircraft] {
        guard let selectedICAO else { return [] }
        // Include coasting targets for one hour after last ADS-B so the full visit stays visible.
        return aircraftByAirport[selectedICAO] ?? []
    }

    func selectedAirport(from airports: [Airport]) -> Airport? {
        airports.first { $0.icao == selectedICAO } ?? airports.first
    }

    /// Active runway direction for the selected airport, if known.
    var selectedActiveRunway: String? {
        guard let selectedICAO else { return nil }
        return activeRunwayByAirport[selectedICAO]
    }

    func hasLiveFeed(for icao: String) -> Bool {
        liveAirportICAOs.contains(icao)
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
            statusText = "Add an airport to start tracking."
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
            if let selected = selectedAirport(from: airports) {
                airportsToPoll = [selected]
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
            if !liveAirportICAOs.contains(airport.icao), airport.icao == selectedICAO {
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
                if airport.icao == selectedICAO {
                    recordADSFeed(
                        snapshots: snapshots,
                        airport: airport,
                        sourceName: fetched.sourceName,
                        receivedAt: fetched.result.serverTime
                    )
                }
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
                if airport.icao == selectedICAO {
                    totalAircraft = output.aircraft.filter(\.inRange).count
                }
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
                let creditText = newestCredits.map { " · \($0) credits left" } ?? ""
                statusText = "\(usedName) · \(totalAircraft) aircraft\(creditText)"
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
            selectedICAO = suggested
        }
        resetReplayDetectors()
        clearADSFeed()
        // Avoid the live-connection overlay while scrubbing a recording.
        if let selectedICAO {
            liveAirportICAOs.insert(selectedICAO)
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
        if let selectedICAO {
            liveAirportICAOs.insert(selectedICAO)
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

        guard let airport = selectedAirport(from: knownAirports) else {
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
        lastAircraftCount = lastAircraft.filter(\.inRange).count
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
        }
        selectedTrackerICAO24 = nil
        hoveredTrackerICAO24 = nil
    }

    func patternOccupancyHistory(for airportICAO: String) -> [PatternOccupancySample] {
        patternOccupancyByAirport[airportICAO] ?? []
    }

    func clearPatternOccupancy(for airportICAO: String? = nil) {
        if let airportICAO {
            patternOccupancyByAirport[airportICAO] = []
        } else {
            patternOccupancyByAirport = [:]
        }
    }

    private func recordPatternOccupancy(
        airportICAO: String,
        aircraft: [LandingDetector.TrackedAircraft],
        at time: Date
    ) {
        let sample = PatternOccupancy.sample(aircraft: aircraft, at: time)
        var series = patternOccupancyByAirport[airportICAO] ?? []
        if let last = series.last, abs(last.time.timeIntervalSince(time)) < 0.5 {
            series[series.count - 1] = sample
        } else {
            series.append(sample)
        }
        let cutoff = time.addingTimeInterval(-PatternOccupancy.maxHistory)
        series.removeAll { $0.time < cutoff }
        if series.count > PatternOccupancy.maxSamples {
            series = Array(series.suffix(PatternOccupancy.maxSamples))
        }
        patternOccupancyByAirport[airportICAO] = series
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

    func clearADSFeed() {
        adsLatestPoll = nil
        adsLogLines = []
        adsSavedPolls = []
    }

    func saveADSTrack(to url: URL, aircraftFilter: String = "") throws {
        guard !adsSavedPolls.isEmpty else { throw ADSSavedTrackError.empty }
        let data = try ADSSavedTrackExporter.export(polls: adsSavedPolls, aircraftFilter: aircraftFilter)
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
        adsLatestPoll = poll
        adsSavedPolls.append(poll)
        let stamp = receivedAt.formatted(date: .omitted, time: .standard)
        adsLogLines.append("[\(stamp)] \(sourceName) \(airport.icao)  \(rows.count) aircraft")
        adsLogLines.append(contentsOf: rows.map { "  \($0.logLine)" })
    }
}

enum AppSettings {
    static let clientIDKey = "opensky.clientID"
    static let clientSecretKey = "opensky.clientSecret"
    static let pollIntervalKey = "opensky.pollInterval"
    static let feedSourceKey = "traffic.feedSource"
    static let mapStyleKey = "map.basemapStyle"
    static let mapOpacityKey = "map.basemapOpacity"
    static let showAirfieldIDKey = "map.showAirfieldID"
    static let trackingRadiusKey = "map.trackingRadiusNM"
    static let debugTrackDumpKey = "debug.trackDump"
    static let replaySpeedKey = "debug.replaySpeed"
    /// Fraction of the ADS-B feed split given to the incoming log (bottom pane).
    static let adsFeedLogFractionKey = "ads.feedLogFraction"

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

