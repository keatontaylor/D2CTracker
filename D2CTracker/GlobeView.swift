import SwiftUI
import SceneKit
import simd
import UIKit
import D2CTrackerCore

private enum SatelliteMapMode: String, CaseIterable, Identifiable {
    case visible = "Service capable"
    case constellation = "All DTC"

    var id: Self { self }
}

struct GlobeScreen: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationService
    @State private var mode: SatelliteMapMode = .constellation
    @State private var focusRequest = GlobeFocusRequest(target: .observer, token: 0)
    @State private var didCenterOnLiveLocation = false

    private var displayedSatelliteID: Int? {
        model.selectedSatelliteID ?? model.estimate.satellite?.id
    }

    private var selectedInGlobe: SatelliteObservation? {
        guard let displayedSatelliteID else { return nil }
        return model.observations.first { $0.id == displayedSatelliteID }
    }

    private var isInspectingAnotherSatellite: Bool {
        model.selectedSatelliteID != nil
    }

    private var displayedObservations: [SatelliteObservation] {
        var values = mode == .visible ? serviceCapableObservations : model.observations
        if let selected = selectedInGlobe, !values.contains(where: { $0.id == selected.id }) {
            values.append(selected)
        }
        return values
    }

    private var serviceCapableObservations: [SatelliteObservation] {
        model.observations.filter(model.isObservationServiceCapable)
    }

    private var serviceCapableIDs: Set<Int> {
        Set(serviceCapableObservations.map(\.id))
    }

    private var selectedServiceElevationDegrees: Double {
        guard let selected = selectedInGlobe else { return 90 }
        return D2CUplinkBudget.minimumQualityElevationDegrees(
            satelliteAltitudeKilometers: selected.state.geodetic.altitudeKilometers,
            satelliteAzimuthDegrees: 0,
            targetAdjustedMarginDB: D2CUplinkBudget.dependableMarginDB,
            phoneHeadingDegrees: nil,
            phonePointingElevationDegrees: nil
        )
    }

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                LazyVStack(spacing: 14) {
                    HStack {
                        Picker("Satellites", selection: $mode) {
                            ForEach(SatelliteMapMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        Text("\(displayedObservations.count)")
                            .font(.headline.monospacedDigit())
                            .foregroundStyle(.cyan)
                            .frame(minWidth: 40, alignment: .trailing)
                            .accessibilityLabel("\(displayedObservations.count) satellites displayed")
                    }

                    InputStatusBadges(statuses: model.inputStatuses)

                    SatelliteGlobe3DView(
                        coastlines: model.coastlines,
                        countryBoundaries: model.countryBoundaries,
                        stateBoundaries: model.stateBoundaries,
                        observations: displayedObservations,
                        groundTrack: model.groundTrack,
                        observer: model.observerLocation,
                        selectedID: displayedSatelliteID,
                        serviceCapableIDs: serviceCapableIDs,
                        selectedServiceElevationDegrees: selectedServiceElevationDegrees,
                        denseConstellation: mode == .constellation,
                        resetToken: model.sceneActivationToken,
                        focusRequest: focusRequest,
                        onSelect: inspectSatellite
                    )
                    .aspectRatio(0.92, contentMode: .fit)
                    .frame(maxWidth: 680)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(alignment: .topTrailing) { globeControls }
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1)
                    }

                    if isInspectingAnotherSatellite, let selected = selectedInGlobe {
                        inspectionBar(selected)
                    }

                    legend

                    if let selected = selectedInGlobe { selectedCard(selected) }
                }
                .padding()
            }
        }
        .navigationTitle("3D Globe")
        .preferredColorScheme(.dark)
        .onAppear {
            if location.location != nil { didCenterOnLiveLocation = true }
        }
        .onChange(of: location.location) { _, updatedLocation in
            guard updatedLocation != nil, !model.usesManualLocation, !didCenterOnLiveLocation else { return }
            didCenterOnLiveLocation = true
            requestFocus(.observer)
        }
    }

    private var legend: some View {
        HStack(spacing: 13) {
            LegendDot(color: .mint, text: "You")
            LegendDot(color: .cyan, text: "Selected")
            LegendDot(color: .white.opacity(0.8), text: "DTC satellite")
            Spacer(minLength: 0)
            Text("Drag · pinch · tap")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    private var globeControls: some View {
        VStack(spacing: 7) {
            Button { requestFocus(.observer) } label: { Image(systemName: "location.fill") }
                .accessibilityLabel("Center globe on my location")
            if selectedInGlobe != nil {
                Button { requestFocus(.selectedSatellite) } label: { Image(systemName: "scope") }
                    .accessibilityLabel("Center globe on selected satellite")
            }
            Button { requestFocus(.wholeEarth) } label: { Image(systemName: "globe.americas.fill") }
                .accessibilityLabel("Show the whole Earth")
        }
        .font(.caption.weight(.semibold))
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
        .padding(10)
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private func requestFocus(_ target: GlobeFocusTarget) {
        focusRequest = GlobeFocusRequest(target: target, token: focusRequest.token + 1)
    }

    private func inspectSatellite(_ id: Int?) {
        model.select(id)
    }

    private func returnToServingSatellite() {
        model.select(nil)
    }

    private func inspectionBar(_ selected: SatelliteObservation) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "satellite.fill")
                .foregroundStyle(.cyan)
            VStack(alignment: .leading, spacing: 1) {
                Text("Inspecting \(selected.satellite.elements.name)")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                Text("Globe details pinned to this satellite")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button(action: returnToServingSatellite) {
                Label("Return to Serving", systemImage: "antenna.radiowaves.left.and.right")
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
    }

    private func selectedCard(_ selected: SatelliteObservation) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(selected.satellite.elements.name).font(.headline)
                        Text(selected.id == model.estimate.satellite?.id ? "Likely serving satellite" : "Selected satellite")
                            .font(.caption).foregroundStyle(selected.id == model.estimate.satellite?.id ? .cyan : .secondary)
                    }
                    Spacer()
                    Image(systemName: "satellite.fill").foregroundStyle(.cyan).font(.title2)
                }

                HStack(spacing: 0) {
                    globeMetric("Latitude", selected.state.geodetic.latitude.formatted(.number.precision(.fractionLength(1))) + "°")
                    globeMetric("Longitude", signedLongitude(selected.state.geodetic.longitude).formatted(.number.precision(.fractionLength(1))) + "°")
                    globeMetric("Altitude", selected.state.geodetic.altitudeKilometers.formatted(.number.precision(.fractionLength(0))) + " km")
                }
                HStack(spacing: 0) {
                    globeMetric("Elevation", selected.elevationDegrees.formatted(.number.precision(.fractionLength(1))) + "°")
                    globeMetric("Azimuth", selected.azimuthDegrees.formatted(.number.precision(.fractionLength(0))) + "°")
                    globeMetric("Range", selected.slantRangeKilometers.formatted(.number.precision(.fractionLength(0))) + " km")
                }
            }
        }
    }

    private func globeMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.subheadline.weight(.semibold).monospacedDigit()).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func signedLongitude(_ longitude: Double) -> Double {
        CoordinateTransforms.normalizedDegrees(longitude + 180) - 180
    }
}

