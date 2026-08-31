import Foundation

/// Published Vso (stall in landing configuration, max gross) in knots.
/// Used for kinematic landing: GS below 1.3×Vso (criterion 2, Final/Flare, AGL < 0).
/// Criterion 1b logs on surface contact in the pending runway corridor (ADS-B margin).
///
/// Sources: FAA TCDS / POH airspeed limitations (flaps full, power off). ADS-B ground
/// speed is compared directly — close enough at pattern speeds.
enum AircraftStallSpeed {
    static let approachSpeedFactor = 1.3
    /// Hold inferred ground state while ADS-B still shows airborne after criterion 2.
    static let nearGroundSpeedFactor = 1.2

    // MARK: - Type lookup (ICAO designator → Vso kt)

    /// Exact ICAO type designators (normalized uppercase, no punctuation).
    static let typeVsoKnots: [String: Double] = [
        // Cessna singles
        "C152": 35, "C150": 35, "C140": 38, "C170": 40,
        "C172": 48, "C172N": 48, "C172P": 40, "C172R": 48, "C172S": 48,
        "C175": 48, "C177": 48, "C180": 48, "C182": 49, "C185": 50,
        "C206": 51, "C210": 55, "C337": 61, "C340": 61, "C402": 71,
        "C414": 75, "C421": 78, "C425": 78,
        // Piper
        "PA18": 38, "PA22": 42, "PA24": 48, "PA28": 49, "PA28R": 52,
        "PA30": 58, "PA32": 55, "PA32R": 58, "PA34": 61, "PA44": 65,
        "PA46": 61, "P28A": 49, "P28B": 49, "P28R": 52, "P32R": 58,
        "P46T": 68,
        // Beech
        "BE33": 55, "BE35": 55, "BE36": 55, "BE58": 61, "BE9L": 61,
        "BE20": 78, "B190": 85, "B350": 85,
        // Mooney / Grumman / American
        "M20P": 55, "M20T": 58, "M20R": 58, "AA5": 48, "AA1": 45,
        // Cirrus / Diamond / Van's / Cub
        "SR20": 49, "SR22": 52, "SR22T": 52,
        "DA20": 42, "DA40": 45, "DA42": 56, "DA62": 61,
        "RV6": 50, "RV7": 50, "RV8": 52, "RV9": 48, "RV10": 52, "RV12": 42,
        "J3": 38, "L4": 38, "CUB2": 38,
        // Turboprops
        "TBM7": 68, "TBM8": 68, "TBM9": 68, "PC12": 77, "PC6": 45,
        "P180": 68, "P210": 68, "M600": 68,
        // Light jets / bizjets
        "C25A": 85, "C25B": 85, "C25C": 85, "C510": 75, "C525": 85,
        "C526": 85, "C550": 95, "C560": 98, "C680": 105, "C700": 105,
        "LJ35": 92, "LJ35A": 92, "LJ45": 95, "LJ60": 98, "LJ75": 98,
        "E50P": 85, "E55P": 95, "EA50": 85, "HDJT": 85, "PRM1": 85,
        "G150": 95, "G200": 95, "G280": 98, "GLF4": 110, "GLF5": 115,
        "FA50": 95, "FA7X": 105, "FA8X": 105, "F2TH": 95, "F900": 98,
        "PC24": 95, "SF50": 75,
        // Regional / airliners (representative Vso)
        "B737": 125, "B738": 125, "B739": 125, "B752": 130, "B763": 130,
        "B772": 130, "B773": 130, "B788": 125, "B789": 125,
        "A319": 120, "A320": 120, "A321": 125, "A332": 130, "A333": 130,
        "A359": 125, "A388": 135,
        "E170": 115, "E175": 115, "E190": 120, "E195": 120,
        "CRJ2": 115, "CRJ7": 115, "CRJ9": 120, "BCS1": 115, "BCS3": 120,
        // Helicopters (effective approach/min controllable)
        "R22": 42, "R44": 50, "R66": 52, "B06": 55, "B407": 52,
        "EC35": 42, "EC45": 48, "AS50": 48, "AS55": 52, "H60": 55,
        "S76": 58, "A109": 52, "A139": 55,
        // Gliders / ultralight
        "GLID": 36, "S10": 36,
    ]

