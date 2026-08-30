import SwiftUI

/// Centered card while an airfield is waiting for its first successful live snapshot.
struct ConnectionOverlay: View {
    let airport: Airport
    @Environment(TrackingEngine.self) private var engine

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .padding(.top, 4)

            Text(headline)
                .font(.headline)
                .multilineTextAlignment(.center)

            Text(airport.icao)
                .font(.title3.monospaced().weight(.bold))

            if !airport.name.isEmpty, airport.name != airport.icao {
                Text(airport.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: 6) {
                infoRow("Feed", AppSettings.feedSource.title)
                infoRow("Coverage", "\(Int(AppSettings.trackingRadiusNM.rounded())) NM")
                infoRow("Poll", "\(Int(AppSettings.pollIntervalSeconds)) s")
                if let error = engine.lastError, !engine.hasLiveFeed(for: airport.icao) {
                    infoRow("Status", error)
                } else {
                    infoRow("Status", detailStatus)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
        }
        .padding(22)
        .frame(width: 320)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(headline). \(airport.icao). \(detailStatus)")
    }

    private var headline: String {
        if engine.lastError != nil, !engine.hasLiveFeed(for: airport.icao) {
            return "Waiting to reconnect"
        }
        return "Connecting to live traffic"
    }

    private var detailStatus: String {
        if engine.isPollInProgress {
            return "Contacting \(AppSettings.feedSource.title)…"
        }
        if engine.lastError != nil {
            return "Retrying…"
        }
        return engine.statusText
    }

    @ViewBuilder
    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(label == "Status" && engine.lastError != nil ? Color.red : Color.primary)
                .textSelection(.enabled)
        }
    }
}