private enum GlobeFocusTarget: Equatable {
    case observer
    case selectedSatellite
    case wholeEarth
}

private struct GlobeFocusRequest: Equatable {
    let target: GlobeFocusTarget
    let token: Int
}

private struct SatelliteGlobe3DView: UIViewRepresentable {
    let coastlines: [[ObserverLocation]]
    let countryBoundaries: [[ObserverLocation]]
    let stateBoundaries: [[ObserverLocation]]
    let observations: [SatelliteObservation]
    let groundTrack: [GroundTrackPoint]
    let observer: ObserverLocation
    let selectedID: Int?
    let serviceCapableIDs: Set<Int>
    let selectedServiceElevationDegrees: Double
    let denseConstellation: Bool
    let resetToken: Int
    let focusRequest: GlobeFocusRequest
    let onSelect: (Int?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        context.coordinator.configure(view)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.update(
            coastlines: coastlines,
            countryBoundaries: countryBoundaries,
            stateBoundaries: stateBoundaries,
            observations: observations,
            groundTrack: groundTrack,
            observer: observer,
            selectedID: selectedID,
            serviceCapableIDs: serviceCapableIDs,
            selectedServiceElevationDegrees: selectedServiceElevationDegrees,
            denseConstellation: denseConstellation,
            resetToken: resetToken,
            in: view
        )
        context.coordinator.apply(focusRequest, selectedID: selectedID, observations: observations, observer: observer, in: view)
    }

