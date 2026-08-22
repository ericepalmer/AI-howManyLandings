import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.clientIDKey) private var clientID = ""
    @AppStorage(AppSettings.clientSecretKey) private var clientSecret = ""
    @AppStorage(AppSettings.pollIntervalKey) private var pollInterval = 10.0
    @AppStorage(AppSettings.feedSourceKey) private var feedSourceRaw = TrafficFeedSource.automatic.rawValue
    @AppStorage(AppSettings.mapStyleKey) private var mapStyleRaw = MapBasemapStyle.satellite.rawValue
    @AppStorage(AppSettings.mapOpacityKey) private var mapOpacity = 1.0
    @AppStorage(AppSettings.showAirfieldIDKey) private var showAirfieldID = true
    @AppStorage(AppSettings.patternDisplayKey) private var patternDisplayRaw = PatternDisplayMode.leftHand.rawValue
    @Environment(\.dismiss) private var dismiss
    @Environment(TrackingEngine.self) private var engine

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
                        LabeledContent("Basemap opacity", value: "\(Int((mapOpacity * 100).rounded()))%")
                    }
                    Toggle("Show Airfield ID", isOn: $showAirfieldID)
                    Picker("Pattern track", selection: $patternDisplayRaw) {
                        ForEach(PatternDisplayMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                } header: {
                    Text("Map")
                } footer: {
                    Text("None replaces the basemap with a dark canvas. Opacity fades satellite or street layers under the tracking overlay.")
                }

                Section {
                    Picker("Source", selection: $feedSourceRaw) {
                        ForEach(TrafficFeedSource.allCases) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }
                } header: {
                    Text("Live traffic")
                } footer: {
                    Text("Automatic uses the community ADS-B network (adsb.lol). OpenSky’s API host is often unreachable and is kept as an optional source if you have credentials.")
                }

                Section {
                    TextField("Client ID", text: $clientID)
                        .textContentType(.username)
                    SecureField("Client Secret", text: $clientSecret)
                        .textContentType(.password)
                } header: {
                    Text("OpenSky Network")
                } footer: {
                    Text("Only needed if you force the OpenSky source. Create an API client at opensky-network.org (Account → API Client).")
                }

                Section("Polling") {
                    Picker("Interval", selection: $pollInterval) {
                        Text("10 seconds").tag(10.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                    }
                    if let credits = engine.creditsRemaining {
                        LabeledContent("Credits remaining", value: "\(credits)")
                    }
                    if let updated = engine.lastUpdated {
                        LabeledContent("Last update", value: updated.formatted(date: .omitted, time: .standard))
                    }
                }

                Section("Landing detection") {
                    Text("A landing is counted when an aircraft descends through landing altitude, gets low and slow near a runway (or hovers there), then either climbs away (touch-and-go) or stays on the surface (full stop). High-speed overflights are ignored.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Takeoffs, landings, and touch-and-goes require consecutive qualifying ADS-B updates before they are logged. Full stops need stronger proof: surface contact, taxi-speed dwell, and three matching samples.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
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
    }
}
