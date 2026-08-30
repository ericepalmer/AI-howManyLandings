import CoreLocation
import Foundation

/// Collapse duplicate ADS-B contacts that share identity and are co-located.
enum AircraftSnapshotDeduplicator {
    /// Max separation for two hits to be treated as the same aircraft.
    static let proximityNM = 0.2

    static func deduplicated(
        _ snapshots: [AircraftSnapshot],
        preferredICAO24: Set<String> = []
    ) -> [AircraftSnapshot] {
        let aircraft = snapshots.filter(\.category.isAircraft)
        let nonAircraft = snapshots.filter { !$0.category.isAircraft }
        guard aircraft.count > 1 else {
            return snapshots
        }

        var parent = Array(0..<aircraft.count)
        func find(_ index: Int) -> Int {
            var i = index
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        func unite(_ a: Int, _ b: Int) {
            let ra = find(a)
            let rb = find(b)
            if ra != rb { parent[rb] = ra }
        }

        for i in 0..<aircraft.count {
            for j in (i + 1)..<aircraft.count where isDuplicate(aircraft[i], aircraft[j]) {
                unite(i, j)
            }
        }

        var groups: [Int: [AircraftSnapshot]] = [:]
        for index in aircraft.indices {
            groups[find(index), default: []].append(aircraft[index])
        }

        let winners = groups.values.map { pickWinner($0, preferredICAO24: preferredICAO24) }
        return nonAircraft + winners
    }

    private static func isDuplicate(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        guard Geo.distanceNM(a.coordinate, b.coordinate) <= proximityNM else { return false }
        let tailMatch = normalizedTail(a) == normalizedTail(b)
        guard tailMatch else { return false }
        let aCall = normalizedCallsign(a.callsign)
        let bCall = normalizedCallsign(b.callsign)
        if aCall != nil, bCall != nil {
            return aCall == bCall
        }
        return true
    }

    private static func normalizedTail(_ snapshot: AircraftSnapshot) -> String {
        snapshot.tailNumber.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    private static func normalizedCallsign(_ raw: String?) -> String? {
        guard let raw else { return nil }
        return AircraftIdentity.cleanedCallsign(raw)
    }

    private static func pickWinner(
        _ group: [AircraftSnapshot],
        preferredICAO24: Set<String>
    ) -> AircraftSnapshot {
        group.max(by: { qualityScore($0, preferredICAO24: preferredICAO24)
            < qualityScore($1, preferredICAO24: preferredICAO24)
        })!
    }

    private static func qualityScore(_ snapshot: AircraftSnapshot, preferredICAO24: Set<String>) -> Int {
        var score = 0
        if preferredICAO24.contains(snapshot.icao24) { score += 1_000 }
        if snapshot.callsign != nil { score += 40 }
        if snapshot.registration != nil { score += 40 }
        if snapshot.trackDeg != nil { score += 8 }
        if snapshot.velocityMPS != nil { score += 8 }
        if snapshot.verticalRateMPS != nil { score += 4 }
        if snapshot.baroAltitudeMeters != nil || snapshot.geoAltitudeMeters != nil { score += 4 }
        if snapshot.squawk != nil { score += 2 }
        return score
    }
}