    static func dismantleUIView(_ uiView: SCNView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSelect: (Int?) -> Void
        private let scene = SCNScene()
        private let earthNode = SCNNode()
        private let coastlineLayer = SCNNode()
        private let countryBoundaryLayer = SCNNode()
        private let satelliteLayer = SCNNode()
        private let overlayLayer = SCNNode()
        private let animatedOverlayLayer = SCNNode()
        private let stateBoundaryLayer = SCNNode()
        private let cameraNode = SCNNode()
        private let footprintNode = SCNNode()
        private let observerLinkNode = SCNNode()
        private var coastlineSignature = 0
        private var countryBoundarySignature = 0
        private var stateBoundarySignature = 0
        private var lastFocusToken = Int.min
        private var displayLink: CADisplayLink?
        private var cameraLatitude = 2.18
        private var cameraLongitude = 0.0
        private var cameraDistance: Float = 3.15
        private var currentMarkerScale: Float = 1
        private var satelliteNodes: [Int: SCNNode] = [:]
        private var satelliteStyles: [Int: SatelliteStyle] = [:]
        private var satelliteSampleDate: Date?
        private var lastResetToken = Int.min
        private var animatedOverlaySatelliteID: Int?
        private var animatedFootprintRadius = 0.0
        private var animatedObserverPosition: SCNVector3?
        private var animatedLinkColor: UIColor?
        private weak var parentScrollView: UIScrollView?

        private struct SatelliteStyle: Equatable {
            let selected: Bool
            let aboveMask: Bool
            let dense: Bool
        }

        init(onSelect: @escaping (Int?) -> Void) {
            self.onSelect = onSelect
            super.init()
        }

        func configure(_ view: SCNView) {
            view.scene = scene
            view.backgroundColor = .black
            view.antialiasingMode = .multisampling4X
            view.preferredFramesPerSecond = 60
            view.allowsCameraControl = false
            view.accessibilityLabel = "Interactive three-dimensional Earth with DTC satellites"
            view.accessibilityHint = "Drag to rotate, pinch to zoom, and tap a satellite to select it"

            scene.background.contents = GlobeArtwork.starfield
            scene.rootNode.addChildNode(earthNode)
            scene.rootNode.addChildNode(coastlineLayer)
            scene.rootNode.addChildNode(countryBoundaryLayer)
            scene.rootNode.addChildNode(stateBoundaryLayer)
            scene.rootNode.addChildNode(overlayLayer)
            scene.rootNode.addChildNode(animatedOverlayLayer)
            scene.rootNode.addChildNode(satelliteLayer)
            footprintNode.renderingOrder = 22
            observerLinkNode.renderingOrder = 23
            animatedOverlayLayer.addChildNode(footprintNode)
            animatedOverlayLayer.addChildNode(observerLinkNode)

            let camera = SCNCamera()
            camera.fieldOfView = 43
            camera.zNear = 0.02
            camera.zFar = 100
            camera.wantsHDR = false
            camera.bloomIntensity = 0.16
            camera.bloomThreshold = 1.35
            cameraNode.camera = camera
            cameraNode.position = SCNVector3(0, 0.18, 3.15)
            let lookAt = SCNLookAtConstraint(target: earthNode)
            lookAt.isGimbalLockEnabled = true
            cameraNode.constraints = [lookAt]
            scene.rootNode.addChildNode(cameraNode)
            view.pointOfView = cameraNode

            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 560
            key.light?.temperature = 6_200
            key.eulerAngles = SCNVector3(-0.45, 0.75, 0)
            scene.rootNode.addChildNode(key)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 90
            ambient.light?.color = UIColor(red: 0.20, green: 0.32, blue: 0.52, alpha: 1)
            scene.rootNode.addChildNode(ambient)

            let tap = UITapGestureRecognizer(target: self, action: #selector(didTap(_:)))
            tap.cancelsTouchesInView = false
            tap.delegate = self
            view.addGestureRecognizer(tap)

            let pan = UIPanGestureRecognizer(target: self, action: #selector(didPan(_:)))
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            view.addGestureRecognizer(pan)

            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(didPinch(_:)))
            pinch.delegate = self
            view.addGestureRecognizer(pinch)

            let displayLink = CADisplayLink(target: self, selector: #selector(updateBoundaryVisibility))
            displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 15, maximum: 30, preferred: 30)
            displayLink.add(to: .main, forMode: .common)
            self.displayLink = displayLink
        }

        func stop() {
            parentScrollView?.isScrollEnabled = true
            displayLink?.invalidate()
            displayLink = nil
        }

        func update(
            coastlines: [[ObserverLocation]],
            countryBoundaries: [[ObserverLocation]],
            stateBoundaries: [[ObserverLocation]],
            observations: [SatelliteObservation],
            groundTrack: [GroundTrackPoint],
            observer: ObserverLocation,
            selectedID: Int?,
            serviceCapableIDs: Set<Int>,
            selectedServiceElevationDegrees: Double,
            denseConstellation: Bool,
            resetToken: Int,
            in view: SCNView
        ) {
            let newSignature = coastlines.reduce(0) { $0 &+ $1.count }
            if earthNode.geometry == nil || newSignature != coastlineSignature {
                coastlineSignature = newSignature
                installEarth(coastlines: coastlines)
            }
            let newCountrySignature = countryBoundaries.reduce(0) { $0 &+ $1.count }
            if newCountrySignature != countryBoundarySignature {
                countryBoundarySignature = newCountrySignature
                installCountryBoundaries(countryBoundaries)
            }
            let newStateSignature = stateBoundaries.reduce(0) { $0 &+ $1.count }
            if newStateSignature != stateBoundarySignature {
                stateBoundarySignature = newStateSignature
                installStateBoundaries(stateBoundaries)
            }

            let ids = Set(observations.map(\.id))
            let removedIDs = Set(satelliteNodes.keys).subtracting(ids)
            let shouldResetMotion = resetToken != lastResetToken
            if shouldResetMotion { lastResetToken = resetToken }
            let updatedSampleDate = observations.first?.observedAt
            let isNewSample = updatedSampleDate.map { sample in
                satelliteSampleDate.map { sample > $0 } ?? false
            } ?? false
            let animationDuration: TimeInterval
            if isNewSample, let previousSampleDate = satelliteSampleDate, let updatedSampleDate {
                let sampleGap = updatedSampleDate.timeIntervalSince(previousSampleDate)
                animationDuration = sampleGap <= 7.5 ? min(6, max(1, sampleGap)) : 0
            } else {
                animationDuration = 0
            }

            SCNTransaction.begin()
            SCNTransaction.disableActions = true
            for id in removedIDs {
                satelliteNodes.removeValue(forKey: id)?.removeFromParentNode()
                satelliteStyles.removeValue(forKey: id)
            }
            overlayLayer.childNodes.forEach { $0.removeFromParentNode() }

            for observation in observations {
                let style = SatelliteStyle(
                    selected: observation.id == selectedID,
                    aboveMask: serviceCapableIDs.contains(observation.id),
                    dense: denseConstellation
                )
                if let node = satelliteNodes[observation.id] {
                    if shouldResetMotion {
                        node.removeAllAnimations()
                        node.position = satellitePosition(for: observation)
                    }
                    if satelliteStyles[observation.id] != style {
                        configureSatelliteNode(node, style: style)
                        satelliteStyles[observation.id] = style
                    }
                } else {
                    let node = satelliteNode(for: observation, style: style)
                    node.scale = markerScaleVector
                    satelliteLayer.addChildNode(node)
                    satelliteNodes[observation.id] = node
                    satelliteStyles[observation.id] = style
                }
            }

            let observerMarker = observerNode(at: observer)
            observerMarker.scale = markerScaleVector
            overlayLayer.addChildNode(observerMarker)

            if let selected = observations.first(where: { $0.id == selectedID }) {
                addGroundTrackOverlays(track: groundTrack)
                configureAnimatedOverlays(
                    for: selected,
                    observer: observer,
                    serviceElevationDegrees: selectedServiceElevationDegrees,
                    linkIsDependable: serviceCapableIDs.contains(selected.id)
                )
            } else {
                clearAnimatedOverlays()
            }
            SCNTransaction.commit()

            if isNewSample, animationDuration > 0, !shouldResetMotion {
                SCNTransaction.begin()
                SCNTransaction.animationDuration = animationDuration
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .linear)
                for observation in observations {
                    satelliteNodes[observation.id]?.position = satellitePosition(for: observation)
                }
                SCNTransaction.commit()
            } else if isNewSample {
                SCNTransaction.begin()
                SCNTransaction.disableActions = true
                for observation in observations {
                    satelliteNodes[observation.id]?.removeAllAnimations()
                    satelliteNodes[observation.id]?.position = satellitePosition(for: observation)
                }
                SCNTransaction.commit()
            }
            if let updatedSampleDate, satelliteSampleDate.map({ updatedSampleDate > $0 }) ?? true {
                satelliteSampleDate = updatedSampleDate
            }
            view.setNeedsDisplay()
        }

        private var markerScaleVector: SCNVector3 {
            SCNVector3(currentMarkerScale, currentMarkerScale, currentMarkerScale)
        }

        func apply(
            _ request: GlobeFocusRequest,
            selectedID: Int?,
            observations: [SatelliteObservation],
            observer: ObserverLocation,
            in view: SCNView
        ) {
            guard request.token != lastFocusToken else { return }
            lastFocusToken = request.token

            switch request.target {
            case .observer:
                setCamera(latitude: observer.latitude, longitude: observer.longitude, distance: 2.65, animated: true)
            case .selectedSatellite:
                guard let selected = observations.first(where: { $0.id == selectedID }) else { return }
                setCamera(
                    latitude: selected.state.geodetic.latitude,
                    longitude: selected.state.geodetic.longitude,
                    distance: 2.45,
                    animated: true
                )
            case .wholeEarth:
                setCamera(latitude: 2.18, longitude: 0, distance: 3.15, animated: true)
            }
            view.pointOfView = cameraNode
        }

        private func setCamera(latitude: Double, longitude: Double, distance: Float, animated: Bool) {
            cameraLatitude = min(85, max(-85, latitude))
            cameraLongitude = normalizedLongitude(longitude)
            cameraDistance = min(4.5, max(1.18, distance))

            SCNTransaction.begin()
            SCNTransaction.animationDuration = animated ? 0.65 : 0
            if animated {
                SCNTransaction.animationTimingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            }
            cameraNode.position = cameraPosition(
                latitude: cameraLatitude,
                longitude: cameraLongitude,
                distance: cameraDistance
            )
            SCNTransaction.commit()
        }

        private func normalizedLongitude(_ longitude: Double) -> Double {
            var value = longitude.truncatingRemainder(dividingBy: 360)
            if value > 180 { value -= 360 }
            if value < -180 { value += 360 }
            return value
        }

        private func installEarth(coastlines: [[ObserverLocation]]) {
            let geometry = GlobeGeometry.earthSphere(radius: 1, stacks: 96, slices: 192)
            let material = SCNMaterial()
            material.lightingModel = .blinn
            material.diffuse.contents = GlobeArtwork.earthTexture(coastlines: coastlines)
            material.diffuse.intensity = 0.38
            material.ambient.contents = UIColor(red: 0.01, green: 0.04, blue: 0.08, alpha: 1)
            material.emission.contents = UIColor(red: 0.004, green: 0.018, blue: 0.05, alpha: 1)
            material.emission.intensity = 0.22
            material.specular.contents = UIColor(red: 0.10, green: 0.28, blue: 0.42, alpha: 1)
            material.shininess = 0.08
            geometry.materials = [material]
            earthNode.geometry = geometry

            coastlineLayer.childNodes.forEach { $0.removeFromParentNode() }
            let coastlineLines = coastlines.map { line in
                line.map { GlobeGeometry.position(latitude: $0.latitude, longitude: $0.longitude, radius: 1.007) }
            }
            if let coastlines = GlobeGeometry.polylines(
                coastlineLines,
                color: UIColor(red: 0.25, green: 0.92, blue: 0.72, alpha: 0.9)
            ) {
                coastlines.renderingOrder = 20
                coastlineLayer.addChildNode(coastlines)
            }

            earthNode.childNodes.forEach { $0.removeFromParentNode() }
            let atmosphereGeometry = SCNSphere(radius: 1.018)
            atmosphereGeometry.segmentCount = 128
            let atmosphere = SCNMaterial()
            atmosphere.lightingModel = .constant
            atmosphere.diffuse.contents = UIColor(red: 0.12, green: 0.52, blue: 1, alpha: 0.055)
            atmosphere.emission.contents = UIColor(red: 0.05, green: 0.30, blue: 0.9, alpha: 0.03)
            atmosphere.transparency = 0.09
            atmosphere.blendMode = .add
            atmosphere.isDoubleSided = true
            atmosphere.writesToDepthBuffer = false
            atmosphereGeometry.materials = [atmosphere]
            let atmosphereNode = SCNNode(geometry: atmosphereGeometry)
            atmosphereNode.renderingOrder = 5
            earthNode.addChildNode(atmosphereNode)
        }

        private func installStateBoundaries(_ boundaries: [[ObserverLocation]]) {
            stateBoundaryLayer.childNodes.forEach { $0.removeFromParentNode() }
            let lines = boundaries.map { line in
                line.map { GlobeGeometry.position(latitude: $0.latitude, longitude: $0.longitude, radius: 1.010) }
            }
            if let node = GlobeGeometry.polylines(lines, color: UIColor.white.withAlphaComponent(0.78)) {
                node.renderingOrder = 21
                stateBoundaryLayer.addChildNode(node)
            }
            stateBoundaryLayer.opacity = 0.03
        }

        private func installCountryBoundaries(_ boundaries: [[ObserverLocation]]) {
            countryBoundaryLayer.childNodes.forEach { $0.removeFromParentNode() }
            let lines = boundaries.map { line in
                line.map { GlobeGeometry.position(latitude: $0.latitude, longitude: $0.longitude, radius: 1.009) }
            }
            if let node = GlobeGeometry.polylines(
                lines,
                color: UIColor(red: 0.58, green: 0.83, blue: 0.92, alpha: 0.82)
            ) {
                node.renderingOrder = 21
                countryBoundaryLayer.addChildNode(node)
            }
        }

        private func satelliteNode(for observation: SatelliteObservation, style: SatelliteStyle) -> SCNNode {
            let node = SCNNode()
            node.name = "satellite:\(observation.id)"
            node.position = satellitePosition(for: observation)
            configureSatelliteNode(node, style: style)
            return node
        }

        private func configureSatelliteNode(_ node: SCNNode, style: SatelliteStyle) {
            node.childNodes.forEach { $0.removeFromParentNode() }
            let radius: CGFloat = style.selected ? (style.dense ? 0.008 : 0.010) : (style.dense ? 0.0055 : 0.009)
            let sphere = SCNSphere(radius: radius)
            sphere.segmentCount = style.selected ? 18 : 8
            let material = SCNMaterial()
            material.lightingModel = .constant
            let color: UIColor
            if style.selected {
                color = .cyan
            } else if style.aboveMask {
                color = UIColor(white: 1, alpha: 0.96)
            } else {
                color = UIColor(red: 0.33, green: 0.72, blue: 0.88, alpha: style.dense ? 0.72 : 0.9)
            }
            material.diffuse.contents = color
            material.emission.contents = color
            material.transparency = style.selected ? 1 : (style.dense ? 0.82 : 0.95)
            sphere.materials = [material]
            node.geometry = sphere

            if style.selected {
                let haloGeometry = SCNSphere(radius: radius * 1.45)
                haloGeometry.segmentCount = 20
                let halo = SCNMaterial()
                halo.lightingModel = .constant
                halo.diffuse.contents = UIColor.cyan.withAlphaComponent(0.08)
                halo.emission.contents = UIColor.cyan.withAlphaComponent(0.18)
                halo.transparency = 0.24
                halo.blendMode = .add
                haloGeometry.materials = [halo]
                node.addChildNode(SCNNode(geometry: haloGeometry))
            }
        }

        private func satellitePosition(for observation: SatelliteObservation) -> SCNVector3 {
            let altitudeScale = 1 + Float(max(0, observation.state.geodetic.altitudeKilometers) / 6_378.137)
            return GlobeGeometry.position(
                latitude: observation.state.geodetic.latitude,
                longitude: observation.state.geodetic.longitude,
                radius: altitudeScale
            )
        }

        private func observerNode(at observer: ObserverLocation) -> SCNNode {
            let container = SCNNode()
            container.name = "observer-marker"
            container.position = GlobeGeometry.position(latitude: observer.latitude, longitude: observer.longitude, radius: 1.012)

            let marker = SCNSphere(radius: 0.012)
            marker.segmentCount = 16
            let markerMaterial = SCNMaterial()
            markerMaterial.lightingModel = .constant
            markerMaterial.diffuse.contents = UIColor.systemMint
            markerMaterial.emission.contents = UIColor.systemMint
            marker.materials = [markerMaterial]
            container.addChildNode(SCNNode(geometry: marker))

            let halo = SCNSphere(radius: 0.025)
            halo.segmentCount = 20
            let haloMaterial = SCNMaterial()
            haloMaterial.lightingModel = .constant
            haloMaterial.diffuse.contents = UIColor.systemMint.withAlphaComponent(0.08)
            haloMaterial.emission.contents = UIColor.systemMint.withAlphaComponent(0.12)
            haloMaterial.transparency = 0.25
            haloMaterial.blendMode = .add
            halo.materials = [haloMaterial]
            container.addChildNode(SCNNode(geometry: halo))
            return container
        }

        private func addGroundTrackOverlays(track: [GroundTrackPoint]) {
            let now = Date()
            let past = track.filter { $0.date <= now }.map { GlobeGeometry.position(latitude: $0.latitude, longitude: $0.longitude, radius: 1.006) }
            let future = track.filter { $0.date >= now }.map { GlobeGeometry.position(latitude: $0.latitude, longitude: $0.longitude, radius: 1.008) }
            if let node = GlobeGeometry.polyline(past, color: UIColor.cyan.withAlphaComponent(0.26)) { overlayLayer.addChildNode(node) }
            if let node = GlobeGeometry.polyline(future, color: UIColor.cyan.withAlphaComponent(0.92)) { overlayLayer.addChildNode(node) }
        }

        private func configureAnimatedOverlays(
            for selected: SatelliteObservation,
            observer: ObserverLocation,
            serviceElevationDegrees: Double,
            linkIsDependable: Bool
        ) {
            animatedOverlaySatelliteID = selected.id
            animatedFootprintRadius = footprintAngularRadius(
                for: selected,
                minimumServiceElevationDegrees: serviceElevationDegrees
            )
            animatedObserverPosition = GlobeGeometry.position(
                latitude: observer.latitude,
                longitude: observer.longitude,
                radius: 1.016
            )
            animatedLinkColor = linkIsDependable
                ? UIColor.systemMint.withAlphaComponent(0.68)
                : UIColor.systemOrange.withAlphaComponent(0.42)
            footprintNode.isHidden = false
            observerLinkNode.isHidden = false
            updateAnimatedOverlays()
        }

        private func clearAnimatedOverlays() {
            animatedOverlaySatelliteID = nil
            animatedObserverPosition = nil
            animatedLinkColor = nil
            footprintNode.geometry = nil
            observerLinkNode.geometry = nil
            footprintNode.isHidden = true
            observerLinkNode.isHidden = true
        }

        private func footprintAngularRadius(
            for observation: SatelliteObservation,
            minimumServiceElevationDegrees: Double
        ) -> Double {
            let earthRadius = 6_378.137
            let altitude = max(0, observation.state.geodetic.altitudeKilometers)
            let elevation = min(90, max(0, minimumServiceElevationDegrees)) * .pi / 180
            let ratio = min(1, earthRadius / (earthRadius + altitude))
            return max(0, acos(ratio * cos(elevation)) - elevation)
        }

        private func updateAnimatedOverlays() {
            guard
                let id = animatedOverlaySatelliteID,
                let satellite = satelliteNodes[id],
                let observerPosition = animatedObserverPosition,
                let linkColor = animatedLinkColor
            else { return }

            let satellitePosition = satellite.presentation.position
            let center = simd_normalize(SIMD3<Float>(satellitePosition.x, satellitePosition.y, satellitePosition.z))
            let reference = abs(center.y) < 0.9
                ? SIMD3<Float>(0, 1, 0)
                : SIMD3<Float>(1, 0, 0)
            let tangent = simd_normalize(simd_cross(reference, center))
            let bitangent = simd_normalize(simd_cross(center, tangent))
            let cosineRadius = Float(cos(animatedFootprintRadius))
            let sineRadius = Float(sin(animatedFootprintRadius))
            let earthSurfaceRadius: Float = 1.009
            let points = stride(from: 0.0, to: 360.0, by: 5.0).map { angle -> SCNVector3 in
                let radians = Float(angle * .pi / 180)
                let ringDirection = tangent * cos(radians) + bitangent * sin(radians)
                let point = (center * cosineRadius + ringDirection * sineRadius) * earthSurfaceRadius
                return SCNVector3(point.x, point.y, point.z)
            }

            footprintNode.geometry = GlobeGeometry.polyline(
                points,
                color: UIColor.cyan.withAlphaComponent(0.48),
                closed: true
            )?.geometry
            observerLinkNode.geometry = GlobeGeometry.polyline(
                [observerPosition, satellitePosition],
                color: linkColor
            )?.geometry
        }

        private func cameraPosition(latitude: Double, longitude: Double, distance: Float) -> SCNVector3 {
            GlobeGeometry.position(latitude: latitude, longitude: longitude, radius: distance)
        }

        @objc private func didTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended, let view = recognizer.view as? SCNView else { return }
            let hits = view.hitTest(recognizer.location(in: view), options: [
                SCNHitTestOption.searchMode: SCNHitTestSearchMode.all.rawValue,
                SCNHitTestOption.boundingBoxOnly: true
            ])
            for hit in hits {
                var candidate: SCNNode? = hit.node
                while let node = candidate {
                    if let name = node.name, name.hasPrefix("satellite:"), let id = Int(name.dropFirst("satellite:".count)) {
                        onSelect(id)
                        return
                    }
                    candidate = node.parent
                }
            }
        }

