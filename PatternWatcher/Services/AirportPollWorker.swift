import Foundation

/// CPU-heavy per-airport poll work off the main actor.
enum AirportPollWorker {
    struct ProcessedPoll: Sendable {
        var detector: LandingDetector
        var aircraft: [LandingDetector.TrackedAircraft]
        var landingMarkers: [PatternLandingMarker]
        var takeoffMarkers: [PatternTakeoffMarker]
        var activeRunwayDirection: String?
        var adsFeedPoll: ADSFeedPoll
        var adsLogLines: [String]
    }

    static func process(
        detector: LandingDetector,
        snapshots: [AircraftSnapshot],
        airport: Airport,
        trackingRadiusNM: Double,
        now: Date,
        sourceName: String,
        accumulateADSFeed: Bool
    ) -> ProcessedPoll {
        let preferredICAO = Set(detector.trackedICAO24s)
        let deduped = AircraftSnapshotDeduplicator.deduplicated(
            snapshots,
            preferredICAO24: preferredICAO
        )
        var detector = detector
        let output = detector.ingest(
            snapshots: deduped,
            airport: airport,
            trackingRadiusNM: trackingRadiusNM,
            now: now
        )
        let feed = ADSFeedBuffer.makePoll(
            snapshots: deduped,
            airport: airport,
            sourceName: sourceName,
            receivedAt: now
        )
        return ProcessedPoll(
            detector: detector,
            aircraft: output.aircraft,
            landingMarkers: output.landingMarkers,
            takeoffMarkers: output.takeoffMarkers,
            activeRunwayDirection: detector.activeRunwayDirection,
            adsFeedPoll: feed.poll,
            adsLogLines: accumulateADSFeed ? feed.logLines : []
        )
    }
}

/// Network fetch decoupled from `TrackingEngine` so awaits do not pin the main actor.
enum TrafficFeedFetcher {
    static func fetch(
        for airport: Airport,
        feedSource: TrafficFeedSource,
        clientID: String,
        clientSecret: String,
        trackingRadiusNM: Double,
        recordedPoll: ADSRecordedPoll?,
        recordedFileName: String?
    ) async throws -> (result: OpenSkyClient.FetchResult, sourceName: String) {
        let radius = trackingRadiusNM
        switch feedSource {
        case .opensky:
            let result = try await OpenSkyClient.shared.fetchStates(
                bbox: airport.boundingBox(radiusNM: radius),
                clientID: clientID,
                clientSecret: clientSecret
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
                    clientID: clientID,
                    clientSecret: clientSecret
                )
                return (result, "OpenSky")
            }
        case .recorded:
            guard let poll = recordedPoll else {
                throw ADSRecordingError.noFileLoaded
            }
            let label = recordedFileName.map { "Recorded · \($0)" } ?? "Recorded ADS-B"
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
}
