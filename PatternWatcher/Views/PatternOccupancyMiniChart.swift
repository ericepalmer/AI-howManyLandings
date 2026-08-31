import Charts
import SwiftUI

/// Compact 10-minute pattern occupancy sparkline for the main window panel (4:1 aspect).
struct PatternOccupancyMiniChart: View {
    @Environment(TrackingEngine.self) private var engine
    let airportICAO: String

    private var samples: [PatternOccupancySample] {
        let all = engine.patternOccupancyHistory(for: airportICAO)
        return PatternOccupancy.recentSamples(all, now: engine.simulationNow)
    }

    private var chartEnd: Date { engine.simulationNow }

    private var feedGaps: [PatternFeedGap] {
        var gaps = engine.patternFeedGaps(for: airportICAO)
        let threshold = PatternOccupancy.feedGapThreshold(
            pollInterval: AppSettings.pollIntervalSeconds
        )
        let all = engine.patternOccupancyHistory(for: airportICAO)
        if let last = all.last {
            let elapsed = chartEnd.timeIntervalSince(last.time)
            if elapsed > threshold {
                gaps.append(PatternFeedGap(start: last.time, end: chartEnd))
            }
        }
        return gaps
    }

    private var visibleGaps: [PatternFeedGap] {
        PatternOccupancy.gapsInRange(feedGaps, from: visibleStart, to: chartEnd)
    }

    private var sampleSegments: [[PatternOccupancySample]] {
        PatternOccupancy.contiguousSampleSegments(samples: samples, gaps: feedGaps)
    }

    private var xDomain: ClosedRange<Date> {
        let end = chartEnd
        let start = end.addingTimeInterval(-PatternOccupancy.miniChartWindow)
        return start...end
    }

    private var visibleStart: Date { xDomain.lowerBound }

    private var landingMarkers: [PatternLandingMarker] {
        engine.patternLandingMarkers(for: airportICAO)
            .filter { $0.time >= visibleStart }
    }

    private var takeoffMarkers: [PatternTakeoffMarker] {
        engine.patternTakeoffMarkers(for: airportICAO)
            .filter { $0.time >= visibleStart }
    }

    var body: some View {
        Group {
            if samples.count < 2 {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay {
                        Text("Collecting…")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
            } else {
                Chart {
                    ForEach(visibleGaps) { gap in
                        RectangleMark(
                            xStart: .value("Time", gap.start),
                            xEnd: .value("Time", gap.end),
                            yStart: .value("Aircraft", 0),
                            yEnd: .value("Aircraft", Double(yMax))
                        )
                        .foregroundStyle(Color.secondary.opacity(0.14))
                    }

                    ForEach(Array(sampleSegments.enumerated()), id: \.offset) { _, segment in
                        ForEach(segment) { sample in
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

                    ForEach(landingMarkers) { marker in
                        RectangleMark(
                            xStart: .value("Time", marker.time),
                            xEnd: .value("Time", marker.time.addingTimeInterval(eventBarDuration)),
                            yStart: .value("Landings", 0),
                            yEnd: .value("Landings", 1)
                        )
                        .foregroundStyle(PatternEventChartColors.landing(confirmed: marker.confirmed))
                    }

                    ForEach(takeoffMarkers) { marker in
                        RectangleMark(
                            xStart: .value("Time", marker.time),
                            xEnd: .value("Time", marker.time.addingTimeInterval(eventBarDuration)),
                            yStart: .value("Takeoffs", 1),
                            yEnd: .value("Takeoffs", 2)
                        )
                        .foregroundStyle(PatternEventChartColors.takeoff(confirmed: marker.confirmed))
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var eventBarDuration: TimeInterval {
        guard samples.count >= 2 else { return 30 }
        let sorted = samples.map(\.time).sorted()
        let deltas = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }
        guard !deltas.isEmpty else { return 30 }
        let average = deltas.reduce(0, +) / Double(deltas.count)
        return min(45, max(12, average * 0.75))
    }

    private var yMax: Int {
        let peak = samples.map(\.count).max() ?? 1
        let eventBand = (landingMarkers.isEmpty && takeoffMarkers.isEmpty) ? 0 : 2
        return max(2, peak + 1, eventBand)
    }
}