        @objc private func didPan(_ recognizer: UIPanGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                setPageScrollingEnabled(false, from: view)
                recognizer.setTranslation(.zero, in: view)
                return
            case .ended, .cancelled, .failed:
                setPageScrollingEnabled(true, from: view)
                recognizer.setTranslation(.zero, in: view)
                return
            case .changed:
                break
            default:
                return
            }

            let translation = recognizer.translation(in: view)
            let zoomFraction = max(0.08, min(1, (cameraDistance - 1.12) / (3.15 - 1.12)))
            let degreesPerPoint = Double(0.24 * zoomFraction)
            cameraLongitude -= Double(translation.x) * degreesPerPoint
            cameraLatitude += Double(translation.y) * degreesPerPoint
            setCamera(latitude: cameraLatitude, longitude: cameraLongitude, distance: cameraDistance, animated: false)
            recognizer.setTranslation(.zero, in: view)
        }

        @objc private func didPinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let view = recognizer.view else { return }
            switch recognizer.state {
            case .began:
                setPageScrollingEnabled(false, from: view)
                recognizer.scale = 1
                return
            case .ended, .cancelled, .failed:
                setPageScrollingEnabled(true, from: view)
                recognizer.scale = 1
                return
            case .changed:
                break
            default:
                return
            }
            guard recognizer.scale.isFinite, recognizer.scale > 0 else { return }
            let earthClearance = max(0.12, cameraDistance - 1.06)
            let adjustedClearance = earthClearance / Float(recognizer.scale)
            setCamera(
                latitude: cameraLatitude,
                longitude: cameraLongitude,
                distance: 1.06 + adjustedClearance,
                animated: false
            )
            recognizer.scale = 1
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer.view === otherGestureRecognizer.view
        }

        private func setPageScrollingEnabled(_ enabled: Bool, from view: UIView) {
            if parentScrollView == nil {
                var ancestor = view.superview
                while let current = ancestor {
                    if let scrollView = current as? UIScrollView {
                        parentScrollView = scrollView
                        break
                    }
                    ancestor = current.superview
                }
            }
            parentScrollView?.isScrollEnabled = enabled
        }

        @objc private func updateBoundaryVisibility() {
            let position = cameraNode.presentation.position
            let distance = sqrt(position.x * position.x + position.y * position.y + position.z * position.z)
            let zoomProgress = max(0, min(1, (3.0 - distance) / 1.3))
            stateBoundaryLayer.opacity = CGFloat(0.03 + zoomProgress * 0.78)

            let markerScale = max(0.06, min(1.5, (distance - 1.06) / (3.15 - 1.06)))
            currentMarkerScale = markerScale
            satelliteLayer.childNodes.forEach { $0.scale = markerScaleVector }
            overlayLayer.childNodes
                .filter { $0.name == "observer-marker" }
                .forEach { $0.scale = markerScaleVector }
            updateAnimatedOverlays()
        }
    }
}

