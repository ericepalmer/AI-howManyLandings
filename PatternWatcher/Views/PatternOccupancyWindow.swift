import Charts
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Time series of how many aircraft are in the pattern (≤ 2,000 ft AGL, ≤ 5 NM).
struct PatternOccupancyWindow: View {
    let airportICAO: String
    @Environment(TrackingEngine.self) private var engine
    @State private var windowDuration: TimeInterval = PatternOccupancy.defaultChartWindow
    @State private var magnificationAnchor: TimeInterval?

    private var chartEnd: Date { engine.simulationNow }

    private var visibleStart: Date {
        chartEnd.addingTimeInterval(-windowDuration)
    }

    private var xDomain: ClosedRange<Date> {
        visibleStart...chartEnd
    }

    private var historySamples: [PatternOccupancySample] {
        PatternOccupancy.recentSamples(
            engine.patternOccupancyHistory(for: airportICAO),
            now: chartEnd,
            window: PatternOccupancy.fullChartWindow
        )
    }

    private var samples: [PatternOccupancySample] {
        historySamples.filter { $0.time >= visibleStart }
    }

    private var landingMarkers: [PatternLandingMarker] {
        markersInWindow(engine.patternLandingMarkers(for: airportICAO))
    }

    private var takeoffMarkers: [PatternTakeoffMarker] {
        markersInWindow(engine.patternTakeoffMarkers(for: airportICAO))
    }

    var body: some View {
        NavigationStack {
            Group {
                if historySamples.count < 2 {
                    ContentUnavailableView(
                        "Collecting pattern data",
                        systemImage: "chart.xyaxis.line",
                        description: Text("Counts update each ADS-B poll. Drag or scroll on the chart to zoom the time axis (5 min–4 hr).")
                    )
                } else {
                    chart
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
                    Text(windowRangeLabel)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                ToolbarItemGroup(placement: .automatic) {
                    Button {
                        zoomIn()
                    } label: {
                        Label("Zoom in", systemImage: "plus.magnifyingglass")
                    }
                    .help("Show a shorter time range (down to 5 minutes)")

                    Button {
                        zoomOut()
                    } label: {
                        Label("Zoom out", systemImage: "minus.magnifyingglass")
                    }
                    .help("Show a longer time range (up to 4 hours)")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 420)
        #endif
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
        .gesture(
            MagnificationGesture()
                .onChanged { scale in
                    if magnificationAnchor == nil {
                        magnificationAnchor = windowDuration
                    }
                    let base = magnificationAnchor ?? windowDuration
                    windowDuration = clampDuration(base / scale)
                }
                .onEnded { _ in
                    magnificationAnchor = nil
                }
        )
        #if os(macOS)
        .overlay {
            ChartScrollZoomOverlay { factor in
                windowDuration = clampDuration(windowDuration * factor)
            }
        }
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var axisMarkCount: Int {
        let minutes = windowDuration / 60
        if minutes <= 10 { return 5 }
        if minutes <= 60 { return 6 }
        return 8
    }

    private var windowRangeLabel: String {
        let minutes = Int(windowDuration / 60)
        if minutes < 60 {
            return "\(minutes) min"
        }
        let hours = windowDuration / 3600
        if hours.truncatingRemainder(dividingBy: 1) == 0 {
            return "\(Int(hours)) hr"
        }
        return String(format: "%.1f hr", hours)
    }

    private func zoomIn() {
        windowDuration = clampDuration(windowDuration * 0.72)
    }

    private func zoomOut() {
        windowDuration = clampDuration(windowDuration * 1.39)
    }

    private func clampDuration(_ duration: TimeInterval) -> TimeInterval {
        min(PatternOccupancy.fullChartWindow, max(PatternOccupancy.minChartWindow, duration))
    }

    private func markersInWindow(_ markers: [PatternLandingMarker]) -> [PatternLandingMarker] {
        markers.filter { $0.time >= visibleStart }
    }

    private func markersInWindow(_ markers: [PatternTakeoffMarker]) -> [PatternTakeoffMarker] {
        markers.filter { $0.time >= visibleStart }
    }

    private var eventBarDuration: TimeInterval {
        guard samples.count >= 2 else { return 45 }
        let sorted = samples.map(\.time).sorted()
        let deltas = zip(sorted, sorted.dropFirst()).map { $1.timeIntervalSince($0) }
        guard !deltas.isEmpty else { return 45 }
        let average = deltas.reduce(0, +) / Double(deltas.count)
        return min(90, max(20, average * 0.75))
    }

    /// Y offset within each 1-unit event band (padding above the band floor).
    private var eventLabelY: Double { 0.14 }

    private var yMax: Int {
        let peak = samples.map(\.count).max() ?? 1
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

#if os(macOS)
/// Scroll wheel over the chart zooms the time axis.
private struct ChartScrollZoomOverlay: NSViewRepresentable {
    var onZoom: (Double) -> Void

    func makeNSView(context: Context) -> ScrollZoomCaptureView {
        let view = ScrollZoomCaptureView()
        view.onZoom = onZoom
        return view
    }

    func updateNSView(_ nsView: ScrollZoomCaptureView, context: Context) {
        nsView.onZoom = onZoom
    }
}

private final class ScrollZoomCaptureView: NSView {
    var onZoom: ((Double) -> Void)?

    override func scrollWheel(with event: NSEvent) {
        let delta = event.scrollingDeltaY + event.scrollingDeltaX
        guard abs(delta) > 0.01 else { return }
        // Scroll up / left: zoom in (shorter window). Scroll down / right: zoom out.
        let factor = delta > 0 ? 0.88 : 1.14
        onZoom?(factor)
    }
}
#endif
