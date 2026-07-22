import SwiftUI
import D2CTrackerCore

private enum SkyPresentation: String, CaseIterable, Identifiable {
    case dome = "Dome"
    case horizon = "Horizon"

    var id: Self { self }
}

struct SkyScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var terrain: TerrainService
    @State private var presentation: SkyPresentation = .dome

    private var horizonObservations: [SatelliteObservation] {
        model.observations
            .filter { $0.elevationDegrees >= 0 }
            .sorted { $0.elevationDegrees > $1.elevationDegrees }
    }

    private var maskObservations: [SatelliteObservation] {
        horizonObservations.filter {
            model.isObservationVisible($0)
                && uplinkAssessment($0).adjustedMarginDB >= D2CUplinkBudget.dependableMarginDB
        }
    }

    private var selectedInSky: SatelliteObservation? {
        let id = model.selectedSatelliteID ?? model.estimate.satellite?.id
        return horizonObservations.first { $0.id == id }
    }

    private var displayedSatelliteID: Int? {
        model.selectedSatelliteID ?? model.estimate.satellite?.id
    }

    private var isInspectingAnotherSatellite: Bool {
        model.selectedSatelliteID != nil
    }

    private var representativeSatelliteAltitude: Double {
        let altitudes = horizonObservations
            .map(\.state.geodetic.altitudeKilometers)
            .filter { $0 > 100 }
            .sorted()
        guard !altitudes.isEmpty else { return 525 }
        return altitudes[altitudes.count / 2]
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                LazyVStack(spacing: 14) {
                    controls
                    InputStatusBadges(statuses: model.inputStatuses)

                    if presentation == .dome {
                        SkyPlotView(
                            observations: horizonObservations,
                            selectedID: displayedSatelliteID,
                            candidateID: model.estimate.satellite?.id,
                            elevationMask: model.elevationMask,
                            representativeSatelliteAltitude: representativeSatelliteAltitude,
                            terrainHorizon: terrain.isEnabled ? terrain.horizonProfile : nil,
                            headingDegrees: location.headingDegrees,
                            resetToken: model.sceneActivationToken,
                            onSelect: inspectSatellite
                        )
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 560)
                    } else {
                        HorizonSkyView(
                            observations: horizonObservations,
                            selectedID: displayedSatelliteID,
                            candidateID: model.estimate.satellite?.id,
                            elevationMask: model.elevationMask,
                            representativeSatelliteAltitude: representativeSatelliteAltitude,
                            terrainHorizon: terrain.isEnabled ? terrain.horizonProfile : nil,
                            headingDegrees: location.horizonViewHeadingDegrees ?? location.headingDegrees,
                            viewportElevationDegrees: location.horizonViewElevationDegrees,
                            resetToken: model.sceneActivationToken,
                            onSelect: inspectSatellite
                        )
                        .aspectRatio(1.12, contentMode: .fit)
                        .frame(maxWidth: 700)

                        Label("Turn and tilt the phone · horizon remains level", systemImage: "move.3d")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if isInspectingAnotherSatellite, let selected = selectedInSky {
                        inspectionBar(selected)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 16) {
                            Label("Possible uplink", systemImage: "waveform.path")
                                .foregroundStyle(.indigo)
                            Label("Dependable data", systemImage: "antenna.radiowaves.left.and.right")
                                .foregroundStyle(.pink)
                            if terrain.horizonProfile != nil {
                                Label("Terrain ridge", systemImage: "line.diagonal")
                                    .foregroundStyle(.mint)
                                Label("RF clearance", systemImage: "waveform.path")
                                    .foregroundStyle(.yellow)
                            }
                        }
                        .font(.caption)
                    }

                    if let selected = selectedInSky {
                        selectedCard(selected)
                    } else {
                        ContentUnavailableView(
                            "No satellites above the horizon",
                            systemImage: "scope",
                            description: Text("The plot remains available offline and updates as Direct-to-Cell satellites rise.")
                        )
                        .foregroundStyle(.secondary)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Local Sky")
        .preferredColorScheme(.dark)
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("View", selection: $presentation) {
                ForEach(SkyPresentation.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .trailing, spacing: 1) {
                Text("\(maskObservations.count)")
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.cyan)
                Text("dependable now")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 64)
        }
    }

    private func selectedCard(_ selected: SatelliteObservation) -> some View {
        let assessment = uplinkAssessment(selected)
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.satellite.elements.name).font(.headline)
                        Text(selected.id == model.estimate.satellite?.id ? "Likely serving satellite" : "Selected satellite")
                            .font(.caption).foregroundStyle(selected.id == model.estimate.satellite?.id ? .cyan : .secondary)
                    }
                    Spacer()
                    Label(compassPoint(selected.azimuthDegrees), systemImage: "location.north.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.cyan)
                }

                HStack(spacing: 0) {
                    skyMetric("Elevation", selected.elevationDegrees.formatted(.number.precision(.fractionLength(1))) + "°")
                    skyMetric("Azimuth", selected.azimuthDegrees.formatted(.number.precision(.fractionLength(0))) + "°")
                    skyMetric("Range", selected.slantRangeKilometers.formatted(.number.precision(.fractionLength(0))) + " km")
                    skyMetric("Sets in", timeUntil(selected.pass?.set))
                }

                HStack {
                    Label("Static clear-sky uplink", systemImage: "arrow.up.to.line.compact")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(String(format: "%+.1f dB · %@", assessment.clearSkyMarginDB, qualityLabel(assessment.quality)))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(qualityColor(assessment.quality))
                }
                Text("Reference ring ignores phone orientation; terrain remains shown separately.")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
    }

    private func inspectionBar(_ selected: SatelliteObservation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "satellite.fill")
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("Inspecting \(selected.satellite.elements.name)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("Details pinned to this satellite")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: returnToServingSatellite) {
                Label("Return to Serving", systemImage: "antenna.radiowaves.left.and.right")
                    .labelStyle(.titleAndIcon)
            }
            .font(.caption.weight(.semibold))
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.cyan.opacity(0.8))
        }
        .padding(11)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.cyan.opacity(0.24), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }

    private func inspectSatellite(_ id: Int?) {
        model.select(id)
    }

    private func returnToServingSatellite() {
        model.select(nil)
    }

    private func skyMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func uplinkAssessment(_ observation: SatelliteObservation) -> D2CUplinkAssessment {
        D2CUplinkBudget.clearSkyAssessment(for: observation)
    }

    private func qualityLabel(_ quality: D2CUplinkQuality) -> String {
        switch quality {
        case .unavailable: "unlikely"
        case .possible: "possible"
        case .dependable: "dependable"
        case .strong: "strong"
        }
    }

    private func qualityColor(_ quality: D2CUplinkQuality) -> Color {
        switch quality {
        case .unavailable: .orange
        case .possible: .indigo
        case .dependable: .pink
        case .strong: .mint
        }
    }

    private func compassPoint(_ degrees: Double) -> String {
        let labels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = CoordinateTransforms.normalizedDegrees(degrees)
        return labels[Int((normalized / 45).rounded()) % labels.count]
    }

    private func timeUntil(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m"
    }
}

