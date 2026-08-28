import Charts
import SwiftUI

/// Time series of how many aircraft are in the pattern (≤ 2,000 ft AGL, ≤ 5 NM).
struct PatternOccupancyWindow: View {
    @Environment(TrackingEngine.self) private var engine

    private var icao: String? { engine.selectedICAO }

    private var samples: [PatternOccupancySample] {
        guard let icao else { return [] }
        return engine.patternOccupancyHistory(for: icao)
    }

    private var latest: PatternOccupancySample? { samples.last }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                if samples.count < 2 {
                    ContentUnavailableView(
                        "Collecting pattern data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Counts update each ADS-B poll. Lost aircraft still in the pattern are counted until their estimated landing time.")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    chart
                        .padding(16)
                }
            }
            .navigationTitle(icao.map { "Pattern · \($0)" } ?? "Pattern occupancy")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Aircraft in pattern")
                    .font(.headline)
                Text("≤ \(Int(Geo.patternMaxAGLFt)) ft AGL · ≤ \(Int(Geo.patternRadiusNM)) NM · Departure–Final only · lost ETA for Downwind/Base/Final/Flare")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let latest {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(latest.count)")
                        .font(.title2.monospacedDigit().weight(.bold))
                    Text("\(latest.liveCount) live · \(latest.estimatedCount) est.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var chart: some View {
        Chart {
            ForEach(samples) { sample in
                AreaMark(
                    x: .value("Time", sample.time),
                    y: .value("Aircraft", sample.count)
                )
                .foregroundStyle(Color.accentColor.opacity(0.22))
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", sample.time),
                    y: .value("Aircraft", sample.count)
                )
                .foregroundStyle(Color.accentColor)
                .lineStyle(StrokeStyle(lineWidth: 2.25))
                .interpolationMethod(.monotone)

                if sample.estimatedCount > 0 {
                    RuleMark(x: .value("Time", sample.time))
                        .foregroundStyle(Color.orange.opacity(0.08))
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartYAxisLabel("Aircraft")
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 6)) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let n = value.as(Int.self) {
                        Text("\(n)")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var yMax: Int {
        let peak = samples.map(\.count).max() ?? 1
        return max(3, peak + 1)
    }
}
