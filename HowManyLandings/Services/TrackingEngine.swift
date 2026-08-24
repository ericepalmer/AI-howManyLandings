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
    /// Log entries whose saved tracks are highlighted on the map (often a whole tail).
    var selectedEventIDs: Set<UUID> = []
    /// Pattern-tracker card selection (Mode-S hex); drives map trail emphasis.
    var selectedTrackerICAO24: String?
    /// Latest decoded ADS-B poll for the selected airport (before pattern filtering).
    var adsLatestPoll: ADSFeedPoll?
    /// Rolling text log of incoming ADS-B polls.
    var adsLogLines: [String] = []
    /// Active landing runway direction per airport (`12`, not `12L`/`12R`).
    var activeRunwayByAirport: [String: String] = [:]
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
            if recordedReplayFinished {
                return AppSettings.pollIntervalSeconds
            }
            let nextIndex = recordedPollIndex
            guard nextIndex < recording.polls.count else {
                return AppSettings.pollIntervalSeconds
            }
            if nextIndex == 0 {
                return 0.25
            }
            let prev = recording.polls[nextIndex - 1].time
            let next = recording.polls[nextIndex].time
            let delta = max(0.1, next.timeIntervalSince(prev))
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
                lastUpdated = Date()
                statusText = "Recording finished · \(recordedPollIndex)/\(recordedPollCount) polls"
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
                if airport.icao == selectedICAO {
                    recordADSFeed(
                        snapshots: fetched.result.snapshots,
                        airport: airport,
                        sourceName: fetched.sourceName,
                        receivedAt: fetched.result.serverTime
                    )
                }
                var detector = detectors[airport.icao] ?? LandingDetector()
                let output = detector.ingest(
                    snapshots: fetched.result.snapshots,
                    airport: airport,
                    trackingRadiusNM: AppSettings.trackingRadiusNM,
                    now: fetched.result.serverTime
                )
                detectors[airport.icao] = detector
                aircraftByAirport[airport.icao] = output.aircraft
                if let active = detector.activeRunwayDirection {
                    activeRunwayByAirport[airport.icao] = active
                }
                if airport.icao == selectedICAO {
                    totalAircraft = output.aircraft.filter(\.inRange).count
                }
                persist(output.events, airport: airport)
                clearExpiredTracks(icao24s: output.purgedICAO24s, airportICAO: airport.icao)
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
        AppSettings.feedSource = .recorded
        if let suggested = manifest.suggestedAirportICAO {
            selectedICAO = suggested
        }
        resetReplayDetectors(clearEvents: true)
        clearADSFeed()
        feedName = "Recorded ADS-B"
        statusText = "Replay ready · \(manifest.fileName) · \(manifest.polls.count) polls"
        if pollTask == nil, !knownAirports.isEmpty {
            isPolling = true
            pollTask = Task { [weak self] in
                while let self, !Task.isCancelled {
                    await self.pollOnce()
                    let delay = self.nextDelay()
                    try? await Task.sleep(for: .seconds(delay))
                }
            }
        } else {
            Task { await pollOnce() }
        }
    }

    func restartRecordedReplay() {
        guard recording != nil else { return }
        recordedPollIndex = 0
        recordedReplayFinished = false
        resetReplayDetectors(clearEvents: true)
        clearADSFeed()
        Task { await pollOnce() }
    }

    func stopRecordedReplay(restoreLiveSource: TrafficFeedSource = .automatic) {
        stopRecordingAccess()
        recording = nil
        recordedReplayFileName = nil
        recordedFormatDescription = nil
        recordedPollCount = 0
        recordedPollIndex = 0
        recordedReplayFinished = false
        if AppSettings.feedSource == .recorded {
            AppSettings.feedSource = restoreLiveSource
        }
        resetReplayDetectors(clearEvents: false)
        statusText = "Live traffic · \(AppSettings.feedSource.title)"
        Task { await pollOnce() }
    }

    private func stopRecordingAccess() {
        if let recordingAccessURL {
            recordingAccessURL.stopAccessingSecurityScopedResource()
            self.recordingAccessURL = nil
        }
    }

    private func resetReplayDetectors(clearEvents: Bool) {
        for icao in knownAirports.map(\.icao) {
            detectors[icao] = LandingDetector()
            aircraftByAirport[icao] = []
            activeRunwayByAirport.removeValue(forKey: icao)
        }
        selectedTrackerICAO24 = nil
        selectedEventIDs = []
        if clearEvents {
            clearStoredEvents(for: knownAirports.map(\.icao))
        }
    }

    private func clearStoredEvents(for airportICAOs: [String]) {
        guard let modelContext, !airportICAOs.isEmpty else { return }
        let codes = airportICAOs
        let descriptor = FetchDescriptor<StoredTrafficEvent>(
            predicate: #Predicate { codes.contains($0.airportICAO) }
        )
        guard let stored = try? modelContext.fetch(descriptor) else { return }
        for event in stored {
            modelContext.delete(event)
        }
        try? modelContext.save()
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
        adsLatestPoll = ADSFeedPoll(
            id: UUID(),
            receivedAt: receivedAt,
            sourceName: sourceName,
            airportICAO: airport.icao,
            aircraft: rows
        )
        let stamp = receivedAt.formatted(date: .omitted, time: .standard)
        adsLogLines.append("[\(stamp)] \(sourceName) \(airport.icao)  \(rows.count) aircraft")
        adsLogLines.append(contentsOf: rows.map { "  \($0.logLine)" })
        let maxLines = 500
        if adsLogLines.count > maxLines {
            adsLogLines.removeFirst(adsLogLines.count - maxLines)
        }
    }

    /// When engagement memory expires, drop saved tracks so log color swatches disappear.
    private func clearExpiredTracks(icao24s: Set<String>, airportICAO: String) {
        guard let modelContext, !icao24s.isEmpty else { return }
        let descriptor = FetchDescriptor<StoredTrafficEvent>(
            predicate: #Predicate { $0.airportICAO == airportICAO }
        )
        guard let stored = try? modelContext.fetch(descriptor) else { return }
        var changed = false
        for event in stored where icao24s.contains(event.aircraftICAO24) {
            guard event.hasSavedTrack else { continue }
            // Landing replays are frozen copies; do not delete them when live memory expires.
            if event.kind.countsAsLanding { continue }
            event.trackJSON = nil
            selectedEventIDs.remove(event.eventID)
            changed = true
        }
        if changed {
            try? modelContext.save()
        }
    }

    private func persist(_ events: [LandingDetector.OutputEvent], airport: Airport) {
        guard let modelContext, !events.isEmpty else { return }
        let cooldown: TimeInterval = 90
        for event in events {
            if event.isUpdate {
                let eventID = event.eventID
                var descriptor = FetchDescriptor<StoredTrafficEvent>(
                    predicate: #Predicate { $0.eventID == eventID }
                )
                descriptor.fetchLimit = 1
                if let existing = try? modelContext.fetch(descriptor).first {
                    existing.kind = event.kind
                    existing.tailNumber = event.tailNumber
                    existing.aircraftType = event.typeLabel
                    existing.altitudeAGLFt = event.altitudeAGLFt
                    existing.groundSpeedKt = event.groundSpeedKt
                    if !event.track.isEmpty {
                        existing.trackJSON = StoredTrafficEvent.encodeTrack(event.track)
                    }
                    continue
                }
            }

            // Belt-and-suspenders: drop near-duplicate same aircraft + kind inserts.
            let airportICAO = airport.icao
            let icao24 = event.icao24
            let kindRaw = event.kind.rawValue
            let earliest = event.timestamp.addingTimeInterval(-cooldown)
            var dupCheck = FetchDescriptor<StoredTrafficEvent>(
                predicate: #Predicate {
                    $0.airportICAO == airportICAO
                        && $0.aircraftICAO24 == icao24
                        && $0.kindRaw == kindRaw
                        && $0.timestamp >= earliest
                }
            )
            dupCheck.fetchLimit = 1
            if let existing = try? modelContext.fetch(dupCheck).first,
               abs(existing.timestamp.timeIntervalSince(event.timestamp)) < cooldown {
                if existing.track.isEmpty, !event.track.isEmpty {
                    existing.trackJSON = StoredTrafficEvent.encodeTrack(event.track)
                }
                continue
            }

            let stored = StoredTrafficEvent(
                eventID: event.eventID,
                airportICAO: airport.icao,
                aircraftICAO24: event.icao24,
                tailNumber: event.tailNumber,
                aircraftType: event.typeLabel,
                kind: event.kind,
                timestamp: event.timestamp,
                altitudeAGLFt: event.altitudeAGLFt,
                groundSpeedKt: event.groundSpeedKt,
                track: event.track
            )
            modelContext.insert(stored)
        }
        try? modelContext.save()
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

