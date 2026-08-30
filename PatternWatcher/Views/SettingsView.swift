import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.clientIDKey) private var clientID = ""
    @AppStorage(AppSettings.clientSecretKey) private var clientSecret = ""
    @AppStorage(AppSettings.pollIntervalKey) private var pollInterval = 10.0
    @AppStorage(AppSettings.feedSourceKey) private var feedSourceRaw = TrafficFeedSource.automatic.rawValue
    @AppStorage(AppSettings.mapStyleKey) private var mapStyleRaw = MapBasemapStyle.satellite.rawValue
    @AppStorage(AppSettings.mapOpacityKey) private var mapOpacity = AppSettings.defaultMapOpacity
    @AppStorage(AppSettings.showAirfieldIDKey) private var showAirfieldID = true
    @AppStorage(AppSettings.trackingRadiusKey) private var trackingRadiusNM = Geo.defaultTrackingRadiusNM
    @Environment(\.dismiss) private var dismiss
    @Environment(TrackingEngine.self) private var engine

    private var isOpenSkySource: Bool {
        feedSourceRaw == TrafficFeedSource.opensky.rawValue
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Background", selection: $mapStyleRaw) {
                        ForEach(MapBasemapStyle.allCases) { style in
                            Text(style.title).tag(style.rawValue)
                        }
                    }
                    if MapBasemapStyle(rawValue: mapStyleRaw) != .none {
                        Slider(value: $mapOpacity, in: 0...1) {
                            Text("Opacity")
                        } minimumValueLabel: {
                            Text("0%").font(.caption2)
                        } maximumValueLabel: {
                            Text("100%").font(.caption2)
                        }
                    }
                    HStack(spacing: 8) {
                        HStack(spacing: 4) {
                            Text("Max range")
                            Text("\(Int(trackingRadiusNM.rounded())) NM")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $trackingRadiusNM, in: 1...50, step: 1)
                    }
                    Toggle("Show Airfield ID", isOn: $showAirfieldID)
                } header: {
                    Text("Map")
                }

                Section {
                    Picker("Source", selection: $feedSourceRaw) {
                        Section("Live") {
                            ForEach(TrafficFeedSource.liveCases) { source in
                                Text(source.title).tag(source.rawValue)
                            }
                        }
                        Section("Recorded") {
                            Text(TrafficFeedSource.recorded.title).tag(TrafficFeedSource.recorded.rawValue)
                        }
                    }
                    .onChange(of: feedSourceRaw) { _, newValue in
                        if newValue != TrafficFeedSource.recorded.rawValue, engine.isRecordedReplayActive {
                            engine.stopRecordedReplay(
                                restoreLiveSource: TrafficFeedSource(rawValue: newValue) ?? .automatic
                            )
                        }
                    }

                    if feedSourceRaw == TrafficFeedSource.recorded.rawValue {
                        RecordedADSControlsView()
                    }
                } header: {
                    Text("Traffic")
                }

                if isOpenSkySource {
                    Section {
                        TextField("Client ID", text: $clientID)
                            .textContentType(.username)
                        SecureField("Client Secret", text: $clientSecret)
                            .textContentType(.password)
                    } header: {
                        Text("OpenSky")
                    }
                }

                Section {
                    Picker("Interval", selection: $pollInterval) {
                        Text("10 seconds").tag(10.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                    }
                    if let updated = engine.lastUpdated {
                        LabeledContent("Last update", value: updated.formatted(date: .omitted, time: .standard))
                    }
                } header: {
                    Text("Polling")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 460, maxWidth: 520, minHeight: 420, idealHeight: 520, maxHeight: .infinity)
        #endif
    }
}
