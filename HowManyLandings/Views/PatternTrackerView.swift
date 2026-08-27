import SwiftUI

/// Right-panel list of pattern traffic, grouped by leg.
struct PatternTrackerView: View {
    let airport: Airport
    let aircraft: [LandingDetector.TrackedAircraft]
    @Binding var selectedICAO24: String?
    var onDump: ((LandingDetector.TrackedAircraft) -> Void)?
    var onPlanePicked: (() -> Void)?
    var onShowADS: (() -> Void)?
    var onShowOccupancy: (() -> Void)?

    private var tracked: [LandingDetector.TrackedAircraft] {
        aircraft.filter(\.appearsInTracker)
    }

    private var grouped: [(TrackerCategory, [LandingDetector.TrackedAircraft])] {
        let buckets = Dictionary(grouping: tracked, by: TrackerCategory.category(for:))
        return TrackerCategory.allCases.compactMap { category in
            guard let members = buckets[category], !members.isEmpty else { return nil }
            return (category, category.sorted(members, airport: airport))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Pattern")
                    .font(.headline)
                Text(airport.patternDirectionSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Within \(Int(Geo.patternRadiusNM)) NM · ≤ \(Int(Geo.patternMaxAGLFt)) ft AGL")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(tracked.count) aircraft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            Divider()

            ScrollView {
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if grouped.isEmpty {
                            Text("No pattern traffic yet. Airborne aircraft inside 5 NM and at or below 2,000 ft AGL appear here, plus recently landed for 5 minutes.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        } else {
                            ForEach(grouped, id: \.0) { category, members in
                                TrackerCategoryCard(
                                    category: category,
                                    aircraft: members,
                                    airport: airport,
                                    selectedICAO24: $selectedICAO24,
                                    onDump: onDump,
                                    onPlanePicked: onPlanePicked
                                )
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 3)
                }
            }

            Divider()

            VStack(spacing: 6) {
                Button("Pattern graph") {
                    onShowOccupancy?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)

                Button("Display ADS") {
                    onShowADS?()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }
}

/// Tracker buckets. Empty groups are omitted from the list.
private enum TrackerCategory: Int, CaseIterable, Identifiable {
    case recentlyLanded
    case final
    case base
    case downwind
    case upwind
    case maneuvering
    case leaving

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .recentlyLanded: return "Recently landed"
        case .final: return "Final"
        case .base: return "Base"
        case .downwind: return "Downwind"
        case .upwind: return "Upwind"
        case .maneuvering: return "Maneuvering"
        case .leaving: return "Leaving"
        }
    }

    /// Stable stripe so a hidden neighbor does not flip the shade.
    var usesDarkerStripe: Bool { rawValue.isMultiple(of: 2) == false }

    static func category(for aircraft: LandingDetector.TrackedAircraft) -> TrackerCategory {
        if aircraft.isRecentlyLandedForTracker { return .recentlyLanded }
        switch aircraft.patternPhase {
        case .final, .flare: return .final
        case .base: return .base
        case .downwind: return .downwind
        case .departure, .upwind, .crosswind: return .upwind
        case .leaving: return .leaving
        case .maneuvering, .ground:
            if isRecentTakeoff(aircraft) { return .upwind }
            return .maneuvering
        }
    }

    private static func isRecentTakeoff(_ aircraft: LandingDetector.TrackedAircraft) -> Bool {
        guard let takeoff = aircraft.lastTakeoffAt else { return false }
        return aircraft.asOf.timeIntervalSince(takeoff) <= 90
    }

    func sorted(
        _ aircraft: [LandingDetector.TrackedAircraft],
        airport: Airport
    ) -> [LandingDetector.TrackedAircraft] {
        aircraft.sorted { lhs, rhs in
            let left = sortKey(lhs, airport: airport)
            let right = sortKey(rhs, airport: airport)
            if left != right { return left < right }
            return lhs.id < rhs.id
        }
    }

    private func sortKey(
        _ aircraft: LandingDetector.TrackedAircraft,
        airport: Airport
    ) -> (Int, Double) {
        switch self {
        case .recentlyLanded:
            let age = aircraft.lastLandingAt.map { -$0.timeIntervalSince1970 } ?? 0
            return (0, age)
        case .final:
            let phase = aircraft.patternPhase == .flare ? 0 : 1
            return (phase, aircraft.distanceNM)
        case .upwind:
            let phase: Int
            switch aircraft.patternPhase {
            case .crosswind: phase = 2
            case .upwind: phase = 1
            default: phase = 0
            }
            return (phase, aircraft.distanceNM)
        case .leaving:
            return (0, -aircraft.distanceNM)
        case .base, .downwind, .maneuvering:
            let agl = aircraft.snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt) ?? 9_999
            return (0, aircraft.distanceNM * 1_000 + agl / 100)
        }
    }
}

private struct TrackerCategoryCard: View {
    let category: TrackerCategory
    let aircraft: [LandingDetector.TrackedAircraft]
    let airport: Airport
    @Binding var selectedICAO24: String?
    var onDump: ((LandingDetector.TrackedAircraft) -> Void)?
    var onPlanePicked: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(category.title)
                    .font(.caption.weight(.bold))
                Spacer(minLength: 0)
                Text("\(aircraft.count)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 1)

            ForEach(aircraft) { ac in
                PatternTrackerCard(
                    aircraft: ac,
                    airport: airport,
                    color: TrackPalette.swatch(for: ac.id),
                    isSelected: selectedICAO24 == ac.id,
                    now: ac.asOf,
                    onSelect: {
                        onPlanePicked?()
                        if selectedICAO24 == ac.id {
                            selectedICAO24 = nil
                        } else {
                            selectedICAO24 = ac.id
                        }
                    },
                    onDump: { onDump?(ac) }
                )
            }
        }
        .padding(.horizontal, 3)
        .padding(.bottom, 3)
        .background(
            Color.primary.opacity(category.usesDarkerStripe ? 0.12 : 0.055),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }
}

private struct PatternTrackerCard: View {
    let aircraft: LandingDetector.TrackedAircraft
    let airport: Airport
    let color: Color
    var isSelected: Bool
    var now: Date
    let onSelect: () -> Void
    let onDump: () -> Void

    private var snapshot: AircraftSnapshot { aircraft.snapshot }

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color)
                    .frame(width: 8, height: 28)
                    .highPriorityGesture(TapGesture().onEnded { onDump() })
                    .help("ADS-B dump")

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        AircraftGlyph(
                            kind: AircraftSymbolKind.from(
                                category: snapshot.category,
                                typeCode: snapshot.typeCode
                            ),
                            color: color,
                            heading: 0,
                            isInspected: false
                        )
                        Text(snapshot.mapLabel)
                            .font(.subheadline.weight(.semibold).monospaced())
                            .foregroundStyle(color)
                            .lineLimit(1)
                        if aircraft.isCoasting {
                            Text("Lost")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else if let phaseText = chipText {
                            Text(phaseText)
                                .font(.caption2.weight(.semibold).monospaced())
                                .foregroundStyle(phaseChipColor)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(snapshot.typeDisplay)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !statusText.isEmpty {
                            Text(statusText)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(statusColor)
                        }
                    }
                }

                Spacer(minLength: 2)

                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.1f NM", aircraft.distanceNM))
                        .font(.caption.monospacedDigit().weight(.semibold))
                    if let agl = snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt) {
                        Text("\(Int(agl.rounded())) ft")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    if let gs = snapshot.groundSpeedKt {
                        Text("\(Int(gs.rounded())) kt")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? color.opacity(0.28) : Color.primary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? color.opacity(0.8) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .opacity(aircraft.isCoasting ? 0.75 : 1)
    }

    private var lostAgeText: String {
        Self.formatLostAge(from: aircraft.lastSeen, now: now)
    }

    private var chipText: String? {
        if aircraft.isRecentlyLandedForTracker { return "Landed" }
        return aircraft.patternChipText
    }

    private var statusText: String {
        aircraft.isCoasting ? "\(lostAgeText) ago" : ""
    }

    private var statusColor: Color {
        aircraft.isCoasting ? .secondary : color
    }

    private var phaseChipColor: Color {
        switch aircraft.patternPhase {
        case .ground:
            return TrackPalette.ground
        case .maneuvering, .leaving:
            return .secondary
        case .departure, .upwind, .crosswind, .downwind:
            return .cyan
        case .base, .final, .flare:
            return .orange
        }
    }

    static func formatLostAge(from lastSeen: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(lastSeen)))
        if seconds < 60 { return "\(seconds)s" }
        let minutes = seconds / 60
        let remainder = seconds % 60
        if minutes < 60 {
            return remainder == 0 ? "\(minutes)m" : "\(minutes)m \(remainder)s"
        }
        let hours = minutes / 60
        let minRemainder = minutes % 60
        return minRemainder == 0 ? "\(hours)h" : "\(hours)h \(minRemainder)m"
    }
}
