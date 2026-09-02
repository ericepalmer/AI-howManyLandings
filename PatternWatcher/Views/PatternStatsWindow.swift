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

    private var peakLandingsPerHour: Int? {
        guard hasHourlyData else { return nil }
        return hourlySeries.map(\.landingCount).max()
    }

    /// ~18 hours visible in the chart viewport (hourly ticks, zoomed in).
    private let visibleWindow: TimeInterval = 18 * PatternHourlyStats.hourInterval
    private let hourWidth: CGFloat = 44
    /// Hour slot used for bar width; 10% total gap between adjacent bars.
    private let hourlyBarWidthFraction = 0.9
    private let statsOccupancyBarColor = Color.accentColor
    private let statsLandingBarColor = Color(red: 0.52, green: 0.72, blue: 0.95)
    private let yAxisColumnWidth: CGFloat = 44
    private let occupancyPlotHeight: CGFloat = 168
    private let landingsPlotHeight: CGFloat = 148

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
                        ("Last hour", formatOptionalInt(snapshot.landingsLastHour)),
                        ("Last 24 hours", formatOptionalInt(snapshot.landingsLast24Hours)),
                        ("Peak per hour", formatOptionalInt(peakLandingsPerHour))
                    ]
                )
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
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Hourly average aircraft in pattern")
                        .font(.subheadline.weight(.semibold))
                        .opacity(0)
                        .accessibilityHidden(true)

                    hourlyYAxisChart(kind: .occupancy)
                        .frame(width: yAxisColumnWidth, height: occupancyPlotHeight)

                    landingsHeaderBlock
                        .opacity(0)
                        .accessibilityHidden(true)

                    hourlyYAxisChart(kind: .landings)
                        .frame(width: yAxisColumnWidth, height: landingsPlotHeight)
                }
                .frame(width: yAxisColumnWidth)

                ScrollView(.horizontal, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Hourly average aircraft in pattern")
                            .font(.subheadline.weight(.semibold))

                        hourlyPlotChart(kind: .occupancy)
                            .frame(width: chartContentWidth, height: occupancyPlotHeight)

                        landingsHeaderBlock

                        hourlyPlotChart(kind: .landings)
                            .frame(width: chartContentWidth, height: landingsPlotHeight)
                    }
                    .id("hourlyCharts")
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
            .onAppear {
                scrollToLiveEdge(proxy)
            }
        }
    }

    private var landingsHeaderBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hourly landings")
                .font(.subheadline.weight(.semibold))
            if let peak = peakLandingsPerHour {
                Text("Peak \(peak) per hour")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 4)
    }

    private enum HourlyChartKind {
        case occupancy
        case landings
    }

  /// Fixed column: Y scale only (stays visible while the plot scrolls).
    private func hourlyYAxisChart(kind: HourlyChartKind) -> some View {
        Chart {
            RuleMark(y: .value("Count", 0))
                .opacity(0)
        }
        .chartYScale(domain: yDomain(for: kind))
        .chartXScale(domain: fullXDomain)
        .chartYAxisLabel(kind == .occupancy ? "Aircraft" : "Landings")
        .chartYAxis {
            AxisMarks(position: .leading, values: yAxisTickValues(for: kind)) { value in
                AxisGridLine()
                    .foregroundStyle(.clear)
                AxisValueLabel {
                    if kind == .occupancy, let amount = value.as(Double.self) {
                        Text(formatAverage(amount))
                            .font(.caption2.monospacedDigit())
                    } else if let count = value.as(Int.self) {
                        Text("\(count)")
                            .font(.caption2.monospacedDigit())
                    }
                }
            }
        }
        .chartXAxis {
            switch kind {
            case .occupancy:
                hourlyGridAxisMarks(hidden: true)
            case .landings:
                hourlyDateAxisMarks(hidden: true)
            }
        }
    }

    private func hourlyPlotChart(kind: HourlyChartKind) -> some View {
        Chart {
            yReferenceRuleMarks(for: kind)
            midnightRuleMarks()
            ForEach(hourlySeries) { bucket in
                switch kind {
                case .occupancy:
                    if bucket.occupancySampleCount > 0 {
                        hourlyBarMark(
                            hourStart: bucket.hourStart,
                            value: bucket.averageOccupancy,
                            color: statsOccupancyBarColor,
                            label: formatAverage(bucket.averageOccupancy)
                        )
                    }
                case .landings:
                    if bucket.occupancySampleCount > 0 || bucket.landingCount > 0 {
                        hourlyBarMark(
                            hourStart: bucket.hourStart,
                            value: Double(bucket.landingCount),
                            color: statsLandingBarColor,
                            label: "\(bucket.landingCount)"
                        )
                    }
                }
            }
        }
        .chartYScale(domain: yDomain(for: kind))
        .chartXScale(domain: fullXDomain)
        .chartYAxis(.hidden)
        .chartXAxis {
            if kind == .occupancy {
                hourlyGridAxisMarks()
            } else {
                hourlyDateAxisMarks()
            }
        }
    }

    private func yDomain(for kind: HourlyChartKind) -> ClosedRange<Double> {
        let ticks = yAxisTickValues(for: kind)
        let top = ticks.last ?? 1
        return 0...top
    }

    private func yAxisTickValues(for kind: HourlyChartKind) -> [Double] {
        let peak: Double
        switch kind {
        case .occupancy:
            peak = hourlySeries
                .filter { $0.occupancySampleCount > 0 }
                .map(\.averageOccupancy)
                .max() ?? 0
        case .landings:
            peak = Double(hourlySeries.map(\.landingCount).max() ?? 0)
        }
        let top = max(1, ceil(peak))
        let step = majorYAxisStep(for: top)
        let alignedTop = ceil(top / step) * step
        var values: [Double] = []
        var value = 0.0
        while value <= alignedTop {
            values.append(value)
            value += step
        }
        return values
    }

  /// Step size for Y ticks and horizontal reference lines (major intervals).
    private func majorYAxisStep(for top: Double) -> Double {
        let maxValue = Int(top)
        if maxValue <= 5 { return 1 }
        if maxValue <= 10 { return 2 }
        if maxValue <= 20 { return 5 }
        if maxValue <= 50 { return 10 }
        return Double(((maxValue + 9) / 10) * 10 / 5)
    }

    @ChartContentBuilder
    private func yReferenceRuleMarks(for kind: HourlyChartKind) -> some ChartContent {
        ForEach(yAxisTickValues(for: kind), id: \.self) { level in
            RuleMark(y: .value("Count", level))
                .foregroundStyle(
                    level == 0
                        ? Color.secondary.opacity(0.28)
                        : Color.secondary.opacity(0.14)
                )
                .lineStyle(StrokeStyle(lineWidth: level == 0 ? 1 : 0.5))
        }
    }

    private func hourlyBarCenter(for hourStart: Date) -> Date {
        hourStart.addingTimeInterval(PatternHourlyStats.hourInterval / 2)
    }

    @ChartContentBuilder
    private func hourlyBarMark(
        hourStart: Date,
        value: Double,
        color: Color,
        label: String
    ) -> some ChartContent {
        let hour = PatternHourlyStats.hourInterval
        let inset = hour * (1 - hourlyBarWidthFraction) / 2
        let barStart = hourStart.addingTimeInterval(inset)
        let barEnd = hourStart.addingTimeInterval(hour - inset)
        let barCenter = hourlyBarCenter(for: hourStart)
        RectangleMark(
            xStart: .value("Hour", barStart),
            xEnd: .value("Hour", barEnd),
            yStart: .value("Count", 0),
            yEnd: .value("Count", value)
        )
        .foregroundStyle(color)
        .cornerRadius(2)
        PointMark(
            x: .value("Hour", barCenter),
            y: .value("Count", value)
        )
        .symbolSize(0)
        .annotation(position: .top, spacing: 2) {
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .fixedSize()
        }
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
    private func hourlyGridAxisMarks(hidden: Bool = false) -> some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 1)) { value in
            if let date = value.as(Date.self), Calendar.current.component(.hour, from: date) == 0 {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1.2))
                    .foregroundStyle(hidden ? .clear : Color.primary.opacity(0.28))
            } else {
                AxisGridLine()
                    .foregroundStyle(hidden ? .clear : Color.secondary.opacity(0.22))
            }
        }
    }

    @AxisContentBuilder
    private func hourlyDateAxisMarks(hidden: Bool = false) -> some AxisContent {
        AxisMarks(values: .stride(by: .hour, count: 1)) { value in
            if let date = value.as(Date.self), Calendar.current.component(.hour, from: date) == 0 {
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1.2))
                    .foregroundStyle(hidden ? .clear : Color.primary.opacity(0.28))
                AxisValueLabel(centered: true) {
                    Text(date, format: .dateTime.day().month(.abbreviated))
                        .font(.caption2.weight(.semibold))
                        .opacity(hidden ? 0 : 1)
                }
            } else {
                AxisGridLine()
                    .foregroundStyle(hidden ? .clear : Color.secondary.opacity(0.22))
                AxisValueLabel(centered: true) {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour(.defaultDigits(amPM: .abbreviated)))
                            .font(.caption2)
                            .opacity(hidden ? 0 : 1)
                    }
                }
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
