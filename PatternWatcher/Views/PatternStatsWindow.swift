import Charts
import SwiftUI

/// Pattern occupancy and landing statistics (hourly history up to 7 days).
struct PatternStatsWindow: View {
    let airportICAO: String
    @Environment(TrackingEngine.self) private var engine

    @State private var occupancySelectedHour: Date?
    @State private var landingsSelectedHour: Date?

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

    /// ~18 hours visible in the chart viewport (hourly ticks, zoomed in).
    private let visibleWindow: TimeInterval = 18 * PatternHourlyStats.hourInterval
    private let hourWidth: CGFloat = 44
    /// Hour slot used for bar width; 10% total gap between adjacent bars.
    private let hourlyBarWidthFraction = 0.9
    private let statsOccupancyBarColor = Color.accentColor
    private let statsLandingBarColor = Color(red: 0.52, green: 0.72, blue: 0.95)

    private var fullXDomain: ClosedRange<Date> {
        guard let first = hourlySeries.first?.hourStart else {
            let start = now.addingTimeInterval(-visibleWindow)
            return start...now
        }
        return first...now
    }

    private var chartContentWidth: CGFloat {
        CGFloat(max(hourlySeries.count, 1)) * hourWidth
    }

    private var midnightDates: [Date] {
        let calendar = Calendar.current
        let start = fullXDomain.lowerBound
        let end = fullXDomain.upperBound
        var day = calendar.startOfDay(for: start)
        if day < start {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { return [] }
            day = next
        }
        var dates: [Date] = []
        while day <= end {
            dates.append(day)
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return dates
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
                        ("Last 5 minutes", formatOptionalAverage(snapshot.avgLast5Min)),
                        ("Last 30 minutes", formatOptionalAverage(snapshot.avgLast30Min)),
                        ("Last hour", formatOptionalAverage(snapshot.avgLastHour)),
                        ("Last 24 hours", formatOptionalAverage(snapshot.avgLast24Hours)),
                        ("Peak", formatOptionalInt(snapshot.peakOccupancy))
                    ]
                )

