import MapKit
import SwiftUI

struct AirportMapView: View {
    let airport: Airport
    let aircraft: [LandingDetector.TrackedAircraft]

    @AppStorage(AppSettings.mapStyleKey) private var mapStyleRaw = MapBasemapStyle.satellite.rawValue
    @AppStorage(AppSettings.mapOpacityKey) private var mapOpacity = 1.0
    @AppStorage(AppSettings.showAirfieldIDKey) private var showAirfieldID = true
    @AppStorage(AppSettings.patternDisplayKey) private var patternDisplayRaw = PatternDisplayMode.leftHand.rawValue
    @State private var position: MapCameraPosition = .automatic
    @State private var camera: MapCamera?
    @State private var inspectedICAO: String?
    @State private var didCenter = false

    var body: some View {
        Map(position: $position, interactionModes: .all) {
            if basemapStyle == .none {
                MapCircle(center: airport.coordinate, radius: 25_000_000)
                    .foregroundStyle(mapCanvasColor)
            } else {
                MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: 55))
                    .foregroundStyle(Color.black.opacity(0.58 * basemapCoverOpacity))
                MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: 55))
                    .foregroundStyle(Color(white: 0.12).opacity(0.35 * basemapCoverOpacity))
            }

            MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: Geo.innerRingNM))
                .foregroundStyle(Color.clear)
                .stroke(Color.orange.opacity(0.9), lineWidth: 1.5)

            MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: Geo.trackingRadiusNM))
                .foregroundStyle(Color.clear)
                .stroke(Color.orange.opacity(0.55), lineWidth: 1)

            Annotation("", coordinate: Geo.coordinate(from: airport.coordinate, distanceNM: Geo.innerRingNM, bearingDeg: 0)) {
                RangeLabel(text: "5 NM")
            }
            Annotation("", coordinate: Geo.coordinate(from: airport.coordinate, distanceNM: Geo.trackingRadiusNM, bearingDeg: 0)) {
                RangeLabel(text: "10 NM")
            }

            ForEach(airport.runways) { runway in
                MapPolyline(coordinates: [runway.le, runway.he])
                    .stroke(.white.opacity(0.95), lineWidth: 3.5)

                ForEach(patternSides, id: \.self) { side in
                    MapPolyline(
                        coordinates: TrafficPattern.smoothPath(
                            for: runway,
                            side: side,
                            fieldCenter: airport.coordinate
                        )
                    )
                        .stroke(
                            Color(white: 0.78).opacity(0.85),
                            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round, dash: [7, 6])
                        )
                }
            }

            if showAirfieldID {
                Annotation("", coordinate: airport.coordinate, anchor: .center) {
                    AirportMarker(icao: airport.icao)
                }
            }

            ForEach(aircraft) { ac in
                let isEnroute = TrackPalette.isEnroute(ac.snapshot, airportElevationFt: airport.elevationFt)
                let color = TrackPalette.color(for: ac.snapshot, airportElevationFt: airport.elevationFt)
                let strokeColor = isEnroute ? color.opacity(TrackPalette.enrouteTrailOpacity) : color
                let selected = inspectedICAO == ac.id
                let trackSegments = TrackSmoother.segments(from: ac.track)

                ForEach(Array(trackSegments.enumerated()), id: \.offset) { _, segment in
                    let smooth = TrackSmoother.smoothCoordinates(from: segment)
                    MapPolyline(coordinates: smooth)
                        .stroke(
                            strokeColor,
                            style: StrokeStyle(
                                lineWidth: selected ? 3.5 : (isEnroute ? TrackPalette.enrouteTrailWidth : 1.25),
                                lineCap: .round,
                                lineJoin: .round,
                                dash: isEnroute ? [8, 6] : []
                            )
                        )

                    ForEach(Array(segment.enumerated()), id: \.offset) { _, point in
                        MapCircle(center: point.coordinate, radius: 16)
                            .foregroundStyle(strokeColor.opacity(selected ? 0.95 : 0.85))
                            .stroke(Color.black.opacity(0.35), lineWidth: 0.6)
                    }
                }
                Annotation("", coordinate: ac.snapshot.coordinate, anchor: .center) {
                    AircraftMarker(
                        aircraft: ac,
                        color: color,
                        airportElevationFt: airport.elevationFt,
                        isInspected: inspectedICAO == ac.id
                    )
                    .accessibilityLabel(ac.snapshot.tailNumber)
                    .onHover { hovering in
                        handleHover(hovering, icao: ac.id)
                    }
                    .onTapGesture {
                        inspectedICAO = inspectedICAO == ac.id ? nil : ac.id
                    }
                }
            }
        }
        .background(basemapStyle == .none ? mapCanvasColor : Color.clear)
        .mapStyle(selectedMapStyle)
        .mapControls {
            MapCompass()
            MapScaleView()
            MapPitchToggle()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            camera = context.camera
        }
        .onAppear { centerIfNeeded() }
        .onChange(of: airport.icao) { _, _ in
            didCenter = false
            inspectedICAO = nil
            centerIfNeeded()
        }
        .overlay(alignment: .topLeading) {
            FeedStatusBanner()
                .padding(12)
        }
        .overlay(alignment: .topTrailing) {
            ZoomControls(
                zoomIn: { zoom(factor: 0.62) },
                zoomOut: { zoom(factor: 1.6) },
                recenter: { center(on: airport) }
            )
            .padding(12)
        }
        .overlay(alignment: .bottomLeading) {
            if let inspected = inspectedAircraft {
                AircraftInfoCard(aircraft: inspected, airport: airport)
                    .padding(12)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.15), value: inspectedICAO)
    }

    private var basemapStyle: MapBasemapStyle {
        MapBasemapStyle(rawValue: mapStyleRaw) ?? .satellite
    }

    private var patternDisplay: PatternDisplayMode {
        PatternDisplayMode(rawValue: patternDisplayRaw) ?? .leftHand
    }

    private var patternSides: [TrafficPattern.Side] {
        switch patternDisplay {
        case .none: return []
        case .leftHand: return [.left]
        case .rightHand: return [.right]
        case .both: return [.left, .right]
        }
    }

    private var mapCanvasColor: Color {
        Color(red: 0.08, green: 0.085, blue: 0.095)
    }

    /// 0 = basemap fully visible, 1 = basemap hidden under the dark overlay.
    private var basemapCoverOpacity: Double {
        switch basemapStyle {
        case .none:
            return 1.0
        case .satellite, .street:
            return 0.12 + (1.0 - mapOpacity) * 0.88
        }
    }

    private var selectedMapStyle: MapStyle {
        switch basemapStyle {
        case .none:
            return .standard(emphasis: .muted)
        case .satellite:
            return .imagery(elevation: .flat)
        case .street:
            return .standard(emphasis: .automatic)
        }
    }

    private var inspectedAircraft: LandingDetector.TrackedAircraft? {
        aircraft.first { $0.id == inspectedICAO }
    }

    private func handleHover(_ hovering: Bool, icao: String) {
        if hovering {
            inspectedICAO = icao
        } else if inspectedICAO == icao {
            inspectedICAO = nil
        }
    }

    private func centerIfNeeded() {
        guard !didCenter else { return }
        center(on: airport)
        didCenter = true
    }

    private func center(on airport: Airport) {
        let span = MKCoordinateSpan(latitudeDelta: 0.32, longitudeDelta: 0.32)
        position = .region(MKCoordinateRegion(center: airport.coordinate, span: span))
    }

    private func zoom(factor: Double) {
        let current = camera ?? MapCamera(centerCoordinate: airport.coordinate, distance: 45_000)
        let distance = min(max(current.distance * factor, 700), 220_000)
        position = .camera(
            MapCamera(
                centerCoordinate: current.centerCoordinate,
                distance: distance,
                heading: current.heading,
                pitch: current.pitch
            )
        )
    }
}

