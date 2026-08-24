import MapKit
import SwiftUI

struct HighlightedSavedTrack: Identifiable {
    let id: UUID
    let label: String
    let points: [TrackPoint]
    let color: Color
    var icao24: String = ""
    var kindTitle: String = ""
    var eventTimestamp: Date?
    var airportICAO: String = ""
    /// Selected log rows use full color; recent unselected landings stay faint.
    var isEmphasized: Bool = true
}

struct AirportMapView: View {
    let airport: Airport
    let aircraft: [LandingDetector.TrackedAircraft]
    /// Active landing direction (`12`); parallels share one label.
    var activeRunwayDirection: String? = nil
    var highlightedTracks: [HighlightedSavedTrack] = []
    /// Mode-S IDs whose log rows are currently selected.
    var selectedICAO24s: Set<String> = []
    var selectedTrackerICAO24: String? = nil
    var onSelectAircraft: ((String) -> Void)? = nil
    var externalTrackDump: Binding<TrackDumpPayload?>? = nil

    @AppStorage(AppSettings.mapStyleKey) private var mapStyleRaw = MapBasemapStyle.satellite.rawValue
    @AppStorage(AppSettings.mapOpacityKey) private var mapOpacity = 1.0
    @AppStorage(AppSettings.showAirfieldIDKey) private var showAirfieldID = true
    @AppStorage(AppSettings.trackingRadiusKey) private var trackingRadiusNM = Geo.defaultTrackingRadiusNM
    @AppStorage(AppSettings.debugTrackDumpKey) private var debugTrackDump = false
    @State private var position: MapCameraPosition = .automatic
    @State private var camera: MapCamera?
    @State private var inspectedICAO: String?
    @State private var didCenter = false
    @State private var localTrackDump: TrackDumpPayload?

    private var showingSavedTrack: Bool { highlightedTracks.contains(where: \.isEmphasized) }

    private var landingFocusICAOs: Set<String> {
        Set(highlightedTracks.filter(\.isEmphasized).map(\.icao24).filter { !$0.isEmpty })
    }

    /// Round-cap zero-length dashes render as dots across ADS-B gaps.
    private static let missingADSBDash: [CGFloat] = [0.01, 5]

    private var mapAircraft: [LandingDetector.TrackedAircraft] {
        let visible = aircraft.filter(\.isVisibleOnMap)
        if showingSavedTrack {
            return visible.filter { landingFocusICAOs.contains($0.id) }
        }
        return visible
    }

    private var highlightBannerText: String {
        let labels = highlightedTracks.filter(\.isEmphasized).map(\.label)
        if labels.isEmpty { return "Saved track" }
        if labels.count == 1 { return "Saved track · \(labels[0])" }
        let tails = Array(Set(highlightedTracks.filter(\.isEmphasized).map { $0.label.split(separator: " · ").first.map(String.init) ?? $0.label })).sorted()
        if tails.count == 1 {
            return "Saved tracks · \(tails[0]) · \(labels.count) events"
        }
        return "Saved tracks · \(tails.joined(separator: ", "))"
    }

    var body: some View {
        Map(position: $position, interactionModes: .all) {
            if basemapStyle == .none {
                // Blank canvas — no basemap imagery or place names.
                MapCircle(center: airport.coordinate, radius: 25_000_000)
                    .foregroundStyle(mapCanvasColor)
            } else {
                let cover = basemapCoverOpacity
                // Dim outside the coverage ring; at opacity 0 the whole basemap is hidden.
                MapPolygon(outsideCoverageMask)
                    .foregroundStyle(mapCanvasColor.opacity(0.72 + 0.28 * cover))

                MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: trackingRadiusNM))
                    .foregroundStyle(mapCanvasColor.opacity(cover))
            }

