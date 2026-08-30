import SwiftUI

/// Mini chart, optional replay controls, and supplementary window shortcuts (right panel footer).
struct PatternAccessoryPanel: View {
    let airportICAO: String
    var onShowOccupancy: () -> Void
    var onShowStats: () -> Void
    var onShowMETAR: () -> Void
    var onShowADS: () -> Void
    @Environment(TrackingEngine.self) private var engine
    @Environment(OpenAirportCoordinator.self) private var coordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if coordinator.showMiniPatternPlot {
                PatternOccupancyMiniChart(airportICAO: airportICAO)
                    .frame(height: 72)
                    .padding(8)
                    .background(panelBoxBackground, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.08))
                    }
                    .overlay(alignment: .topTrailing) {
                        Button {
                            coordinator.setShowMiniPatternPlot(false)
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.secondary, Color.primary.opacity(0.06))
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .padding(4)
                        .help("Hide mini plot")
                    }
            }

            if engine.isRecordedReplayActive {
                ReplayPaletteView()
            }

            HStack(spacing: 6) {
                Button("Plot", action: onShowOccupancy)
                    .frame(maxWidth: .infinity)
                Button("Stats", action: onShowStats)
                    .frame(maxWidth: .infinity)
                Button("METAR", action: onShowMETAR)
                    .frame(maxWidth: .infinity)
                Button("Display ADS", action: onShowADS)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            #if os(macOS)
            Button("Save log…") {
                Task {
                    await PatternLogSaveService.save(
                        coordinator: coordinator,
                        engine: engine,
                        focusedAirportICAO: airportICAO
                    )
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .frame(maxWidth: .infinity)
            #endif
        }
        .frame(maxWidth: .infinity)
    }

    private var panelBoxBackground: some ShapeStyle {
        Color.primary.opacity(0.04)
    }
}
