import SwiftUI

/// Right-panel list of pattern traffic, grouped by leg (same rules as occupancy graph).
struct PatternTrackerView: View {
    let airport: Airport
    let aircraft: [LandingDetector.TrackedAircraft]
    @Binding var selectedICAO24: String?
    var onDump: ((LandingDetector.TrackedAircraft) -> Void)?
    var onPlanePicked: (() -> Void)?
    var onShowOccupancy: () -> Void = {}
    var onShowStats: () -> Void = {}
    var onShowMETAR: () -> Void = {}
    var onShowADS: () -> Void = {}
    var onHidePanel: (() -> Void)?
    @Environment(TrackingEngine.self) private var engine
    @State private var phaseEditorICAO: String?

    private var panelAircraft: [LandingDetector.TrackedAircraft] {
        aircraft.filter { $0.appearsInPatternPanel(airportElevationFt: airport.elevationFt) }
    }

    private var occupancyCount: Int {
        let now = engine.simulationNow
        return panelAircraft.filter { $0.countsTowardPatternOccupancy(at: now) }.count
    }

    private var grouped: [(TrackerCategory, [LandingDetector.TrackedAircraft])] {
        let now = engine.simulationNow
        let buckets = Dictionary(
            grouping: panelAircraft,
            by: { TrackerCategory.category(for: $0, now: now) }
        )
        return TrackerCategory.allCases.compactMap { category in
            guard let members = buckets[category], !members.isEmpty else { return nil }
            return (category, category.sorted(members, airport: airport))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if !panelAircraft.isEmpty {
                    Text("\(panelAircraft.count) aircraft · \(occupancyCount) toward landing")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let onHidePanel {
                    Button(action: onHidePanel) {
                        Image(systemName: "sidebar.right")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Hide panel")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)

            if !panelAircraft.isEmpty {
                Divider()
            }

            ScrollView {
                TimelineView(.periodic(from: .now, by: 10)) { _ in
                    LazyVStack(alignment: .leading, spacing: 3) {
                        if grouped.isEmpty {
                            Text("No pattern traffic yet. Airborne inside 5 NM and at or below 2,000 ft AGL.")
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
                                    phaseEditorICAO: $phaseEditorICAO,
                                    hoveredICAO24: engine.hoveredTrackerICAO24(for: airport.icao),
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
            .frame(maxHeight: .infinity)

            Divider()

            PatternAccessoryPanel(
                airportICAO: airport.icao,
                onShowOccupancy: onShowOccupancy,
                onShowStats: onShowStats,
                onShowMETAR: onShowMETAR,
                onShowADS: onShowADS
            )
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: selectedICAO24) { _, newValue in
            if phaseEditorICAO != newValue {
                phaseEditorICAO = nil
            }
        }
    }
}

/// Tracker buckets. Empty groups are omitted from the list.
private enum TrackerCategory: Int, CaseIterable, Identifiable {
    case recentlyLanded
    case final
    case base
    case downwind
    case crosswind
    case upwind
    case maneuvering

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .recentlyLanded: return "Recently landed"
        case .final: return "Final"
        case .base: return "Base"
        case .downwind: return "Downwind"
        case .crosswind: return "Crosswind"
        case .upwind: return "Upwind"
        case .maneuvering: return "Maneuvering"
        }
    }

    /// Stable stripe so a hidden neighbor does not flip the shade.
    var usesDarkerStripe: Bool { rawValue.isMultiple(of: 2) == false }

    static func category(
        for aircraft: LandingDetector.TrackedAircraft,
        now: Date
    ) -> TrackerCategory {
        if aircraft.showsLandedChip { return .recentlyLanded }
        if aircraft.effectivePatternStatusUnknown {
            return .maneuvering
        }
        if aircraft.effectivePatternLiberalUncertain {
            return legCategory(for: aircraft.displayPatternPhase)
        }
        if !aircraft.countsTowardPatternOccupancy(at: now) {
            return .maneuvering
        }
        return legCategory(for: aircraft.displayPatternPhase)
    }

    private static func legCategory(for phase: PatternPhase) -> TrackerCategory {
        switch phase {
        case .final, .flare: return .final
        case .base: return .base
        case .downwind: return .downwind
        case .crosswind: return .crosswind
        case .departure, .upwind: return .upwind
        case .leaving, .maneuvering, .ground: return .maneuvering
        }
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
            let phase = aircraft.displayPatternPhase == .flare ? 0 : 1
            return (phase, aircraft.distanceNM)
        case .upwind:
            let phase: Int
            switch aircraft.displayPatternPhase {
            case .upwind: phase = 1
            case .departure: phase = 0
            default: phase = 2
            }
            return (phase, aircraft.distanceNM)
        case .maneuvering:
            if aircraft.effectivePatternStatusUnknown {
                return (0, aircraft.distanceNM)
            }
            switch aircraft.displayPatternPhase {
            case .leaving:
                return (0, -aircraft.distanceNM)
            default:
                let agl = aircraft.snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt) ?? 9_999
                return (1, aircraft.distanceNM * 1_000 + agl / 100)
            }
        case .crosswind, .base, .downwind:
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
    @Binding var phaseEditorICAO: String?
    var hoveredICAO24: String?
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
                    airportICAO: airport.icao,
                    airportElevationFt: airport.elevationFt,
                    color: TrackPalette.swatch(for: ac.id),
                    isSelected: selectedICAO24 == ac.id,
                    isPhaseEditing: phaseEditorICAO == ac.id,
                    isHovered: hoveredICAO24 == ac.id,
                    now: ac.asOf,
                    onSelect: {
                        onPlanePicked?()
                        if selectedICAO24 == ac.id {
                            selectedICAO24 = nil
                        } else {
                            selectedICAO24 = ac.id
                        }
                    },
                    onBeginPhaseEdit: {
                        onPlanePicked?()
                        selectedICAO24 = ac.id
                        phaseEditorICAO = ac.id
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
    let airportICAO: String
    let airportElevationFt: Int
    let color: Color
    var isSelected: Bool
    var isPhaseEditing: Bool
    var isHovered: Bool
    var now: Date
    let onSelect: () -> Void
    let onBeginPhaseEdit: () -> Void
    let onDump: () -> Void
    @Environment(TrackingEngine.self) private var engine
    @State private var copiedTrack = false

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
                        if isPhaseEditing {
                            statusPicker
                        } else if aircraft.isCoasting {
                            Text("Lost")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else if let phaseText = chipText {
                            Text(phaseText)
                                .font(.caption2.weight(.semibold).monospaced())
                                .foregroundStyle(.white)
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

                Image(systemName: copiedTrack ? "checkmark.circle.fill" : "doc.on.clipboard")
                    .font(.caption)
                    .foregroundStyle(copiedTrack ? color : .secondary)
                    .highPriorityGesture(TapGesture().onEnded { copyTrackToClipboard() })
                    .help("Copy last 5 minutes of track data")
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? color.opacity(0.28)
                    : isHovered ? color.opacity(0.20)
                    : Color.primary.opacity(0.10),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        isSelected ? color.opacity(0.8)
                            : isHovered ? color.opacity(0.55)
                            : Color.clear,
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .highPriorityGesture(TapGesture(count: 2).onEnded { onBeginPhaseEdit() })
        .opacity(aircraft.isCoasting ? 0.75 : 1)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private func copyTrackToClipboard() {
        let dump = TrackDumpPayload.forTrackerAircraft(
            aircraft,
            airportICAO: airportICAO,
            airportElevationFt: airportElevationFt,
            now: now
        )
        Clipboard.copy(dump.text)
        copiedTrack = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copiedTrack = false
        }
    }

    private var lostAgeText: String {
        Self.formatLostAge(from: aircraft.lastSeen, now: now)
    }

    private var chipText: String? {
        if aircraft.showsLandedChip { return "Landed" }
        return aircraft.patternChipText
    }

    private var statusPicker: some View {
        Menu {
            Section("Landings") {
                ForEach(TrackerUserAssignment.landingOptions, id: \.self) { assignment in
                    Button {
                        engine.setUserTrackerAssignment(
                            assignment,
                            icao24: aircraft.id,
                            airportICAO: airportICAO
                        )
                    } label: {
                        if isAssignmentSelected(assignment) {
                            Label(assignment.title, systemImage: "checkmark")
                        } else {
                            Text(assignment.title)
                        }
                    }
                }
            }
            Section("Pattern") {
                ForEach(TrackerUserAssignment.patternOptions, id: \.self) { assignment in
                    Button {
                        engine.setUserTrackerAssignment(
                            assignment,
                            icao24: aircraft.id,
                            airportICAO: airportICAO
                        )
                    } label: {
                        if isAssignmentSelected(assignment) {
                            Label(assignment.title, systemImage: "checkmark")
                        } else {
                            Text(assignment.title)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(pickerLabelText)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var pickerLabelText: String {
        chipText ?? "Unknown"
    }

    private func isAssignmentSelected(_ assignment: TrackerUserAssignment) -> Bool {
        if aircraft.userAssignment == assignment { return true }
        if aircraft.userAssignment == nil {
            switch assignment {
            case .landed:
                return aircraft.isRecentlyLandedForTracker
            case .patternPhase(let phase):
                return !aircraft.isRecentlyLandedForTracker
                    && aircraft.patternPhase == phase
                    && !aircraft.patternStatusUnknown
                    && !aircraft.patternLiberalUncertain
            }
        }
        return false
    }

    private var statusText: String {
        aircraft.isCoasting ? "\(lostAgeText) ago" : ""
    }

    private var statusColor: Color {
        aircraft.isCoasting ? .secondary : color
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
