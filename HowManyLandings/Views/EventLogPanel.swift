import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Landing / takeoff event log (lives in the lower portion of the left airport pane).
struct EventLogPanel: View {
    let airport: Airport?
    let events: [StoredTrafficEvent]
    let sessionStartedAt: Date
    @Binding var selectedEventIDs: Set<UUID>
    @Environment(TrackingEngine.self) private var engine
    @State private var trackDump: TrackDumpPayload?

    private var hourAgo: Date { Date().addingTimeInterval(-3600) }

    private var rollingPeriod: (title: String, since: Date) {
        LandingStats.rollingPeriod(sessionStartedAt: sessionStartedAt)
    }

    private var scopedEvents: [StoredTrafficEvent] {
        guard let airport else { return [] }
        return events.filter { $0.airportICAO == airport.icao && $0.timestamp >= rollingPeriod.since }
    }

    private var landingsLastHour: Int {
        guard let airport else { return 0 }
        return events.filter {
            $0.airportICAO == airport.icao && $0.kind.countsAsLanding && $0.timestamp >= hourAgo
        }.count
    }

    private var takeoffsLastHour: Int {
        guard let airport else { return 0 }
        return events.filter {
            $0.airportICAO == airport.icao && $0.kind == .takeoff && $0.timestamp >= hourAgo
        }.count
    }

    private var selectedEvents: [StoredTrafficEvent] {
        scopedEvents.filter { selectedEventIDs.contains($0.eventID) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Log")
                    .font(.headline)
                if let airport {
                    Text(airport.icao)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        Label("\(landingsLastHour) land", systemImage: "airplane.arrival")
                        Label("\(takeoffsLastHour) to", systemImage: "airplane.departure")
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                } else {
                    Text("Select an airport")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !selectedEventIDs.isEmpty {
                    Button("Clear selection") { selectedEventIDs = [] }
                        .font(.caption.weight(.semibold))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    if airport == nil {
                        Text("Choose an airport above to see landings and takeoffs.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else if scopedEvents.isEmpty {
                        Text("No landings or takeoffs yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    } else {
                        ForEach(scopedEvents, id: \.eventID) { event in
                            let selected = selectedEventIDs.contains(event.eventID)
                            EventLogRow(
                                event: event,
                                trackColor: TrackPalette.color(forEventID: event.eventID, icao24: event.aircraftICAO24),
                                hasTrack: hasDisplayableTrack(event),
                                isSelected: selected,
                                onSelect: { handleTap(on: event) },
                                onDump: { presentDump(for: event) }
                            )
                            .padding(.horizontal, 8)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
        .sheet(item: $trackDump) { dump in
            TrackDumpSheet(dump: dump)
        }
    }

    private func hasDisplayableTrack(_ event: StoredTrafficEvent) -> Bool {
        if event.hasSavedTrack { return true }
        guard let airport else { return false }
        let live = engine.aircraftByAirport[airport.icao] ?? []
        return live.contains { $0.id == event.aircraftICAO24 && !$0.track.isEmpty }
    }

    private func presentDump(for event: StoredTrafficEvent) {
        guard let airport else { return }
        let live = (engine.aircraftByAirport[airport.icao] ?? [])
            .first { $0.id == event.aircraftICAO24 }?.track ?? []
        let points = event.kind.countsAsLanding
            ? TrackSmoother.landingReplayPoints(stored: event.track, live: live, landingAt: event.timestamp)
            : (event.track.isEmpty ? live : event.track)
        guard !points.isEmpty else { return }
        trackDump = TrackDumpPayload(
            id: event.eventID,
            title: "\(event.tailNumber) · \(event.kind.title)",
            subtitle: "Saved event track",
            airportICAO: event.airportICAO,
            airportElevationFt: airport.elevationFt,
            icao24: event.aircraftICAO24,
            reportedKind: event.kind.title,
            reportedTime: event.timestamp,
            points: points
        )
    }

    private func handleTap(on event: StoredTrafficEvent) {
        if isMultiSelectModifierDown {
            if selectedEventIDs.contains(event.eventID) {
                selectedEventIDs.remove(event.eventID)
            } else {
                selectedEventIDs.insert(event.eventID)
            }
            return
        }

        if selectedEventIDs == [event.eventID] {
            selectedEventIDs = []
            if event.kind.countsAsLanding {
                engine.selectedTrackerICAO24 = nil
            }
            return
        }

        selectedEventIDs = [event.eventID]
        if event.kind.countsAsLanding {
            engine.selectedTrackerICAO24 = event.aircraftICAO24
        } else {
            engine.selectedTrackerICAO24 = nil
        }
    }

    private var isMultiSelectModifierDown: Bool {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        return flags.contains(.shift) || flags.contains(.control) || flags.contains(.command)
        #else
        return false
        #endif
    }
}

private struct EventLogRow: View {
    let event: StoredTrafficEvent
    let trackColor: Color
    var hasTrack: Bool = false
    var isSelected: Bool = false
    let onSelect: () -> Void
    let onDump: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                if hasTrack {
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(trackColor)
                        .frame(width: 8, height: 24)
                        .highPriorityGesture(TapGesture().onEnded { onDump() })
                }

                Image(systemName: event.kind.systemImage)
                    .font(.caption)
                    .foregroundStyle(event.kind.countsAsLanding ? Color.orange : Color.cyan)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(event.tailNumber)
                            .font(.caption.weight(.semibold).monospaced())
                            .lineLimit(1)
                        if !event.aircraftType.isEmpty {
                            Text(event.aircraftType)
                                .font(.caption2.monospaced().weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Text(event.kind.title)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 2)
                Text(event.timestamp, style: .time)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected ? trackColor.opacity(0.25) : Color.primary.opacity(0.03),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
        .buttonStyle(.plain)
    }
}

enum LandingStats {
    static func rollingPeriod(sessionStartedAt: Date, now: Date = Date()) -> (title: String, since: Date) {
        let elapsed = now.timeIntervalSince(sessionStartedAt)
        if elapsed < 86_400 {
            return (formatDuration(elapsed), sessionStartedAt)
        }
        return ("24h", now.addingTimeInterval(-86_400))
    }

    static func formatDuration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(1, Int(interval / 60))
        if totalMinutes < 60 {
            return "\(totalMinutes) min"
        }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if minutes == 0 {
            return "\(hours)h"
        }
        return "\(hours)h \(minutes)m"
    }
}
