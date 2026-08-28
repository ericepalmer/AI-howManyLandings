import SwiftUI

struct SettingsView: View {
    @AppStorage(AppSettings.clientIDKey) private var clientID = ""
    @AppStorage(AppSettings.clientSecretKey) private var clientSecret = ""
    @AppStorage(AppSettings.pollIntervalKey) private var pollInterval = 10.0
    @AppStorage(AppSettings.feedSourceKey) private var feedSourceRaw = TrafficFeedSource.automatic.rawValue
    @AppStorage(AppSettings.mapStyleKey) private var mapStyleRaw = MapBasemapStyle.satellite.rawValue
    @AppStorage(AppSettings.mapOpacityKey) private var mapOpacity = 1.0
    @AppStorage(AppSettings.showAirfieldIDKey) private var showAirfieldID = true
    @AppStorage(AppSettings.trackingRadiusKey) private var trackingRadiusNM = Geo.defaultTrackingRadiusNM
    @AppStorage(AppSettings.debugTrackDumpKey) private var debugTrackDump = false
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
                    Slider(value: $trackingRadiusNM, in: 1...50, step: 1) {
                        Text("Max range")
                    } minimumValueLabel: {
                        Text("1").font(.caption2)
                    } maximumValueLabel: {
                        Text("50").font(.caption2)
                    }
                    LabeledContent("Traffic coverage", value: "\(Int(trackingRadiusNM.rounded())) NM")
                    Toggle("Show Airfield ID", isOn: $showAirfieldID)
                } header: {
                    Text("Map")
                } footer: {
                    settingsFooter(
                        "Background “None” is a blank canvas with no place names or range labels. Basemap opacity at 0% hides satellite/street imagery completely. Max range sets the traffic fetch distance and coverage ring (1–50 NM). Pattern boxes follow published left/right traffic per runway end."
                    )
                }

                Section {
                    Picker("Source", selection: $feedSourceRaw) {
                        ForEach(TrafficFeedSource.liveCases) { source in
                            Text(source.title).tag(source.rawValue)
                        }
                    }
                    .onChange(of: feedSourceRaw) { _, newValue in
                        if newValue != TrafficFeedSource.recorded.rawValue, engine.isRecordedReplayActive {
                            engine.stopRecordedReplay(restoreLiveSource: TrafficFeedSource(rawValue: newValue) ?? .automatic)
                        }
                    }
                } header: {
                    Text("Live traffic")
                } footer: {
                    settingsFooter(
                        "Automatic uses the community ADS-B network (adsb.lol). OpenSky’s API host is often unreachable and is kept as an optional source if you have credentials."
                    )
                }

                Section {
                    RecordedADSControlsView()
                } header: {
                    Text("Recorded ADS-B (debug)")
                } footer: {
                    settingsFooter(
                        "Load a saved feed to replay without live traffic. A floating palette on the map provides play, speed, and step controls. Supports adsb.lol JSON, JSONL, OpenSky snapshots, and track-dump exports. Loading clears the landing log and resets detectors."
                    )
                }

                Section {
                    TextField("Client ID", text: $clientID)
                        .textContentType(.username)
                    SecureField("Client Secret", text: $clientSecret)
                        .textContentType(.password)
                } header: {
                    Text("OpenSky Network")
                } footer: {
                    settingsFooter(
                        "Only needed if you force the OpenSky source. Create an API client at opensky-network.org (Account → API Client)."
                    )
                }

                Section {
                    Picker("Interval", selection: $pollInterval) {
                        Text("10 seconds").tag(10.0)
                        Text("15 seconds").tag(15.0)
                        Text("30 seconds").tag(30.0)
                    }
                    if let credits = engine.creditsRemaining {
                        LabeledContent("OpenSky credits left", value: "\(credits)")
                        LabeledContent("Used this session", value: "\(engine.creditsUsedThisSession)")
                    } else {
                        LabeledContent("API credits", value: "n/a")
                    }
                    if let updated = engine.lastUpdated {
                        LabeledContent("Last update", value: updated.formatted(date: .omitted, time: .standard))
                    }
                } header: {
                    Text("Polling")
                } footer: {
                    settingsFooter(
                        "Credits apply only to OpenSky. The default Live ADS-B (adsb.lol) feed has no credit balance. OpenSky reports remaining credits on each response; daily quotas are typically 400 (anonymous), 4,000 (free account), or 8,000 (active feeder)."
                    )
                }

                Section {
                    settingsBodyNote(
                        "The Pattern panel and occupancy charts list the same traffic: airborne Departure, Upwind, Crosswind, Downwind, Base, Final, and Flare within 5 NM and ≤ 2,000 ft AGL. Maneuvering, Leaving, Ground, and surface aircraft are excluded. The sidebar mini-chart shows occupancy over the last 10 minutes."
                    )
                } header: {
                    Text("Pattern tracking")
                }

                Section {
                    LabeledContent("Build", value: AppBuild.number)
                    Toggle("Click track for ADS-B dump", isOn: $debugTrackDump)
                } header: {
                    Text("Debug")
                } footer: {
                    settingsFooter(
                        "Build increments each time you compile. Match the number in the top-left of the window to confirm you are running the latest binary. When off, track dots do not capture clicks so pinch-zoom and pan work normally. When on, clicking a track point or aircraft opens the ADS-B dump sheet."
                    )
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
        .frame(minWidth: 440, idealWidth: 520, maxWidth: 640, minHeight: 480, idealHeight: 680, maxHeight: .infinity)
        #endif
    }

    private func settingsFooter(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func settingsBodyNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