struct SkyPlotView: View {
    let observations: [SatelliteObservation]
    let selectedID: Int?
    let candidateID: Int?
    let elevationMask: Double
    let representativeSatelliteAltitude: Double
    let terrainHorizon: TerrainHorizonProfile?
    let headingDegrees: Double?
    let resetToken: Int
    let onSelect: (Int?) -> Void

    @State private var motion = SkyPlotMotion()

    private let rotationDegrees = 0.0
    private var effectiveVisibleCount: Int {
        observations.filter { observation in
            let terrainElevation = terrainHorizon?.rfHorizonDegrees(atAzimuth: observation.azimuthDegrees) ?? 0
            let assessment = D2CUplinkBudget.clearSkyAssessment(for: observation)
            return observation.elevationDegrees >= max(elevationMask, terrainElevation)
                && assessment.adjustedMarginDB >= D2CUplinkBudget.dependableMarginDB
        }.count
    }

    var body: some View {
        let possibleEnvelopeSamples = envelopeSamples(targetMarginDB: 0)
        let dependableEnvelopeSamples = envelopeSamples(targetMarginDB: D2CUplinkBudget.dependableMarginDB)
        return TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let animatedPositions = motion.positions(at: timeline.date)
                Canvas { context, size in
                let side = min(size.width, size.height)
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                let radius = side * 0.425
                let horizonRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

                context.fill(Path(ellipseIn: horizonRect), with: .radialGradient(
                    Gradient(colors: [Color.cyan.opacity(0.16), Color.blue.opacity(0.09), Color.black.opacity(0.76)]),
                    center: center,
                    startRadius: 0,
                    endRadius: radius
                ))

                let maskRadius = radius * (90 - elevationMask) / 90
                var belowMask = Path()
                belowMask.addEllipse(in: horizonRect)
                belowMask.addEllipse(in: CGRect(x: center.x - maskRadius, y: center.y - maskRadius, width: maskRadius * 2, height: maskRadius * 2))
                context.fill(belowMask, with: .color(.orange.opacity(0.045)), style: FillStyle(eoFill: true))

                if let terrainHorizon, !terrainHorizon.elevationDegrees.isEmpty {
                    var physicalRidge = Path()
                    var rfClearanceRidge = Path()
                    for index in terrainHorizon.elevationDegrees.indices {
                        let azimuth = Double(index) * terrainHorizon.azimuthStepDegrees
                        let elevation = terrainHorizon.elevationDegrees[index]
                        let physicalPoint = plotPoint(azimuth: azimuth, elevation: elevation, center: center, radius: radius)
                        let rfPoint = plotPoint(
                            azimuth: azimuth,
                            elevation: terrainHorizon.rfHorizonDegrees(atAzimuth: azimuth),
                            center: center,
                            radius: radius
                        )
                        if index == terrainHorizon.elevationDegrees.startIndex {
                            physicalRidge.move(to: physicalPoint)
                            rfClearanceRidge.move(to: rfPoint)
                        } else {
                            physicalRidge.addLine(to: physicalPoint)
                            rfClearanceRidge.addLine(to: rfPoint)
                        }
                    }
                    physicalRidge.closeSubpath()
                    rfClearanceRidge.closeSubpath()
                    var terrainBlockedArea = Path(ellipseIn: horizonRect)
                    terrainBlockedArea.addPath(rfClearanceRidge)
                    context.fill(
                        terrainBlockedArea,
                        with: .color(.brown.opacity(0.18)),
                        style: FillStyle(eoFill: true)
                    )
                    context.stroke(
                        physicalRidge,
                        with: .color(.mint.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 1.5, lineJoin: .round)
                    )
                    context.stroke(
                        rfClearanceRidge,
                        with: .color(.yellow.opacity(0.8)),
                        style: StrokeStyle(lineWidth: 1.2, lineJoin: .round, dash: [4, 3])
                    )
                }

                let possibleEnvelope = envelopePath(
                    samples: possibleEnvelopeSamples,
                    center: center,
                    radius: radius
                )
                context.stroke(
                    possibleEnvelope,
                    with: .color(.indigo.opacity(0.9)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round, dash: [5, 4])
                )
                let dependableEnvelope = envelopePath(
                    samples: dependableEnvelopeSamples,
                    center: center,
                    radius: radius
                )
                context.stroke(
                    dependableEnvelope,
                    with: .color(.pink.opacity(0.92)),
                    style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
                )

                for angle in stride(from: 0.0, to: 360, by: 30) {
                    var spoke = Path()
                    spoke.move(to: center)
                    spoke.addLine(to: plotPoint(azimuth: angle, elevation: 0, center: center, radius: radius))
                    context.stroke(spoke, with: .color(.white.opacity(angle.truncatingRemainder(dividingBy: 90) == 0 ? 0.09 : 0.035)), lineWidth: 0.7)
                }

                for elevation in [0.0, 30, 60] {
                    let ringRadius = radius * (90 - elevation) / 90
                    let path = Path(ellipseIn: CGRect(x: center.x - ringRadius, y: center.y - ringRadius, width: ringRadius * 2, height: ringRadius * 2))
                    context.stroke(path, with: .color(.white.opacity(elevation == 0 ? 0.38 : 0.13)), lineWidth: elevation == 0 ? 1.5 : 0.8)
                    if elevation > 0 {
                        context.draw(
                            Text("\(Int(elevation))°").font(.caption2.monospacedDigit()).foregroundStyle(.secondary),
                            at: CGPoint(x: center.x + 5, y: center.y - ringRadius + 7),
                            anchor: .topLeading
                        )
                    }
                }

                context.stroke(
                    Path(ellipseIn: CGRect(x: center.x - maskRadius, y: center.y - maskRadius, width: maskRadius * 2, height: maskRadius * 2)),
                    with: .color(.orange.opacity(0.55)),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 5])
                )

