import SwiftUI

/// Right-panel list of pattern traffic (≤5 NM and ≤2,000 ft AGL), closest first.
struct PatternTrackerView: View {
    let airport: Airport
    let aircraft: [LandingDetector.TrackedAircraft]
    @Binding var selectedICAO24: String?
    var onDump: ((LandingDetector.TrackedAircraft) -> Void)?
    var onPlanePicked: (() -> Void)?
    var onShowADS: (() -> Void)?

    private var tracked: [LandingDetector.TrackedAircraft] {
        aircraft
            .filter(\.appearsInTracker)
            .sorted { $0.distanceNM < $1.distanceNM }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pattern")
                    .font(.headline)
                Text(airport.patternDirectionSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("Within \(Int(Geo.patternRadiusNM)) NM · ≤ \(Int(Geo.patternMaxAGLFt)) ft AGL · airborne")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(tracked.count) aircraft")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(14)

            Divider()

            ScrollView {
                TimelineView(.periodic(from: .now, by: 10)) { timeline in
                    LazyVStack(alignment: .leading, spacing: 6) {
                        if tracked.isEmpty {
                            Text("No pattern traffic yet. Airborne aircraft inside 5 NM and at or below 2,000 ft AGL appear here. Ground targets stay on the map until they take off.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                        } else {
                            ForEach(tracked) { ac in
                                PatternTrackerCard(
                                    aircraft: ac,
                                    airport: airport,
                                    color: TrackPalette.swatch(for: ac.id),
                                    isSelected: selectedICAO24 == ac.id,
                                    now: timeline.date,
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
                                .padding(.horizontal, 8)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }

            Divider()

            Button("Display ADS") {
                onShowADS?()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
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
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(color)
                    .frame(width: 10, height: 36)
                    .highPriorityGesture(TapGesture().onEnded { onDump() })
                    .help("ADS-B dump")

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
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
                            .lineLimit(1)
                        if aircraft.isCoasting {
                            Text("Lost")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.orange)
                        } else if let phaseText = aircraft.patternChipText {
                            Text(phaseText)
                                .font(.caption2.weight(.semibold).monospaced())
                                .foregroundStyle(phaseChipColor)
                        }
                    }
                    HStack(spacing: 8) {
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

                Spacer(minLength: 4)

                VStack(alignment: .trailing, spacing: 2) {
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
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? color.opacity(0.28) : Color.primary.opacity(0.04),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? color.opacity(0.8) : Color.clear, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .opacity(aircraft.isCoasting ? 0.75 : 1)
    }

    private var lostAgeText: String {
        Self.formatLostAge(from: aircraft.lastSeen, now: now)
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
        case .departure, .crosswind, .downwind:
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
