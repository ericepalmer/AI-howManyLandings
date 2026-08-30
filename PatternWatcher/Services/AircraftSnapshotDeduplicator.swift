import CoreLocation
import Foundation

/// Collapse duplicate ADS-B contacts: same identity, or dual transponders on one airframe.
enum AircraftSnapshotDeduplicator {
    /// Max separation for two hits with matching tail / callsign identity.
    static let proximityNM = 0.2
    /// Dual-broadcast merge: two ICAO24s almost stacked (common with outdated second ADS-B install).
    static let dualEquipmentProximityNM = 0.08
    static let dualEquipmentAltitudeFt = 100.0
    static let dualEquipmentTrackDeg = 25.0
    static let dualEquipmentSpeedKt = 15.0

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

    /// Whether two snapshots are the same physical aircraft (for tracked-state collapse).
    static func areColocatedDuplicates(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        isDuplicate(a, b)
    }

    private static func isDuplicate(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        guard a.category.isAircraft, b.category.isAircraft else { return false }
        let distanceNM = Geo.distanceNM(a.coordinate, b.coordinate)
        guard distanceNM <= proximityNM else { return false }
        if matchingCallsign(a, b) { return true }
        if matchingTail(a, b) { return true }
        if distanceNM <= dualEquipmentProximityNM, matchingDualEquipment(a, b) { return true }
        return false
    }

    /// Same ADS-B callsign while co-located (dual transponders often share one callsign).
    private static func matchingCallsign(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        guard let aCall = normalizedCallsign(a.callsign),
              let bCall = normalizedCallsign(b.callsign),
              aCall == bCall
        else { return false }
        return true
    }

    /// Same registration / derived tail while co-located.
    private static func matchingTail(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        guard normalizedTail(a) == normalizedTail(b) else { return false }
        let aCall = normalizedCallsign(a.callsign)
        let bCall = normalizedCallsign(b.callsign)
        if aCall != nil, bCall != nil {
            return aCall == bCall
        }
        return true
    }

    /// Two transponders on one aircraft: different Mode-S / registration but same place and motion.
    private static func matchingDualEquipment(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        guard a.icao24.caseInsensitiveCompare(b.icao24) != .orderedSame else { return false }
        guard a.onGround == b.onGround else { return false }
        if matchingCallsign(a, b) { return true }

        guard matchingAircraftKind(a, b) else { return false }

        if let altA = a.altitudeMSLFt, let altB = b.altitudeMSLFt {
            guard abs(altA - altB) <= dualEquipmentAltitudeFt else { return false }
        }

        if a.onGround {
            return true
        }

        if let trA = a.trackDeg, let trB = b.trackDeg {
            guard trackDeltaDeg(trA, trB) <= dualEquipmentTrackDeg else { return false }
        }
        if let spA = a.groundSpeedKt, let spB = b.groundSpeedKt {
            guard abs(spA - spB) <= dualEquipmentSpeedKt else { return false }
        }
        return true
    }

    private static func matchingAircraftKind(_ a: AircraftSnapshot, _ b: AircraftSnapshot) -> Bool {
        if let ta = normalizedTypeCode(a), let tb = normalizedTypeCode(b) {
            return ta == tb
        }
        return a.category == b.category
    }

    private static func normalizedTypeCode(_ snapshot: AircraftSnapshot) -> String? {
        guard let raw = snapshot.typeCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased(),
            !raw.isEmpty
        else { return nil }
        return raw.filter { $0.isLetter || $0.isNumber }
    }

    private static func trackDeltaDeg(_ a: Double, _ b: Double) -> Double {
        let delta = abs(a - b).truncatingRemainder(dividingBy: 360)
        return min(delta, 360 - delta)
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

    static func qualityScore(_ snapshot: AircraftSnapshot, preferredICAO24: Set<String> = []) -> Int {
        var score = 0
        if preferredICAO24.contains(snapshot.icao24) { score += 1_000 }
        if snapshot.registration != nil { score += 80 }
        if snapshot.callsign != nil { score += 40 }
        if snapshot.typeCode != nil { score += 20 }
        if snapshot.trackDeg != nil { score += 8 }
        if snapshot.velocityMPS != nil { score += 8 }
        if snapshot.verticalRateMPS != nil { score += 4 }
        if snapshot.baroAltitudeMeters != nil || snapshot.geoAltitudeMeters != nil { score += 4 }
        if snapshot.squawk != nil { score += 2 }
        return score
    }
}