private struct RangeLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption2.weight(.bold).monospaced())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial, in: Capsule())
    }
}

private struct ZoomControls: View {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let recenter: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            controlButton("plus.magnifyingglass", action: zoomIn)
            controlButton("minus.magnifyingglass", action: zoomOut)
            controlButton("location.north.circle", action: recenter)
        }
        .padding(6)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func controlButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .help(systemName == "plus.magnifyingglass" ? "Zoom in" : systemName == "minus.magnifyingglass" ? "Zoom out" : "Center on airport")
    }
}

private struct AirportMarker: View {
    let icao: String

    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "building.2.fill")
                .font(.caption)
            Text(icao)
                .font(.caption2.weight(.bold).monospaced())
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AircraftMarker: View {
    let aircraft: LandingDetector.TrackedAircraft
    let color: Color
    let airportElevationFt: Int
    let isInspected: Bool

    var body: some View {
        let snapshot = aircraft.snapshot
        let isHigh = TrackPalette.isEnroute(snapshot, airportElevationFt: airportElevationFt)
        let heading = snapshot.trackDeg ?? 0
        let symbolColor = isHigh ? TrackPalette.enroute : color
        VStack(spacing: 2) {
            if isHigh {
                Image(systemName: "location.north.fill")
                    .font(.system(size: isInspected ? 16 : 14, weight: .bold))
                    .foregroundStyle(symbolColor)
                    .rotationEffect(.degrees(heading))
                    .shadow(color: symbolColor.opacity(0.45), radius: isInspected ? 4 : 1)
            } else {
                AircraftGlyph(
                    kind: AircraftSymbolKind.from(category: snapshot.category, typeCode: snapshot.typeCode),
                    color: color,
                    heading: heading,
                    isInspected: isInspected
                )
            }
            Text(snapshot.tailNumber)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(symbolColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(4)
        .background(isInspected ? symbolColor.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

private struct AircraftInfoCard: View {
    let aircraft: LandingDetector.TrackedAircraft
    let airport: Airport

    private var snapshot: AircraftSnapshot { aircraft.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.tailNumber)
                    .font(.headline.monospaced())
                Spacer()
                Text(snapshot.onGround ? "On ground" : "Airborne")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(snapshot.onGround ? TrackPalette.ground : TrackPalette.color(for: snapshot, airportElevationFt: airport.elevationFt))
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                info("Type", snapshot.typeDisplay)
                if let callsign = snapshot.callsign, callsign != snapshot.tailNumber {
                    info("Callsign", callsign)
                }
                if let registration = snapshot.registration, registration != snapshot.tailNumber {
                    info("Registration", registration)
                }
                info("Category", snapshot.category.displayName)
                if snapshot.onGround {
                    info("Altitude", "Surface")
                } else {
                    if let msl = snapshot.altitudeMSLFt {
                        info("Altitude", "\(format(msl)) ft MSL")
                    }
                    if let agl = snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt) {
                        info("AGL", "\(format(agl)) ft")
                    }
                }
                if let vs = snapshot.verticalRateFPM, !snapshot.onGround {
                    let sign = vs >= 0 ? "+" : ""
                    info("Vertical", "\(sign)\(format(vs)) fpm")
                }
                if let gs = snapshot.groundSpeedKt {
                    info("Groundspeed", "\(format(gs)) kt")
                }
                if let track = snapshot.trackDeg {
                    info("Track", "\(Int(track.rounded()))°")
                }
                if let squawk = snapshot.squawk {
                    info("Squawk", squawk)
                }
                if !snapshot.originCountry.isEmpty {
                    info("Origin", snapshot.originCountry)
                }
                info("From field", String(format: "%.1f NM", Geo.distanceNM(snapshot.coordinate, airport.coordinate)))
                info("ICAO24", snapshot.icao24.uppercased())
            }
        }
        .padding(12)
        .frame(width: 250, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(radius: 6)
    }

    @ViewBuilder
    private func info(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced().weight(.semibold))
        }
    }

    private func format(_ value: Double) -> String {
        abs(value) >= 100 ? String(Int(value.rounded())) : String(format: "%.0f", value)
    }
}

private struct FeedStatusBanner: View {
    @Environment(TrackingEngine.self) private var engine

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(engine.feedName)
                .font(.caption.weight(.semibold))
            if let error = engine.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
            } else {
                Text("\(engine.selectedAircraft.count) aircraft · 5 / 10 NM rings")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let updated = engine.lastUpdated {
                Text("Updated \(updated.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Button("Refresh") {
                engine.refreshNow()
            }
            .font(.caption.weight(.semibold))
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