            if trackingRadiusNM > Geo.innerRingNM + 0.5 {
                MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: Geo.innerRingNM))
                    .foregroundStyle(Color.clear)
                    .stroke(Color.orange.opacity(0.9), lineWidth: 1.5)

                if showsMapLabels {
                    Annotation("", coordinate: Geo.coordinate(from: airport.coordinate, distanceNM: Geo.innerRingNM, bearingDeg: 0)) {
                        RangeLabel(text: "5 NM")
                    }
                }
            }

            MapCircle(center: airport.coordinate, radius: Geo.meters(fromNM: trackingRadiusNM))
                .foregroundStyle(Color.clear)
                .stroke(Color.orange.opacity(0.95), lineWidth: 2)

            if showsMapLabels {
                Annotation("", coordinate: Geo.coordinate(from: airport.coordinate, distanceNM: trackingRadiusNM, bearingDeg: 0)) {
                    RangeLabel(text: rangeLabelText)
                }
            }

            ForEach(airport.runways) { runway in
                MapPolyline(coordinates: [runway.le, runway.he])
                    .stroke(.white.opacity(0.95), lineWidth: 3.5)

                ForEach(runway.publishedPatternSides, id: \.self) { side in
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

            if showsMapLabels, showAirfieldID {
                Annotation("", coordinate: airport.coordinate, anchor: .center) {
                    AirportMarker(icao: airport.icao)
                }
            }

            ForEach(mapAircraft) { ac in
                let landingHighlight = highlightedTracks.contains { $0.icao24 == ac.id && $0.isEmphasized }
                let isFocused = inspectedICAO == ac.id
                    || (selectedTrackerICAO24 == ac.id && !landingHighlight)
                let trailPoints = TrackSmoother.recent(ac.track)
                let drawTrail = ac.shouldDrawTrail && !landingHighlight && trailPoints.count >= 2
                let isEnroute = TrackPalette.isEnroute(ac.snapshot, airportElevationFt: airport.elevationFt)
                let isSurface = Geo.isSurfaceOps(
                    onGround: ac.snapshot.onGround,
                    altitudeAGLFt: ac.snapshot.altitudeAGLFt(airportElevationFt: airport.elevationFt),
                    groundSpeedKt: ac.snapshot.groundSpeedKt
                )
                let trailColor: Color = {
                    let base: Color = {
                        if ac.inPattern || ac.isPostLandingTrail || isFocused {
                            return TrackPalette.swatch(for: ac.id)
                        }
                        return TrackPalette.color(for: ac.snapshot, airportElevationFt: airport.elevationFt)
                    }()
                    return isFocused ? TrackPalette.emphasized(base) : base
                }()
                let markerColor = isSurface
                    ? (isFocused ? TrackPalette.emphasized(TrackPalette.ground) : TrackPalette.ground)
                    : trailColor
                let trailOpacity: Double = {
                    if isFocused { return 1.0 }
                    if ac.isCoasting { return 0.55 }
                    return isEnroute && !ac.inPattern ? TrackPalette.enrouteTrailOpacity : 1.0
                }()
                let lineWidth: CGFloat = {
                    if isFocused { return 4 }
                    return isEnroute && !ac.inPattern ? TrackPalette.enrouteTrailWidth : 2.25
                }()
                let trackLegs = TrackSmoother.pathLegs(from: trailPoints)

                if drawTrail {
                    ForEach(Array(trackLegs.enumerated()), id: \.offset) { _, leg in
                        if isFocused {
                            MapPolyline(coordinates: leg.coordinates)
                                .stroke(
                                    Color.white.opacity(0.85),
                                    style: StrokeStyle(
                                        lineWidth: 7,
                                        lineCap: .round,
                                        lineJoin: .round,
                                        dash: leg.isExtrapolated ? Self.missingADSBDash : []
                                    )
                                )
                        }
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(
                                trailColor.opacity((leg.isExtrapolated ? 0.75 : 1) * trailOpacity),
                                style: StrokeStyle(
                                    lineWidth: lineWidth,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: leg.isExtrapolated ? Self.missingADSBDash : (isEnroute && !ac.inPattern && !isFocused ? [8, 6] : [])
                                )
                            )
                    }
                }

                Annotation("", coordinate: ac.snapshot.coordinate, anchor: .center) {
                    AircraftMarker(
                        aircraft: ac,
                        color: markerColor,
                        airportElevationFt: airport.elevationFt,
                        isInspected: inspectedICAO == ac.id
                            || selectedTrackerICAO24 == ac.id
                            || selectedICAO24s.contains(ac.id)
                    )
                    .opacity(ac.isCoasting ? 0.7 : 1)
                    .modifier(TrackDumpHitModifier(enabled: debugTrackDump) {
                        inspectedICAO = ac.id
                        presentDump(dump(for: ac))
                    })
                    .accessibilityLabel(ac.snapshot.mapLabel)
                    .help(debugTrackDump ? "Click for ADS-B dump" : ac.snapshot.mapLabel)
                    .onHover { hovering in
                        handleHover(hovering, icao: ac.id)
                    }
                    .onTapGesture {
                        onSelectAircraft?(ac.id)
                    }
                }
            }

            ForEach(highlightedTracks.filter(\.isEmphasized)) { track in
                let legs = TrackSmoother.pathLegs(from: track.points)
                let trailOpacity = track.isEmphasized ? 1.0 : TrackPalette.postLandingUnselectedOpacity
                let lineWidth: CGFloat = track.isEmphasized ? 4 : TrackPalette.postLandingUnselectedWidth
                let strokeColor = track.isEmphasized ? TrackPalette.emphasized(track.color) : track.color
                ForEach(Array(legs.enumerated()), id: \.offset) { _, leg in
                    if track.isEmphasized {
                        MapPolyline(coordinates: leg.coordinates)
                            .stroke(
                                Color.white.opacity(0.85),
                                style: StrokeStyle(
                                    lineWidth: 7,
                                    lineCap: .round,
                                    lineJoin: .round,
                                    dash: leg.isExtrapolated ? Self.missingADSBDash : []
                                )
                            )
                    }
                    MapPolyline(coordinates: leg.coordinates)
                        .stroke(
                            strokeColor.opacity((leg.isExtrapolated ? 0.8 : 1) * trailOpacity),
                            style: StrokeStyle(
                                lineWidth: lineWidth,
                                lineCap: .round,
                                lineJoin: .round,
                                dash: leg.isExtrapolated ? Self.missingADSBDash : []
                            )
                        )
                }
                if track.isEmphasized, let last = track.points.sorted(by: { $0.timestamp < $1.timestamp }).last {
                    Annotation("", coordinate: last.coordinate, anchor: .bottom) {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(TrackPalette.emphasized(track.color))
                                .frame(width: 8, height: 8)
                            Text(track.label)
                                .font(.caption2.weight(.bold).monospaced())
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .modifier(TrackDumpHitModifier(enabled: debugTrackDump) {
                            presentDump(dump(for: track))
                        })
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
        .onChange(of: trackingRadiusNM) { _, _ in
            didCenter = false
            centerIfNeeded()
        }
        .overlay(alignment: .topLeading) {
            if activeRunwayDirection != nil || showingSavedTrack {
                VStack(alignment: .leading, spacing: 6) {
                    if let activeRunwayDirection {
                        Text("Active runway \(activeRunwayDirection)")
                            .font(.caption.weight(.semibold).monospaced())
                    }
                    if showingSavedTrack {
                        Text(highlightBannerText)
                            .font(.caption.weight(.semibold))
                        if debugTrackDump {
                            Text("Click a track point or label to copy ADS-B data")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            if let first = highlightedTracks.first {
                                Button("Copy ADS-B dump") {
                                    presentDump(dump(for: first))
                                }
                                .font(.caption.weight(.semibold))
                            }
                        }
                    }
                }
                .padding(10)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .padding(12)
            }
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
        .sheet(item: $localTrackDump) { dump in
            TrackDumpSheet(dump: dump)
        }
    }

    private func presentDump(_ payload: TrackDumpPayload) {
        guard debugTrackDump else { return }
        if let externalTrackDump {
            externalTrackDump.wrappedValue = payload
        } else {
            localTrackDump = payload
        }
    }

    private var rangeLabelText: String {
        let value = trackingRadiusNM
        if abs(value - value.rounded()) < 0.05 {
            return "\(Int(value.rounded())) NM"
        }
        return String(format: "%.1f NM", value)
    }

    /// Dark mask covering the map outside the traffic coverage circle.
    private var outsideCoverageMask: MKPolygon {
        let outerRadius = max(trackingRadiusNM + 80, 120)
        // Outer ring counterclockwise, hole clockwise — required for a proper MapKit hole.
        var outer = Geo.circleCoordinates(center: airport.coordinate, radiusNM: outerRadius, pointCount: 96)
        outer.reverse()
        var hole = Geo.circleCoordinates(center: airport.coordinate, radiusNM: trackingRadiusNM, pointCount: 96)
        let interior = MKPolygon(coordinates: &hole, count: hole.count)
        return MKPolygon(coordinates: &outer, count: outer.count, interiorPolygons: [interior])
    }

    private var basemapStyle: MapBasemapStyle {
        MapBasemapStyle(rawValue: mapStyleRaw) ?? .satellite
    }

    /// Range / airfield text labels — hidden for blank (None) background.
    private var showsMapLabels: Bool {
        basemapStyle != .none
    }

    private var mapCanvasColor: Color {
        Color(red: 0.08, green: 0.085, blue: 0.095)
    }

    /// How much the basemap is covered. `mapOpacity` 1 = fully visible, 0 = invisible.
    private var basemapCoverOpacity: Double {
        switch basemapStyle {
        case .none:
            return 1.0
        case .satellite, .street:
            return min(1, max(0, 1.0 - mapOpacity))
        }
    }

    private var selectedMapStyle: MapStyle {
        switch basemapStyle {
        case .none:
            // No cartography / place names — solid canvas drawn above.
            return .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        case .satellite:
            return .imagery(elevation: .flat)
        case .street:
            return .standard(
                elevation: .flat,
                emphasis: .automatic,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        }
    }

    private var inspectedAircraft: LandingDetector.TrackedAircraft? {
        let icao = inspectedICAO ?? selectedTrackerICAO24
        guard let icao else { return nil }
        return mapAircraft.first { $0.id == icao }
    }

    private func dump(for aircraft: LandingDetector.TrackedAircraft) -> TrackDumpPayload {
        let state = aircraft.flightState?.rawValue ?? "unknown"
        let coast = aircraft.isCoasting ? " · last data \(aircraft.lastSeen.formatted(date: .omitted, time: .standard))" : ""
        return TrackDumpPayload(
            id: UUID(),
            title: aircraft.snapshot.displayLabel,
            subtitle: "Engagement track · \(aircraft.snapshot.typeDisplay) · state=\(state)\(coast)",
            airportICAO: airport.icao,
            airportElevationFt: airport.elevationFt,
            icao24: aircraft.snapshot.icao24,
            reportedKind: "flightState=\(state)",
            reportedTime: nil,
            points: aircraft.track
        )
    }

    private func dump(for track: HighlightedSavedTrack) -> TrackDumpPayload {
        TrackDumpPayload(
            id: track.id,
            title: track.label,
            subtitle: "Saved event track",
            airportICAO: track.airportICAO.isEmpty ? airport.icao : track.airportICAO,
            airportElevationFt: airport.elevationFt,
            icao24: track.icao24.isEmpty ? nil : track.icao24,
            reportedKind: track.kindTitle.isEmpty ? nil : track.kindTitle,
            reportedTime: track.eventTimestamp,
            points: track.points
        )
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
        let delta = max(0.08, (trackingRadiusNM / 60.0) * 2.4)
        let span = MKCoordinateSpan(latitudeDelta: delta, longitudeDelta: delta)
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
        let baseColor = isHigh ? TrackPalette.enroute : color
        let symbolColor = isInspected ? TrackPalette.emphasized(baseColor) : baseColor
        let opacity = aircraft.isCoasting ? 0.55 : 1.0
        VStack(spacing: 2) {
            if isHigh {
                Image(systemName: "location.north.fill")
                    .font(.system(size: isInspected ? 18 : 14, weight: .bold))
                    .foregroundStyle(symbolColor)
                    .rotationEffect(.degrees(heading))
                    .shadow(color: symbolColor.opacity(isInspected ? 0.95 : 0.45), radius: isInspected ? 8 : 1)
            } else {
                AircraftGlyph(
                    kind: AircraftSymbolKind.from(category: snapshot.category, typeCode: snapshot.typeCode),
                    color: symbolColor,
                    heading: heading,
                    isInspected: isInspected
                )
            }
            Text(snapshot.mapLabel)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(symbolColor)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(.ultraThinMaterial, in: Capsule())
        }
        .padding(4)
        .opacity(opacity)
        .background(isInspected ? symbolColor.opacity(0.32) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .shadow(color: isInspected ? symbolColor.opacity(0.7) : .clear, radius: isInspected ? 10 : 0)
    }
}

private struct AircraftInfoCard: View {
    let aircraft: LandingDetector.TrackedAircraft
    let airport: Airport

    private var snapshot: AircraftSnapshot { aircraft.snapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(snapshot.mapLabel)
                    .font(.headline.monospaced())
                Spacer()
                Text(statusTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(statusColor)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                info("Type", snapshot.typeDisplay)
                if let registration = snapshot.registration, registration != snapshot.mapLabel {
                    info("Registration", registration)
                } else if snapshot.tailNumber != snapshot.mapLabel {
                    info("Tail", snapshot.tailNumber)
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
                if let maxAGL = aircraft.maxAltitudeAGLFt, maxAGL > 0 {
                    info("Max AGL", "\(format(maxAGL)) ft")
                }
                if let maxGS = aircraft.maxGroundSpeedKt, maxGS > 0 {
                    info("Max GS", "\(format(maxGS)) kt")
                }
                if let duration = aircraft.trackDuration, duration >= 1 {
                    info("Duration", formatDuration(duration))
                }
                if aircraft.isCoasting {
                    info("Last data", aircraft.lastSeen.formatted(.relative(presentation: .named)))
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

    private var statusTitle: String {
        if aircraft.isCoasting {
            return snapshot.onGround || aircraft.patternPhase == .ground ? "Last on ground" : "Last seen"
        }
        if aircraft.patternPhase == .ground || snapshot.onGround { return "Ground" }
        return aircraft.patternChipText ?? "Airborne"
    }

    private var statusColor: Color {
        if aircraft.isCoasting {
            return .secondary
        }
        if aircraft.patternPhase == .ground || snapshot.onGround {
            return TrackPalette.ground
        }
        return TrackPalette.color(for: snapshot, airportElevationFt: airport.elevationFt)
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

    private func formatDuration(_ interval: TimeInterval) -> String {
        let totalSeconds = max(0, Int(interval.rounded()))
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        }
        return "\(seconds)s"
    }
}

/// When enabled, wraps content in a tappable control for the ADS-B dump sheet.
/// When disabled, passes touches through so MapKit pinch/pan work normally.
private struct TrackDumpHitModifier: ViewModifier {
    var enabled: Bool
    var action: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            Button(action: action) {
                content
            }
            .buttonStyle(.plain)
            .help("Click for ADS-B track dump")
        } else {
            content
                .allowsHitTesting(false)
        }
    }
}