                for (label, angle) in [("N", 0.0), ("E", 90.0), ("S", 180.0), ("W", 270.0)] {
                    let point = plotPoint(azimuth: angle, elevation: -7, center: center, radius: radius)
                    context.draw(
                        Text(label).font(.caption.weight(.bold)).foregroundStyle(label == "N" ? .cyan : .secondary),
                        at: point
                    )
                }

                if let headingDegrees {
                    let tip = plotPoint(azimuth: headingDegrees, elevation: 8, center: center, radius: radius)
                    var heading = Path()
                    heading.move(to: center)
                    heading.addLine(to: tip)
                    context.stroke(heading, with: .color(.mint.opacity(0.48)), style: StrokeStyle(lineWidth: 1.2, dash: [3, 4]))
                    context.draw(Image(systemName: "iphone.gen3.radiowaves.left.and.right"), at: tip)
                }

                context.fill(Path(ellipseIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)), with: .color(.cyan.opacity(0.7)))
                context.draw(Text("ZENITH").font(.system(size: 7, weight: .bold)).foregroundStyle(.cyan.opacity(0.65)), at: CGPoint(x: center.x, y: center.y + 11), anchor: .top)

                for satellite in observations.reversed() {
                    let position = animatedPositions[satellite.id]
                        ?? SkyPlotPosition(azimuth: satellite.azimuthDegrees, elevation: satellite.elevationDegrees)
                    let point = plotPoint(azimuth: position.azimuth, elevation: position.elevation, center: center, radius: radius)
                    let selected = satellite.id == selectedID
                    let candidate = satellite.id == candidateID
                    let terrainElevation = terrainHorizon?.rfHorizonDegrees(atAzimuth: position.azimuth) ?? 0
                    let assessment = D2CUplinkBudget.clearSkyAssessment(for: satellite)
                    let terrainClear = position.elevation >= max(elevationMask, terrainElevation)
                    let dotRadius: CGFloat = selected ? 7.5 : max(3.2, 3.2 + CGFloat(position.elevation / 90) * 2.5)
                    let color: Color = selected ? .cyan : satelliteColor(
                        quality: terrainClear ? assessment.quality : .unavailable
                    )

                    if selected || candidate {
                        let haloRadius: CGFloat = selected ? 15 : 11
                        context.fill(
                            Path(ellipseIn: CGRect(x: point.x - haloRadius, y: point.y - haloRadius, width: haloRadius * 2, height: haloRadius * 2)),
                            with: .color((selected ? Color.cyan : Color.mint).opacity(0.14))
                        )
                    }
                    context.fill(Path(ellipseIn: CGRect(x: point.x - dotRadius, y: point.y - dotRadius, width: dotRadius * 2, height: dotRadius * 2)), with: .color(color))
                    if candidate && !selected {
                        context.stroke(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)), with: .color(.mint.opacity(0.8)), lineWidth: 1)
                    }
                    if selected {
                        let labelAbove = point.y > center.y - radius * 0.62
                        context.draw(
                            Text(satellite.satellite.elements.name).font(.caption2.weight(.semibold)).foregroundStyle(.white),
                            at: CGPoint(x: point.x, y: point.y + (labelAbove ? -17 : 17)),
                            anchor: labelAbove ? .bottom : .top
                        )
                    }
                }
                }
                .contentShape(Circle())
                .gesture(SpatialTapGesture().onEnded {
                    selectNearest(to: $0.location, size: geometry.size, positions: motion.positions(at: Date()))
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Overhead sky plot")
                .accessibilityValue("\(effectiveVisibleCount) satellites above the effective terrain horizon")
            }
        }
        .onAppear { updateMotion(with: observations, at: Date()) }
        .onChange(of: observations) { _, updated in updateMotion(with: updated, at: Date()) }
        .onChange(of: resetToken) { _, _ in
            motion = SkyPlotMotion()
            updateMotion(with: observations, at: .now)
        }
    }

    private func plotPoint(azimuth: Double, elevation: Double, center: CGPoint, radius: CGFloat) -> CGPoint {
        let radial = radius * max(0, min(1.08, (90 - elevation) / 90))
        let radians = (azimuth + rotationDegrees) * .pi / 180
        return CGPoint(x: center.x + radial * sin(radians), y: center.y - radial * cos(radians))
    }

    private func envelopeSamples(targetMarginDB: Double) -> [(azimuth: Double, elevation: Double)] {
        (0...120).map { index in
            let azimuth = Double(index) * 3
            let linkElevation = D2CUplinkBudget.minimumClearSkyElevationDegrees(
                satelliteAltitudeKilometers: representativeSatelliteAltitude,
                targetMarginDB: targetMarginDB
            )
            let terrainElevation = terrainHorizon?.rfHorizonDegrees(atAzimuth: azimuth) ?? 0
            return (azimuth, max(linkElevation, terrainElevation))
        }
    }

    private func envelopePath(
        samples: [(azimuth: Double, elevation: Double)],
        center: CGPoint,
        radius: CGFloat
    ) -> Path {
        var path = Path()
        for (index, sample) in samples.enumerated() {
            let point = plotPoint(
                azimuth: sample.azimuth,
                elevation: sample.elevation,
                center: center,
                radius: radius
            )
            if index == 0 { path.move(to: point) }
            else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }

    private func satelliteColor(quality: D2CUplinkQuality) -> Color {
        switch quality {
        case .unavailable: .orange.opacity(0.55)
        case .possible: .indigo
        case .dependable: .white
        case .strong: .mint
        }
    }

    private func selectNearest(to point: CGPoint, size: CGSize, positions: [Int: SkyPlotPosition]) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = min(size.width, size.height) * 0.425
        let nearest = observations.map { observation in
            let position = positions[observation.id]
                ?? SkyPlotPosition(azimuth: observation.azimuthDegrees, elevation: observation.elevationDegrees)
            let mapped = plotPoint(azimuth: position.azimuth, elevation: position.elevation, center: center, radius: radius)
            return (observation.id, hypot(mapped.x - point.x, mapped.y - point.y))
        }.min { $0.1 < $1.1 }
        onSelect((nearest?.1 ?? .infinity) < 34 ? nearest?.0 : nil)
    }

    private func updateMotion(with updated: [SatelliteObservation], at date: Date) {
        let targets = Dictionary(uniqueKeysWithValues: updated.map {
            ($0.id, SkyPlotPosition(azimuth: $0.azimuthDegrees, elevation: $0.elevationDegrees))
        })
        let sampleDate = updated.first?.observedAt
        motion.retarget(to: targets, sampleDate: sampleDate, at: date)
    }
}

