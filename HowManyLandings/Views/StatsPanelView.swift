import SwiftUI

struct StatsPanelView: View {
    let airport: Airport
    let events: [StoredTrafficEvent]
    let sessionStartedAt: Date

    private var hourAgo: Date { Date().addingTimeInterval(-3600) }
    private var dayAgo: Date { Date().addingTimeInterval(-86_400) }

    private var rollingPeriod: (title: String, since: Date) {
        LandingStats.rollingPeriod(sessionStartedAt: sessionStartedAt)
    }

    private var landingsLastHour: Int {
        events.filter { $0.kind.countsAsLanding && $0.timestamp >= hourAgo }.count
    }

    private var landingsInRollingPeriod: Int {
        events.filter { $0.kind.countsAsLanding && $0.timestamp >= rollingPeriod.since }.count
    }

    private var takeoffsLastHour: Int {
        events.filter { $0.kind == .takeoff && $0.timestamp >= hourAgo }.count
    }

    private var recentEvents: [StoredTrafficEvent] {
        events.filter { $0.timestamp >= rollingPeriod.since }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text(airport.icao)
                    .font(.headline.monospaced())
                Text(airport.displayName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                StatCard(
                    title: "Landings · 1h",
                    value: "\(landingsLastHour)",
                    subtitle: "\(takeoffsLastHour) takeoffs"
                )
                StatCard(
                    title: "Landings · \(rollingPeriod.title)",
                    value: "\(landingsInRollingPeriod)",
                    subtitle: rollingPeriod.title == "24h" ? "last 24 hours" : "since session start"
                )
            }
            .padding(14)

            Divider()

            ScrollViewReader { proxy in
                List {
                    if recentEvents.isEmpty {
                        Text("No landings or takeoffs yet. Keep the app running while aircraft are in the pattern.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(recentEvents, id: \.eventID) { event in
                            EventRow(event: event)
                                .id(event.eventID)
                        }
                    }
                }
                .listStyle(.plain)
                .onChange(of: recentEvents.first?.eventID) { _, topID in
                    guard let topID else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(topID, anchor: .top)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.background)
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

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 32, weight: .bold, design: .rounded))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct EventRow: View {
    let event: StoredTrafficEvent

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind.systemImage)
                .font(.body)
                .foregroundStyle(event.kind.countsAsLanding ? Color.orange : Color.cyan)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(event.tailNumber)
                        .font(.subheadline.weight(.semibold).monospaced())
                    Text(event.aircraftType)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(event.kind.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 2) {
                Text(event.timestamp, style: .time)
                    .font(.caption.monospacedDigit())
                if let speed = event.groundSpeedKt {
                    Text("\(Int(speed.rounded())) kt")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}
