import Charts
import SwiftUI

/// Time series of how many aircraft are in the pattern (≤ 2,000 ft AGL, ≤ 5 NM).
struct PatternOccupancyWindow: View {
    let airportICAO: String
    @Environment(TrackingEngine.self) private var engine

    private let viewportDuration = PatternOccupancy.defaultChartWindow
    private let fullHistoryWindow = PatternOccupancy.fullChartWindow

    private var chartEnd: Date { engine.simulationNow }

    private var fullXStart: Date {
        chartEnd.addingTimeInterval(-fullHistoryWindow)
    }

    private var xDomain: ClosedRange<Date> {
        fullXStart...chartEnd
    }

    private var historySamples: [PatternOccupancySample] {
        PatternOccupancy.recentSamples(
            engine.patternOccupancyHistory(for: airportICAO),
            now: chartEnd,
            window: fullHistoryWindow
        )
    }

    private var landingMarkers: [PatternLandingMarker] {
        markersInWindow(engine.patternLandingMarkers(for: airportICAO))
    }

    private var takeoffMarkers: [PatternTakeoffMarker] {
        markersInWindow(engine.patternTakeoffMarkers(for: airportICAO))
    }

    private var feedGaps: [PatternFeedGap] {
        var gaps = engine.patternFeedGaps(for: airportICAO)
        let threshold = PatternOccupancy.feedGapThreshold(
            pollInterval: AppSettings.pollIntervalSeconds
        )
        if let last = historySamples.last {
            let elapsed = chartEnd.timeIntervalSince(last.time)
            if elapsed > threshold {
                gaps.append(PatternFeedGap(start: last.time, end: chartEnd))
            }
        }
        return gaps
    }

    private var visibleGaps: [PatternFeedGap] {
        PatternOccupancy.gapsInRange(feedGaps, from: fullXStart, to: chartEnd)
    }

    private var sampleSegments: [[PatternOccupancySample]] {
        PatternOccupancy.contiguousSampleSegments(samples: historySamples, gaps: feedGaps)
    }

    var body: some View {
        NavigationStack {
            Group {
                if historySamples.count < 2 {
                    ContentUnavailableView(
                        "Collecting pattern data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Counts update each ADS-B poll. Scroll horizontally to view up to 4 hours of history.")
                    )
                } else {
                    scrollableChart
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Pattern · \(airportICAO)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Text("20 min · scroll for 4 hr")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
    }

    private var scrollableChart: some View {
        GeometryReader { geometry in
            let viewportWidth = max(geometry.size.width, 320)
            let contentWidth = viewportWidth * CGFloat(fullHistoryWindow / viewportDuration)

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: true) {
                    occupancyChart
                        .frame(width: contentWidth, height: geometry.size.height)
                        .id("occupancyChart")
                }
                .onAppear {
                    scrollToLiveEdge(proxy)
                }
                #if os(macOS)
                .overlay(alignment: .bottomTrailing) {
                    Button("Now") {
                        scrollToLiveEdge(proxy)
                    }
                    .buttonStyle(.borderless)
                    .font(.caption2)
                    .padding(4)
                }
                #endif
            }
        }
    }

    private var occupancyChart: some View {
        Chart {
            ForEach(visibleGaps) { gap in
                RectangleMark(
                    xStart: .value("Time", gap.start),
                    xEnd: .value("Time", gap.end),
                    yStart: .value("Aircraft", 0),
                    yEnd: .value("Aircraft", Double(yMax))
                )
                .foregroundStyle(Color.secondary.opacity(0.16))
            }

            ForEach(Array(sampleSegments.enumerated()), id: \.offset) { _, segment in
                ForEach(segment) { sample in
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

            ForEach(landingMarkers) { marker in
                RectangleMark(
                    xStart: .value("Time", marker.time),
                    xEnd: .value("Time", marker.time.addingTimeInterval(eventBarDuration)),
                    yStart: .value("Landings", 0),
                    yEnd: .value("Landings", 1)
                )
                .foregroundStyle(PatternEventChartColors.landing(confirmed: marker.confirmed))

                PointMark(
                    x: .value("Time", marker.time.addingTimeInterval(eventBarDuration * 0.5)),
                    y: .value("Landings", eventLabelY)
                )
                .opacity(0)
                .annotation(position: .overlay, alignment: .bottom) {
                    PatternEventAxisLabel(text: marker.label)
                }
            }

            ForEach(takeoffMarkers) { marker in
                RectangleMark(
                    xStart: .value("Time", marker.time),
                    xEnd: .value("Time", marker.time.addingTimeInterval(eventBarDuration)),
                    yStart: .value("Takeoffs", 1),
                    yEnd: .value("Takeoffs", 2)
                )
                .foregroundStyle(PatternEventChartColors.takeoff(confirmed: marker.confirmed))

                PointMark(
                    x: .value("Time", marker.time.addingTimeInterval(eventBarDuration * 0.5)),
                    y: .value("Takeoffs", 1 + eventLabelY)
                )
                .opacity(0)
                .annotation(position: .overlay, alignment: .bottom) {
                    PatternEventAxisLabel(text: marker.label)
                }
            }
        }
        .chartYScale(domain: 0...yMax)
        .chartXScale(domain: xDomain)
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
            AxisMarks(values: .automatic(desiredCount: axisMarkCount)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
    }

    private var axisMarkCount: Int {
        let minutes = viewportDuration / 60
        if minutes <= 10 { return 5 }
        if minutes <= 60 { return 6 }
        return 8
    }

    private func scrollToLiveEdge(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("occupancyChart", anchor: .trailing)
        }
    }

    private func markersInWindow(_ markers: [PatternLandingMarker]) -> [PatternLandingMarker] {
        markers.filter { $0.time >= fullXStart }
    }

    private func markersInWindow(_ markers: [PatternTakeoffMarker]) -> [PatternTakeoffMarker] {
        markers.filter { $0.time >= fullXStart }
    }

    private var eventBarDuration: TimeInterval {
        guard historySamples.count >= 2 else { return 45 }
        let sorted = historySamples.map(\.time).sorted()
        let deltas = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }
        guard !deltas.isEmpty else { return 45 }
        let average = deltas.reduce(0, +) / Double(deltas.count)
        return min(90, max(20, average * 0.75))
    }

    /// Y offset within each 1-unit event band (padding above the band floor).
    private var eventLabelY: Double { 0.14 }

    private var yMax: Int {
        let peak = historySamples.map(\.count).max() ?? 1
        let eventBand = (landingMarkers.isEmpty && takeoffMarkers.isEmpty) ? 0 : 2
        return max(3, peak + 1, eventBand)
    }
}

/// Vertical callsign/tail anchored just above the floor of its event band; grows upward.
private struct PatternEventAxisLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold, design: .monospaced))
            .foregroundStyle(.white)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .rotationEffect(.degrees(-90), anchor: .bottom)
    }
}