                statsSection(
                    title: "Number of landings",
                    rows: [
                        ("Last 5 minutes", formatOptionalInt(snapshot.landingsLast5Min)),
                        ("Last 30 minutes", formatOptionalInt(snapshot.landingsLast30Min)),
                        ("Last hour", formatOptionalInt(snapshot.landingsLastHour))
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
                        hourlyHistoryCharts
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

    private var hourlyHistoryCharts: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hourly average aircraft in pattern")
                        .font(.subheadline.weight(.semibold))

                    hourlyChart(kind: .occupancy, selectedHour: $occupancySelectedHour)
                        .frame(width: chartContentWidth, height: 140)

                    Text("Hourly landings")
                        .font(.subheadline.weight(.semibold))
                        .padding(.top, 4)

                    hourlyChart(kind: .landings, selectedHour: $landingsSelectedHour)
                        .frame(width: chartContentWidth, height: 120)
                }
                .id("hourlyCharts")
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

    private enum HourlyChartKind {
        case occupancy
        case landings
    }

    private func hourlyChart(kind: HourlyChartKind, selectedHour: Binding<Date?>) -> some View {
        Chart {
            midnightRuleMarks()
            if let hourStart = selectedHour.wrappedValue {
                RuleMark(x: .value("Selected", hourlyBarCenter(for: hourStart)))
                    .foregroundStyle(Color.primary.opacity(0.22))
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(hourlySeries) { bucket in
                switch kind {
                case .occupancy:
                    if bucket.occupancySampleCount > 0 {
                        hourlyBarMark(
                            hourStart: bucket.hourStart,
                            value: bucket.averageOccupancy,
                            color: statsOccupancyBarColor
                        )
                    }
                case .landings:
                    if bucket.occupancySampleCount > 0 || bucket.landingCount > 0 {
                        hourlyBarMark(
                            hourStart: bucket.hourStart,
                            value: Double(bucket.landingCount),
                            color: statsLandingBarColor
                        )
                    }
                }
            }
        }
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxisLabel(kind == .occupancy ? "Aircraft" : "Landings")
        .chartXScale(domain: fullXDomain)
        .chartXAxis {
            if kind == .occupancy {
                hourlyGridAxisMarks()
            } else {
                hourlyDateAxisMarks()
            }
        }
        .chartOverlay { proxy in
            hourlySelectionOverlay(proxy: proxy, kind: kind, selectedHour: selectedHour)
        }
    }

    private func hourlyBarCenter(for hourStart: Date) -> Date {
        hourStart.addingTimeInterval(PatternHourlyStats.hourInterval / 2)
    }

    @ChartContentBuilder
    private func hourlyBarMark(hourStart: Date, value: Double, color: Color) -> some ChartContent {
        let hour = PatternHourlyStats.hourInterval
        let inset = hour * (1 - hourlyBarWidthFraction) / 2
        let barStart = hourStart.addingTimeInterval(inset)
        let barEnd = hourStart.addingTimeInterval(hour - inset)
        RectangleMark(
            xStart: .value("Hour", barStart),
            xEnd: .value("Hour", barEnd),
            yStart: .value("Count", 0),
            yEnd: .value("Count", value)
        )
        .foregroundStyle(color)
        .cornerRadius(2)
    }

    private func hourlySelectionOverlay(
        proxy: ChartProxy,
        kind: HourlyChartKind,
        selectedHour: Binding<Date?>
    ) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    #if os(macOS)
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            selectedHour.wrappedValue = hourAt(
                                location: location,
                                proxy: proxy,
                                geometry: geometry
                            )
                        case .ended:
                            selectedHour.wrappedValue = nil
                        }
                    }
                    #endif
                    #if os(iOS)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if let hour = hourAt(
                                    location: value.location,
                                    proxy: proxy,
                                    geometry: geometry
                                ) {
                                    selectedHour.wrappedValue = hour
                                }
                            }
                    )
                    #endif

                if let hourStart = selectedHour.wrappedValue,
                   let bucket = bucketForHour(hourStart),
                   let plotFrame = proxy.plotFrame,
                   let xPosition = proxy.position(forX: hourlyBarCenter(for: hourStart)) {
                    let frame = geometry[plotFrame]
                    let x = frame.origin.x + xPosition
                    let clampedX = min(max(x, 56), geometry.size.width - 56)
                    hourlyTooltip(bucket: bucket, kind: kind)
                        .position(x: clampedX, y: 18)
                }
            }
        }
    }

    private func hourAt(location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> Date? {
        guard let plotFrame = proxy.plotFrame else { return nil }
        let frame = geometry[plotFrame]
        let x = location.x - frame.origin.x
        guard let date: Date = proxy.value(atX: x) else { return nil }
        return PatternHourlyStats.hourStart(for: date)
    }

    private func bucketForHour(_ date: Date) -> PatternHourlyBucket? {
        let hour = PatternHourlyStats.hourStart(for: date)
        return hourlySeries.first { $0.hourStart == hour }
    }

    private func hourlyTooltip(bucket: PatternHourlyBucket, kind: HourlyChartKind) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(bucket.hourStart, format: .dateTime.weekday(.abbreviated).day().hour(.defaultDigits(amPM: .abbreviated)))
                .font(.caption2.weight(.semibold))
            switch kind {
            case .occupancy:
                if bucket.occupancySampleCount > 0 {
                    Text(formatAverage(bucket.averageOccupancy))
                        .font(.caption.monospacedDigit().weight(.semibold))
                } else {
                    Text("—")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
            case .landings:
                Text("\(bucket.landingCount)")
                    .font(.caption.monospacedDigit().weight(.semibold))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
        )
    }

    @ChartContentBuilder
    private func midnightRuleMarks() -> some ChartContent {
        ForEach(midnightDates, id: \.self) { date in
            RuleMark(x: .value("Midnight", date))
                .foregroundStyle(Color.primary.opacity(0.28))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    @AxisContentBuilder
    private func hourlyGridAxisMarks() -> some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 1)) { value in
            if let date = value.as(Date.self), Calendar.current.component(.hour, from: date) == 0 {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1.2))
                    .foregroundStyle(Color.primary.opacity(0.28))
            } else {
                AxisGridLine()
            }
        }
    }

    @AxisContentBuilder
    private func hourlyDateAxisMarks() -> some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 1)) { value in
            if let date = value.as(Date.self), Calendar.current.component(.hour, from: date) == 0 {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1.2))
                    .foregroundStyle(Color.primary.opacity(0.28))
                AxisValueLabel(centered: true) {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption2.weight(.semibold))
                }
            } else {
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
            }
        }
    }

    private func scrollToLiveEdge(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("hourlyCharts", anchor: .trailing)
        }
    }

    private func formatOptionalAverage(_ value: Double?) -> String {
        guard let value else { return "" }
        return formatAverage(value)
    }

    private func formatOptionalInt(_ value: Int?) -> String {
        guard let value else { return "" }
        return "\(value)"
    }

    private func formatAverage(_ value: Double) -> String {
        if value == 0 { return "0" }
        if abs(value - Double(Int(value.rounded()))) < 0.05 {
            return "\(Int(value.rounded()))"
        }
        return String(format: "%.1f", value)
    }
}