@MainActor
private enum GlobeArtwork {
    static let starfield: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 1_024, height: 1_024), format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.black.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 1_024, height: 1_024))
            var seed: UInt64 = 0xD1CE_CE11
            func random() -> CGFloat {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1
                return CGFloat((seed >> 33) & 0xFFFF) / CGFloat(0xFFFF)
            }
            for _ in 0..<430 {
                let diameter = 0.45 + random() * 1.55
                let alpha = 0.18 + random() * 0.58
                context.setFillColor(UIColor(white: 1, alpha: alpha).cgColor)
                context.fillEllipse(in: CGRect(x: random() * 1_024, y: random() * 1_024, width: diameter, height: diameter))
            }
        }
    }()

    static func earthTexture(coastlines: [[ObserverLocation]]) -> UIImage {
        let size = CGSize(width: 2_048, height: 1_024)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            let colors = [
                UIColor(red: 0.006, green: 0.025, blue: 0.075, alpha: 1).cgColor,
                UIColor(red: 0.010, green: 0.072, blue: 0.135, alpha: 1).cgColor,
                UIColor(red: 0.003, green: 0.018, blue: 0.058, alpha: 1).cgColor
            ] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.5, 1]) {
                context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }

            context.setLineWidth(1)
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.075).cgColor)
            for longitude in stride(from: -180.0, through: 180, by: 30) {
                let x = CGFloat((longitude + 180) / 360) * size.width
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: size.height))
            }
            for latitude in stride(from: -60.0, through: 60, by: 30) {
                let y = CGFloat((90 - latitude) / 180) * size.height
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.strokePath()

            for polygon in coastlines {
                let points = unwrap(polygon)
                for shift in -1...1 {
                    context.beginPath()
                    for (index, point) in points.enumerated() {
                        let shiftedLongitude = point.longitude + Double(shift * 360)
                        let mapped = CGPoint(
                            x: CGFloat((shiftedLongitude + 180) / 360) * size.width,
                            y: CGFloat((90 - point.latitude) / 180) * size.height
                        )
                        index == 0 ? context.move(to: mapped) : context.addLine(to: mapped)
                    }
                    context.closePath()
                    context.setFillColor(UIColor(red: 0.035, green: 0.20, blue: 0.175, alpha: 1).cgColor)
                    context.setStrokeColor(UIColor(red: 0.22, green: 0.58, blue: 0.48, alpha: 0.35).cgColor)
                    context.setLineWidth(1.5)
                    context.drawPath(using: .fillStroke)
                }
            }
        }
    }

    private static func unwrap(_ points: [ObserverLocation]) -> [ObserverLocation] {
        guard let first = points.first else { return [] }
        var output = [first]
        for point in points.dropFirst() {
            var longitude = point.longitude
            let previous = output[output.count - 1].longitude
            while longitude - previous > 180 { longitude -= 360 }
            while longitude - previous < -180 { longitude += 360 }
            output.append(ObserverLocation(latitude: point.latitude, longitude: longitude, altitudeKilometers: point.altitudeKilometers))
        }
        return output
    }
}