    /// Prefix families when the exact designator is absent (longest prefix wins).
    static let prefixVsoKnots: [(String, Double)] = [
        ("C172", 48), ("C152", 35), ("C182", 49), ("C206", 51), ("C25", 85),
        ("PA28", 49), ("PA32", 55), ("PA44", 65), ("BE36", 55), ("BE58", 61),
        ("LJ35", 92), ("LJ45", 95), ("LJ60", 98), ("LJ75", 98),
        ("B737", 125), ("B738", 125), ("B739", 125), ("A320", 120),
        ("CRJ", 115), ("E17", 115), ("E19", 120), ("GLF", 110),
        ("C56", 98), ("C55", 95), ("C52", 85), ("FA8", 105), ("FA7", 105),
        ("TBM", 68), ("PC12", 77), ("SR22", 52), ("SR20", 49),
        ("RV", 50), ("DA40", 45), ("DA42", 56), ("EC", 42), ("R44", 50),
    ]

    // MARK: - Category fallbacks (unknown type)

    static let categoryVsoKnots: [AircraftCategory: Double] = [
        .ultralight: 32,
        .light: 48,
        .small: 58,
        .large: 110,
        .heavy: 125,
        .highVortexLarge: 115,
        .highPerformance: 75,
        .glider: 36,
        .lighterThanAir: 28,
        .rotorcraft: 48,
        .unknown: 55,
        .noInfo: 55,
        .reserved: 55,
        .uav: 45,
        .space: 130,
    ]

    static let defaultVsoKnots = 55.0

    // MARK: - API

    static func normalizedTypeCode(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return nil }
        return trimmed.filter { $0.isLetter || $0.isNumber }
    }

    static func vsoKnots(typeCode: String?, category: AircraftCategory) -> Double {
        if let code = normalizedTypeCode(typeCode) {
            if let exact = typeVsoKnots[code] { return exact }
            var bestPrefix: (length: Int, vso: Double)?
            for (prefix, vso) in prefixVsoKnots where code.hasPrefix(prefix) {
                if bestPrefix == nil || prefix.count > bestPrefix!.length {
                    bestPrefix = (prefix.count, vso)
                }
            }
            if let bestPrefix { return bestPrefix.vso }
        }
        return categoryVsoKnots[category] ?? defaultVsoKnots
    }

    /// 1.3×Vso — criterion 2 (AGL < 0, Final/Flare).
    static func patternApproachSpeedKnots(typeCode: String?, category: AircraftCategory) -> Double {
        approachSpeedFactor * vsoKnots(typeCode: typeCode, category: category)
    }

    /// 1.2×Vso — hold inferred ground while ADS-B still shows airborne after criterion 2.
    static func nearGroundApproachSpeedKnots(typeCode: String?, category: AircraftCategory) -> Double {
        nearGroundSpeedFactor * vsoKnots(typeCode: typeCode, category: category)
    }

    static func vsoKnots(for snapshot: AircraftSnapshot) -> Double {
        vsoKnots(typeCode: snapshot.typeCode, category: snapshot.category)
    }

    static func patternApproachSpeedKnots(for snapshot: AircraftSnapshot) -> Double {
        patternApproachSpeedKnots(typeCode: snapshot.typeCode, category: snapshot.category)
    }

    static func nearGroundApproachSpeedKnots(for snapshot: AircraftSnapshot) -> Double {
        nearGroundApproachSpeedKnots(typeCode: snapshot.typeCode, category: snapshot.category)
    }

    /// Human-readable summary of the stall-speed table for settings / debug.
    static var tableSummary: String {
        var lines = [
            "Aircraft stall speeds (Vso kt, landing config, max gross)",
            "Criterion 2: Final/Flare, AGL < 0, GS < 1.3×Vso",
            "",
            "— Common types (ICAO designator → Vso → 1.3×Vso) —",
        ]
        let common = [
            "C152", "C172", "C182", "PA28", "PA44", "SR22", "DA40", "BE36", "BE58",
            "TBM7", "PC12", "C525", "LJ35", "B738", "A320", "R44",
        ]
        for code in common {
            let vso = typeVsoKnots[code] ?? vsoKnots(typeCode: code, category: .light)
            let approach = patternApproachSpeedKnots(typeCode: code, category: .light)
            let padded = (code as NSString).padding(toLength: 6, withPad: " ", startingAt: 0)
            lines.append("  \(padded)  Vso \(Int(vso)) kt   1.3×Vso \(Int(approach)) kt")
        }
        lines.append("")
        lines.append("— Category fallbacks (unknown type) —")
        for category in [
            AircraftCategory.ultralight, .light, .small, .large, .heavy,
            .highVortexLarge, .highPerformance, .glider, .lighterThanAir,
            .rotorcraft, .unknown,
        ] {
            let vso = categoryVsoKnots[category] ?? defaultVsoKnots
            let approach = approachSpeedFactor * vso
            let name = category.displayName.padding(toLength: 18, withPad: " ", startingAt: 0)
            lines.append("  \(name)  Vso \(Int(vso)) kt   1.3×Vso \(Int(approach)) kt")
        }
        return lines.joined(separator: "\n")
    }
}
