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

    /// ~18 hours visible in the chart viewport (hourly ticks, zoomed in).
    private let visibleWindow: TimeInterval = 18 * PatternHourlyStats.hourInterval
    private let hourWidth: CGFloat = 44

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
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hourly average aircraft in pattern")
                            .font(.subheadline.weight(.semibold))
                        occupancyHourlyChart
                            .frame(width: chartContentWidth, height: 150)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Hourly landings")
                            .font(.subheadline.weight(.semibold))
                        landingsHourlyChart
                            .frame(width: chartContentWidth, height: 130)
                    }
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

    private var occupancyHourlyChart: some View {
        Chart {
            midnightRuleMarks()
            ForEach(hourlySeries) { bucket in
                LineMark(
                    x: .value("Hour", bucket.hourStart),
                    y: .value("Aircraft", bucket.averageOccupancy)
                )
                .foregroundStyle(Color.accentColor)
                .interpolationMethod(.monotone)
            }
        }
        .chartYAxisLabel("Aircraft")
        .chartXScale(domain: fullXDomain)
        .chartXAxis {
            hourlyDateAxisMarks()
        }
    }

    private var landingsHourlyChart: some View {
        Chart {
            midnightRuleMarks()
            ForEach(hourlySeries) { bucket in
                BarMark(
                    x: .value("Hour", bucket.hourStart),
                    y: .value("Landings", bucket.landingCount)
                )
                .foregroundStyle(PatternEventChartColors.landing(confirmed: true))
            }
        }
        .chartYAxisLabel("Landings")
        .chartXScale(domain: fullXDomain)
        .chartXAxis {
            hourlyDateAxisMarks()
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
