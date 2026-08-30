import Charts
import SwiftUI

/// Pattern occupancy and landing statistics (hourly history up to 7 days).
struct PatternStatsWindow: View {
    let airportICAO: String
    @Environment(TrackingEngine.self) private var engine

    private var now: Date { engine.simulationNow }

    private var snapshot: PatternStatsSnapshot {
        engine.patternStatsSnapshot(for: airportICAO, now: now)
    }

    private var hourlySeries: [PatternHourlyBucket] {
        engine.patternHourlyChartSeries(for: airportICAO, now: now)
    }

    private var hasHourlyData: Bool {
        hourlySeries.contains { $0.occupancySampleCount > 0 || $0.landingCount > 0 }
    }

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 10)) { _ in
                statsContent
            }
            .navigationTitle("Stats · \(airportICAO)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 520)
        #endif
    }

    private var statsContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                statsSection(
                    title: "Average aircraft in the pattern",
                    rows: [
                        ("Last 5 minutes", formatAverage(snapshot.avgLast5Min)),
                        ("Last 30 minutes", formatAverage(snapshot.avgLast30Min)),
                        ("Last hour", formatAverage(snapshot.avgLastHour)),
                        ("Last 24 hours", formatAverage(snapshot.avgLast24Hours)),
                        ("Peak", "\(snapshot.peakOccupancy)")
                    ]
                )

                statsSection(
                    title: "Number of landings",
                    rows: [
                        ("Last 5 minutes", "\(snapshot.landingsLast5Min)"),
                        ("Last 30 minutes", "\(snapshot.landingsLast30Min)"),
                        ("Last hour", "\(snapshot.landingsLastHour)")
                    ]
                )

                VStack(alignment: .leading, spacing: 12) {
                    Text("Hourly history (7 days)")
                        .font(.headline)

                    if hourlySeries.isEmpty || !hasHourlyData {
                        Text("Collecting hourly statistics…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        hourlyOccupancyChart
                        hourlyLandingsChart
                    }
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statsSection(title: String, rows: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack {
                        Text(row.0)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.1)
                            .font(.body.monospacedDigit().weight(.semibold))
                    }
                    .padding(.vertical, 6)
                    if index < rows.count - 1 {
                        Divider()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(
                Color.primary.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
        }
    }

    private var hourlyOccupancyChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hourly average aircraft in pattern")
                .font(.subheadline.weight(.semibold))
            Chart(hourlySeries) { bucket in
                LineMark(
                    x: .value("Hour", bucket.hourStart),
                    y: .value("Aircraft", bucket.averageOccupancy)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
            }
            .chartYAxisLabel("Aircraft")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day().hour())
                }
            }
            .frame(height: 180)
        }
    }

    private var hourlyLandingsChart: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Hourly landings")
                .font(.subheadline.weight(.semibold))
            Chart(hourlySeries) { bucket in
                BarMark(
                    x: .value("Hour", bucket.hourStart),
                    y: .value("Landings", bucket.landingCount)
                )
                .foregroundStyle(PatternEventChartColors.landing(confirmed: true))
            }
            .chartYAxisLabel("Landings")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.month().day().hour())
                }
            }
            .frame(height: 160)
        }
    }

    private func formatAverage(_ value: Double) -> String {
        if value == 0 { return "0" }
        if abs(value - Double(Int(value.rounded()))) < 0.05 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}
