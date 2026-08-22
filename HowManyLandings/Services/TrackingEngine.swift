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
    var lastUpdated: Date?
    var isPolling = false
    var feedName = "ADS-B"
    var lastAircraftCount = 0
    var showingAddAirport = false
    var showingSettings = false
    var sessionStartedAt: Date?

    @ObservationIgnored
    private var detectors: [String: LandingDetector] = [:]
    @ObservationIgnored
    private var pollTask: Task<Void, Never>?
    @ObservationIgnored
    private var modelContext: ModelContext?
    @ObservationIgnored
    private var knownAirports: [Airport] = []

    func attach(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func start(airports: [Airport]) {
        if sessionStartedAt == nil {
            sessionStartedAt = Date()
        }
        knownAirports = airports
        for airport in airports where detectors[airport.icao] == nil {
            detectors[airport.icao] = LandingDetector()
        }
        let tracked = Set(airports.map(\.icao))
        detectors = detectors.filter { tracked.contains($0.key) }
        aircraftByAirport = aircraftByAirport.filter { tracked.contains($0.key) }

        if selectedICAO == nil {
            selectedICAO = airports.first?.icao
        } else if let selectedICAO, !tracked.contains(selectedICAO) {
            self.selectedICAO = airports.first?.icao
        }

        guard pollTask == nil else { return }
        isPolling = true
        pollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.pollOnce()
                let delay = self.nextDelay()
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        isPolling = false
    }

    var selectedAircraft: [LandingDetector.TrackedAircraft] {
        guard let selectedICAO else { return [] }
        return (aircraftByAirport[selectedICAO] ?? []).filter(\.inRange)
    }

    func selectedAirport(from airports: [Airport]) -> Airport? {
        airports.first { $0.icao == selectedICAO } ?? airports.first
    }

    private func nextDelay() -> TimeInterval {
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

        var newestCredits: Int?
        var errors: [String] = []
        var anySuccess = false
        var usedName = AppSettings.feedSource.title
        var totalAircraft = 0

        for airport in airports {
            if Task.isCancelled { return }
            do {
                let fetched = try await fetch(for: airport)
                newestCredits = fetched.result.creditsRemaining ?? newestCredits
                lastRateLimit = nil
                anySuccess = true
                usedName = fetched.sourceName
                var detector = detectors[airport.icao] ?? LandingDetector()
                let output = detector.ingest(snapshots: fetched.result.snapshots, airport: airport, now: fetched.result.serverTime)
                detectors[airport.icao] = detector
                aircraftByAirport[airport.icao] = output.aircraft
                if airport.icao == selectedICAO {
                    totalAircraft = output.aircraft.filter(\.inRange).count
                }
                persist(output.events, airport: airport)
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
        creditsRemaining = newestCredits
        feedName = usedName
        lastAircraftCount = totalAircraft
        if anySuccess {
            lastError = nil
            let creditText = newestCredits.map { " · \($0) credits left" } ?? ""
            statusText = "\(usedName) · \(totalAircraft) aircraft\(creditText)"
        } else {
            lastError = errors.first
            statusText = errors.first ?? "Unable to reach the live traffic feed."
        }
    }

    private func fetch(for airport: Airport) async throws -> (result: OpenSkyClient.FetchResult, sourceName: String) {
        switch AppSettings.feedSource {
        case .opensky:
            let result = try await OpenSkyClient.shared.fetchStates(
                bbox: airport.boundingBox(),
                clientID: AppSettings.clientID,
                clientSecret: AppSettings.clientSecret
            )
            return (result, "OpenSky")
        case .adsbLol:
            let result = try await ADSBLolClient.shared.fetchStates(center: airport.coordinate, radiusNM: Geo.trackingRadiusNM)
            return (result, "Live ADS-B")
        case .automatic:
            do {
                let result = try await ADSBLolClient.shared.fetchStates(center: airport.coordinate, radiusNM: Geo.trackingRadiusNM)
                return (result, "Live ADS-B")
            } catch {
                let result = try await OpenSkyClient.shared.fetchStates(
                    bbox: airport.boundingBox(),
                    clientID: AppSettings.clientID,
                    clientSecret: AppSettings.clientSecret
                )
                return (result, "OpenSky")
            }
        }
    }

    private func persist(_ events: [LandingDetector.OutputEvent], airport: Airport) {
        guard let modelContext, !events.isEmpty else { return }
        for event in events {
            let stored = StoredTrafficEvent(
                airportICAO: airport.icao,
                aircraftICAO24: event.icao24,
                tailNumber: event.tailNumber,
                aircraftType: event.typeLabel,
                kind: event.kind,
                timestamp: event.timestamp,
                altitudeAGLFt: event.altitudeAGLFt,
                groundSpeedKt: event.groundSpeedKt
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
    static let patternDisplayKey = "map.patternDisplay"

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

    static var hasCredentials: Bool {
        !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !clientSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

enum PatternDisplayMode: String, CaseIterable, Identifiable {
    case none
    case leftHand
    case rightHand
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .leftHand: return "Left hand"
        case .rightHand: return "Right hand"
        case .both: return "Both"
        }
    }
}
