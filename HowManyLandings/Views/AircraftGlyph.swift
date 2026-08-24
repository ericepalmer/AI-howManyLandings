import SwiftUI

enum AircraftSymbolKind: Sendable {
    case light
    case medium
    case jet
    case rotor

    static func from(category: AircraftCategory, typeCode: String?) -> AircraftSymbolKind {
        let type = (typeCode ?? "").uppercased()
        if category == .rotorcraft || isRotor(type) { return .rotor }
        if isJet(type) { return .jet }
        switch category {
        case .large, .highVortexLarge, .heavy, .highPerformance:
            return .jet
        case .light, .ultralight, .glider, .uav:
            return .light
        case .small:
            return .medium
        default:
            return type.isEmpty ? .light : .medium
        }
    }

    private static func isRotor(_ type: String) -> Bool {
        type.hasPrefix("R22") || type.hasPrefix("R44") || type.hasPrefix("R66")
            || type.hasPrefix("B06") || type.hasPrefix("B407") || type.hasPrefix("EC")
            || type.hasPrefix("AS50") || type.hasPrefix("AS55") || type.hasPrefix("H60")
            || type.hasPrefix("S76") || type.hasPrefix("A109") || type.hasPrefix("A139")
    }

    private static func isJet(_ type: String) -> Bool {
        let prefixes = [
            "B7", "B8", "B2", "B3", "A1", "A2", "A3", "A4",
            "E17", "E19", "E75", "E50", "E55", "E35", "CRJ", "BCS",
            "C25", "C50", "C52", "C55", "C56", "C68", "C70",
            "CL3", "CL6", "GLF", "GLE", "GL5", "GL6", "GL7", "GAL",
            "FA5", "FA7", "FA8", "LJ", "H25", "F2T", "F900",
            "G150", "G280", "G650", "PC24", "HDJT", "EA50",
        ]
        return prefixes.contains { type.hasPrefix($0) }
    }
}

struct AircraftGlyph: View {
    let kind: AircraftSymbolKind
    let color: Color
    var heading: Double
    var isInspected: Bool

    var body: some View {
        let size: CGFloat = {
            switch kind {
            case .light: return isInspected ? 20 : 16
            case .medium: return isInspected ? 24 : 20
            case .jet: return isInspected ? 28 : 24
            case .rotor: return isInspected ? 24 : 20
            }
        }()

        glyph(size: size)
            .rotationEffect(.degrees(heading))
            .shadow(color: color.opacity(isInspected ? 0.95 : 0.45), radius: isInspected ? 8 : 1)
    }

    @ViewBuilder
    private func glyph(size: CGFloat) -> some View {
        switch kind {
        case .light: painted(LightPlaneShape(), size: size)
        case .medium: painted(MediumPlaneShape(), size: size)
        case .jet: painted(JetShape(), size: size)
        case .rotor: painted(RotorShape(), size: size)
        }
    }

    private func painted<S: Shape>(_ shape: S, size: CGFloat) -> some View {
        shape
            .fill(color)
            .overlay(
                shape.stroke(
                    isInspected ? Color.white.opacity(0.9) : Color.black.opacity(0.55),
                    lineWidth: isInspected ? 1.1 : 0.7
                )
            )
            .frame(width: size, height: size)
    }
}

/// Top-down Cessna-style single: straight wings, long tail.
struct LightPlaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        // Fuselage, nose up
        path.addRoundedRect(
            in: CGRect(x: w * 0.42, y: h * 0.06, width: w * 0.16, height: h * 0.78),
            cornerSize: CGSize(width: w * 0.08, height: w * 0.08)
        )
        // Wings
        path.addRoundedRect(
            in: CGRect(x: w * 0.06, y: h * 0.38, width: w * 0.88, height: h * 0.12),
            cornerSize: CGSize(width: h * 0.04, height: h * 0.04)
        )
        // Tailplane
        path.addRoundedRect(
            in: CGRect(x: w * 0.28, y: h * 0.78, width: w * 0.44, height: h * 0.08),
            cornerSize: CGSize(width: h * 0.03, height: h * 0.03)
        )
        // Nose
        path.addEllipse(in: CGRect(x: w * 0.40, y: h * 0.02, width: w * 0.20, height: h * 0.14))
        return path
    }
}