private struct SkyPlotPosition {
    let azimuth: Double
    let elevation: Double
}

private struct SkyPlotMotion {
    private var start: [Int: SkyPlotPosition] = [:]
    private var target: [Int: SkyPlotPosition] = [:]
    private var startedAt = Date.distantPast
    private var duration: TimeInterval = 0
    private var sampleDate: Date?

    mutating func retarget(to updated: [Int: SkyPlotPosition], sampleDate updatedSampleDate: Date?, at date: Date) {
        guard !target.isEmpty else {
            start = updated
            target = updated
            startedAt = date
            sampleDate = updatedSampleDate
            return
        }

        let current = positions(at: date)
        start = Dictionary(uniqueKeysWithValues: updated.map { id, value in (id, current[id] ?? value) })
        target = updated
        startedAt = date

        if let previousSampleDate = sampleDate, let updatedSampleDate, updatedSampleDate > previousSampleDate {
            let sampleGap = updatedSampleDate.timeIntervalSince(previousSampleDate)
            duration = sampleGap <= 7.5 ? min(6, max(1, sampleGap)) : 0
        } else {
            duration = 0
        }
        sampleDate = updatedSampleDate
    }

    func positions(at date: Date) -> [Int: SkyPlotPosition] {
        guard duration > 0 else { return target }
        let fraction = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
        return Dictionary(uniqueKeysWithValues: target.map { id, destination in
            guard let origin = start[id] else { return (id, destination) }
            var azimuthDelta = (destination.azimuth - origin.azimuth).truncatingRemainder(dividingBy: 360)
            if azimuthDelta > 180 { azimuthDelta -= 360 }
            if azimuthDelta < -180 { azimuthDelta += 360 }
            let azimuth = CoordinateTransforms.normalizedDegrees(origin.azimuth + azimuthDelta * fraction)
            let elevation = origin.elevation + (destination.elevation - origin.elevation) * fraction
            return (id, SkyPlotPosition(azimuth: azimuth, elevation: elevation))
        })
    }
}