private enum GlobeGeometry {
    static func position(latitude: Double, longitude: Double, radius: Float) -> SCNVector3 {
        let latitudeRadians = Float(latitude * .pi / 180)
        let longitudeRadians = Float(longitude * .pi / 180)
        let horizontal = cos(latitudeRadians)
        return SCNVector3(
            radius * horizontal * sin(longitudeRadians),
            radius * sin(latitudeRadians),
            radius * horizontal * cos(longitudeRadians)
        )
    }

    static func earthSphere(radius: Float, stacks: Int, slices: Int) -> SCNGeometry {
        var vertices: [SCNVector3] = []
        var normals: [SCNVector3] = []
        var textureCoordinates: [CGPoint] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity((stacks + 1) * (slices + 1))

        for row in 0...stacks {
            let rowFraction = Float(row) / Float(stacks)
            let latitude = Float.pi / 2 - rowFraction * Float.pi
            for column in 0...slices {
                let columnFraction = Float(column) / Float(slices)
                let longitude = -Float.pi + columnFraction * 2 * Float.pi
                let horizontal = cos(latitude)
                let normal = SCNVector3(horizontal * sin(longitude), sin(latitude), horizontal * cos(longitude))
                vertices.append(SCNVector3(normal.x * radius, normal.y * radius, normal.z * radius))
                normals.append(normal)
                textureCoordinates.append(CGPoint(x: CGFloat(columnFraction), y: CGFloat(rowFraction)))
            }
        }

        let rowLength = slices + 1
        for row in 0..<stacks {
            for column in 0..<slices {
                let upperLeft = UInt32(row * rowLength + column)
                let lowerLeft = UInt32((row + 1) * rowLength + column)
                indices.append(contentsOf: [upperLeft, lowerLeft, upperLeft + 1, upperLeft + 1, lowerLeft, lowerLeft + 1])
            }
        }

        let geometry = SCNGeometry(
            sources: [
                SCNGeometrySource(vertices: vertices),
                SCNGeometrySource(normals: normals),
                SCNGeometrySource(textureCoordinates: textureCoordinates)
            ],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        return geometry
    }

    static func polyline(_ points: [SCNVector3], color: UIColor, closed: Bool = false) -> SCNNode? {
        guard points.count >= 2 else { return nil }
        var indices: [UInt32] = []
        for index in 0..<(points.count - 1) {
            indices.append(UInt32(index))
            indices.append(UInt32(index + 1))
        }
        if closed {
            indices.append(UInt32(points.count - 1))
            indices.append(0)
        }
        let source = SCNGeometrySource(vertices: points)
        let element = SCNGeometryElement(indices: indices, primitiveType: .line)
        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    static func polylines(_ lines: [[SCNVector3]], color: UIColor) -> SCNNode? {
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        for line in lines where line.count >= 2 {
            let offset = UInt32(vertices.count)
            vertices.append(contentsOf: line)
            for index in 0..<(line.count - 1) {
                indices.append(offset + UInt32(index))
                indices.append(offset + UInt32(index + 1))
            }
        }
        guard !vertices.isEmpty else { return nil }
        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .line)]
        )
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = color
        material.emission.contents = color
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }
}

struct LegendDot: View {
    let color: Color
    let text: String
    var body: some View {
        Label { Text(text) } icon: { Circle().fill(color).frame(width: 7, height: 7) }
            .font(.caption2).foregroundStyle(.secondary)
    }
}

private struct LegendLine: View {
    let color: Color
    let dashed: Bool
    let text: String

    var body: some View {
        HStack(spacing: 4) {
            Canvas { context, size in
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [3, 2] : []))
            }
            .frame(width: 14, height: 7)
            Text(text)
        }
        .font(.caption2).foregroundStyle(.secondary)
    }
}