/// Twin / turboprop: broader wing, engine nacelles.
struct MediumPlaneShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.addRoundedRect(
            in: CGRect(x: w * 0.40, y: h * 0.04, width: w * 0.20, height: h * 0.80),
            cornerSize: CGSize(width: w * 0.09, height: w * 0.09)
        )
        path.addRoundedRect(
            in: CGRect(x: w * 0.02, y: h * 0.34, width: w * 0.96, height: h * 0.14),
            cornerSize: CGSize(width: h * 0.04, height: h * 0.04)
        )
        // Nacelles
        path.addRoundedRect(
            in: CGRect(x: w * 0.18, y: h * 0.30, width: w * 0.12, height: h * 0.22),
            cornerSize: CGSize(width: w * 0.04, height: w * 0.04)
        )
        path.addRoundedRect(
            in: CGRect(x: w * 0.70, y: h * 0.30, width: w * 0.12, height: h * 0.22),
            cornerSize: CGSize(width: w * 0.04, height: w * 0.04)
        )
        path.addRoundedRect(
            in: CGRect(x: w * 0.24, y: h * 0.76, width: w * 0.52, height: h * 0.10),
            cornerSize: CGSize(width: h * 0.03, height: h * 0.03)
        )
        path.addEllipse(in: CGRect(x: w * 0.38, y: h * 0.00, width: w * 0.24, height: h * 0.16))
        return path
    }
}

/// Swept-wing jet, nose up.
struct JetShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        // Fuselage
        path.move(to: CGPoint(x: w * 0.50, y: h * 0.02))
        path.addQuadCurve(to: CGPoint(x: w * 0.58, y: h * 0.18), control: CGPoint(x: w * 0.58, y: h * 0.08))
        path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.78))
        path.addQuadCurve(to: CGPoint(x: w * 0.42, y: h * 0.78), control: CGPoint(x: w * 0.50, y: h * 0.90))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.18))
        path.addQuadCurve(to: CGPoint(x: w * 0.50, y: h * 0.02), control: CGPoint(x: w * 0.42, y: h * 0.08))
        path.closeSubpath()
        // Swept left wing
        path.move(to: CGPoint(x: w * 0.42, y: h * 0.36))
        path.addLine(to: CGPoint(x: w * 0.02, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.08, y: h * 0.64))
        path.addLine(to: CGPoint(x: w * 0.42, y: h * 0.50))
        path.closeSubpath()
        // Swept right wing
        path.move(to: CGPoint(x: w * 0.58, y: h * 0.36))
        path.addLine(to: CGPoint(x: w * 0.98, y: h * 0.58))
        path.addLine(to: CGPoint(x: w * 0.92, y: h * 0.64))
        path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.50))
        path.closeSubpath()
        // Tailplane
        path.move(to: CGPoint(x: w * 0.42, y: h * 0.72))
        path.addLine(to: CGPoint(x: w * 0.22, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.28, y: h * 0.88))
        path.addLine(to: CGPoint(x: w * 0.50, y: h * 0.80))
        path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.88))
        path.addLine(to: CGPoint(x: w * 0.78, y: h * 0.84))
        path.addLine(to: CGPoint(x: w * 0.58, y: h * 0.72))
        path.closeSubpath()
        return path
    }
}

struct RotorShape: Shape {
    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        var path = Path()
        path.addEllipse(in: CGRect(x: w * 0.32, y: h * 0.28, width: w * 0.36, height: h * 0.40))
        path.addRoundedRect(
            in: CGRect(x: w * 0.46, y: h * 0.58, width: w * 0.08, height: h * 0.32),
            cornerSize: CGSize(width: 2, height: 2)
        )
        // Rotor disc
        path.addEllipse(in: CGRect(x: w * 0.08, y: h * 0.08, width: w * 0.84, height: h * 0.34))
        return path
    }
}
