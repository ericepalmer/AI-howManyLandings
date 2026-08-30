import Foundation

/// Parsed surface wind for runway selection.
struct METARWind: Sendable, Equatable {
    enum Direction: Sendable, Equatable {
        case calm
        case variable
        case degrees(Int)
    }

    var direction: Direction
    var speedKt: Int
    var gustKt: Int?

    var isCalm: Bool {
        direction == .calm || speedKt == 0
    }

    var isLightOrVariable: Bool {
        speedKt < 5 || direction == .variable
    }
}

extension METARObservation {
    var parsedWind: METARWind {
        structuredWind ?? METARClient.parseWind(row: [:], raw: raw)
    }
}

/// Initial active-runway guess from METAR before any landing is observed.
enum RunwayWindSelector {
    private static let crosswindLimitKt = 12.0
    private static let longRunwayMinFt = 4_000

    static func guessDirection(airport: Airport, metar: METARObservation) -> String? {
        guard let longest = airport.runways.max(by: { $0.lengthFt < $1.lengthFt }) else {
            return nil
        }
        let wind = metar.parsedWind

        if wind.isCalm {
            return defaultDirection(for: longest)
        }

        if wind.isLightOrVariable {
            if case .degrees = wind.direction,
               let approach = bestHeadwindApproach(on: longest, wind: wind) {
                return approach.directionIdent
            }
            return defaultDirection(for: longest)
        }

        guard let windDir = windDirectionDegrees(wind) else {
            return defaultDirection(for: longest)
        }
        guard let bestOnLongest = bestHeadwindApproach(on: longest, wind: wind) else {
            return defaultDirection(for: longest)
        }
        let crosswind = crosswindComponent(
            windDirection: windDir,
            windSpeedKt: wind.speedKt,
            runwayHeadingDeg: bestOnLongest.headingDeg
        )
        if crosswind < crosswindLimitKt {
            return bestOnLongest.directionIdent
        }

        return bestMinCrosswindDirection(airport: airport, wind: wind)
            ?? bestOnLongest.directionIdent
    }

    // MARK: - Runway choice

    private static func defaultDirection(for runway: Runway) -> String {
        let le = RunwayApproach.directionIdent(runway.leIdent)
        let he = RunwayApproach.directionIdent(runway.heIdent)
        if le == he { return le }
        let leNum = runwayNumber(le)
        let heNum = runwayNumber(he)
        if let leNum, let heNum {
            return leNum <= heNum ? le : he
        }
        return le
    }

    private static func runwayNumber(_ ident: String) -> Int? {
        let trimmed = ident.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, first.isNumber else { return nil }
        let digits = trimmed.prefix(while: \.isNumber)
        guard let value = Int(digits), value > 0 else { return nil }
        return value
    }

    private static func bestHeadwindApproach(on runway: Runway, wind: METARWind) -> RunwayApproach? {
        guard let windDir = windDirectionDegrees(wind) else { return nil }
        return runway.approaches.max { lhs, rhs in
            headwindComponent(
                windDirection: windDir,
                windSpeedKt: wind.speedKt,
                runwayHeadingDeg: lhs.headingDeg
            )
            < headwindComponent(
                windDirection: windDir,
                windSpeedKt: wind.speedKt,
                runwayHeadingDeg: rhs.headingDeg
            )
        }
    }

    private static func bestMinCrosswindDirection(airport: Airport, wind: METARWind) -> String? {
        guard let windDir = windDirectionDegrees(wind) else { return nil }
        let longRunways = airport.runways.filter { $0.lengthFt > longRunwayMinFt }
        guard !longRunways.isEmpty else { return nil }

        var best: RunwayApproach?
        var bestCross = Double.greatestFiniteMagnitude
        var bestHeadwind = -Double.greatestFiniteMagnitude
        var bestLength = 0

        for runway in longRunways {
            for approach in runway.approaches {
                let cross = crosswindComponent(
                    windDirection: windDir,
                    windSpeedKt: wind.speedKt,
                    runwayHeadingDeg: approach.headingDeg
                )
                let head = headwindComponent(
                    windDirection: windDir,
                    windSpeedKt: wind.speedKt,
                    runwayHeadingDeg: approach.headingDeg
                )
                if cross < bestCross
                    || (cross == bestCross && runway.lengthFt > bestLength)
                    || (cross == bestCross && runway.lengthFt == bestLength && head > bestHeadwind) {
                    bestCross = cross
                    bestHeadwind = head
                    bestLength = runway.lengthFt
                    best = approach
                }
            }
        }
        return best?.directionIdent
    }

    // MARK: - Wind components

    private static func windDirectionDegrees(_ wind: METARWind) -> Double? {
        switch wind.direction {
        case .calm, .variable:
            return nil
        case .degrees(let deg):
            return Double(deg)
        }
    }

    /// Headwind (+) / tailwind (−) in knots for landing along `runwayHeadingDeg`.
    private static func headwindComponent(
        windDirection: Double,
        windSpeedKt: Int,
        runwayHeadingDeg: Double
    ) -> Double {
        let speed = Double(windSpeedKt)
        let deltaRad = (windDirection - runwayHeadingDeg) * .pi / 180
        return speed * cos(deltaRad)
    }

    private static func crosswindComponent(
        windDirection: Double,
        windSpeedKt: Int,
        runwayHeadingDeg: Double
    ) -> Double {
        let speed = Double(windSpeedKt)
        let deltaRad = (windDirection - runwayHeadingDeg) * .pi / 180
        return abs(speed * sin(deltaRad))
    }
}
