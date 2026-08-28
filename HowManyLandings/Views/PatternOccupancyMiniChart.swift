import Charts
import SwiftUI

/// Compact 10-minute pattern occupancy sparkline for the sidebar (4:1 aspect).
struct PatternOccupancyMiniChart: View {
    @Environment(TrackingEngine.self) private var engine
    let airportICAO: String?

    private var samples: [PatternOccupancySample] {
        guard let airportICAO else { return [] }
        let all = engine.patternOccupancyHistory(for: airportICAO)
        return PatternOccupancy.recentSamples(all, now: engine.simulationNow)
    }

    private var latest: PatternOccupancySample? { samples.last }

    private var xDomain: ClosedRange<Date> {
        let end = engine.simulationNow
        let start = end.addingTimeInterval(-PatternOccupancy.miniChartWindow)
        return start...end
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Pattern · 10 min")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if let latest {
                    Text("\(latest.count)")
                        .font(.caption.monospacedDigit().weight(.bold))
                }
            }

            if samples.count < 2 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .aspectRatio(4, contentMode: .fit)
                    .overlay {
                        Text("Collecting…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                Chart {
                    ForEach(samples) { sample in
                        AreaMark(
                            x: .value("Time", sample.time),
                            y: .value("Aircraft", sample.count)
                        )
                        .foregroundStyle(Color.accentColor.opacity(0.2))
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Time", sample.time),
                            y: .value("Aircraft", sample.count)
                        )
                        .foregroundStyle(Color.accentColor)
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                        .interpolationMethod(.monotone)
                    }
                }
                .chartYScale(domain: 0...yMax)
                .chartXScale(domain: xDomain)
                .chartXAxis {
                    AxisMarks(values: .stride(by: .minute, count: 5)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel(format: .dateTime.hour().minute(), centered: true)
                            .font(.system(size: 9, design: .monospaced))
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                            .foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel {
                            if let n = value.as(Int.self) {
                                Text("\(n)")
                                    .font(.system(size: 9, design: .monospaced))
                            }
                        }
                    }
                }
                .aspectRatio(4, contentMode: .fit)
            }
        }
    }

    private var yMax: Int {
        let peak = samples.map(\.count).max() ?? 1
        return max(2, peak + 1)
    }
}
