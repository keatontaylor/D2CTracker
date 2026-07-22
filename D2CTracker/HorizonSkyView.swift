import SwiftUI
import D2CTrackerCore

/// A roll-independent, instrument-style view of the local sky. The center reticle
/// follows the phone's top edge while the rendered horizon always remains level.
struct HorizonSkyView: View {
    let observations: [SatelliteObservation]
    let selectedID: Int?
    let candidateID: Int?
    let elevationMask: Double
    let representativeSatelliteAltitude: Double
    let terrainHorizon: TerrainHorizonProfile?
    let headingDegrees: Double?
    let viewportElevationDegrees: Double?
    let resetToken: Int
    let onSelect: (Int?) -> Void

    @State private var satelliteMotion = HorizonSatelliteMotion()
    @State private var viewportMotion = HorizonViewportMotion()

    private let horizontalFieldOfView = 100.0
    private let verticalFieldOfView = 76.0

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            GeometryReader { geometry in
                let viewport = viewportMotion.value(at: timeline.date)
                let positions = satelliteMotion.positions(at: timeline.date)
                let pointedTarget = pointedSatellite(viewport: viewport, positions: positions)

                ZStack(alignment: .topLeading) {
                    Canvas { context, size in
                        drawBackground(context: &context, size: size)
                        drawElevationGrid(context: &context, size: size, viewport: viewport)
                        drawAzimuthGrid(context: &context, size: size, viewport: viewport)
                        drawHorizonMasks(context: &context, size: size, viewport: viewport)
                        drawLinkEnvelopes(context: &context, size: size, viewport: viewport)
                        drawSatellites(
                            context: &context,
                            size: size,
                            viewport: viewport,
                            positions: positions,
                            pointedID: pointedTarget?.observation.id
                        )
                        drawReticle(
                            context: &context,
                            size: size,
                            viewport: viewport,
                            locked: pointedTarget != nil
                        )
                    }

                    if let pointedTarget {
                        PointedSatelliteHUD(
                            target: pointedTarget,
                            isLikelyServing: pointedTarget.observation.id == candidateID,
                            elevationMask: elevationMask,
                            terrainHorizon: terrainHorizon
                        )
                        .padding(11)
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .topLeading)))
                        .allowsHitTesting(false)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture().onEnded { value in
                    selectNearest(
                        to: value.location,
                        size: geometry.size,
                        viewport: viewportMotion.value(at: .now),
                        positions: satelliteMotion.positions(at: .now)
                    )
                })
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Orientation-controlled horizon sky")
                .accessibilityValue(accessibilityValue(viewport: viewport))
            }
        }
        .onAppear {
            retargetViewport(at: .now, animated: false)
            updateSatelliteMotion(at: .now)
        }
        .onChange(of: headingDegrees) { _, _ in retargetViewport(at: .now, animated: true) }
        .onChange(of: viewportElevationDegrees) { _, _ in retargetViewport(at: .now, animated: true) }
        .onChange(of: observations) { _, _ in updateSatelliteMotion(at: .now) }
        .onChange(of: resetToken) { _, _ in
            satelliteMotion = HorizonSatelliteMotion()
            viewportMotion = HorizonViewportMotion()
            retargetViewport(at: .now, animated: false)
            updateSatelliteMotion(at: .now)
        }
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let bounds = CGRect(origin: .zero, size: size)
        context.fill(
            Path(bounds),
            with: .linearGradient(
                Gradient(colors: [
                    Color(red: 0.03, green: 0.16, blue: 0.29),
                    Color(red: 0.025, green: 0.075, blue: 0.15),
                    Color(red: 0.015, green: 0.025, blue: 0.06)
                ]),
                startPoint: CGPoint(x: size.width / 2, y: 0),
                endPoint: CGPoint(x: size.width / 2, y: size.height)
            )
        )

        for index in 0..<26 {
            let x = CGFloat((index * 73) % 101) / 100 * size.width
            let y = CGFloat((index * 47) % 83) / 100 * size.height
            let radius: CGFloat = index.isMultiple(of: 5) ? 1.1 : 0.65
            context.fill(
                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                with: .color(.white.opacity(index.isMultiple(of: 5) ? 0.38 : 0.20))
            )
        }
    }

    private func drawElevationGrid(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport
    ) {
        let minimum = max(-30, floor((viewport.elevation - verticalFieldOfView / 2) / 10) * 10)
        let maximum = min(90, ceil((viewport.elevation + verticalFieldOfView / 2) / 10) * 10)
        guard minimum <= maximum else { return }

        for elevation in stride(from: minimum, through: maximum, by: 10) {
            let y = project(
                azimuth: viewport.heading,
                elevation: elevation,
                size: size,
                viewport: viewport
            ).y
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(
                line,
                with: .color(.white.opacity(elevation == 0 ? 0.30 : 0.085)),
                style: StrokeStyle(lineWidth: elevation == 0 ? 1.4 : 0.7, dash: elevation == 0 ? [] : [3, 5])
            )
            if y > 18, y < size.height - 10 {
                context.draw(
                    Text("\(Int(elevation))°")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.55)),
                    at: CGPoint(x: 8, y: y - 3),
                    anchor: .bottomLeading
                )
            }
        }
    }

    private func drawAzimuthGrid(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport
    ) {
        let minimum = floor((viewport.heading - horizontalFieldOfView / 2) / 15) * 15
        let maximum = ceil((viewport.heading + horizontalFieldOfView / 2) / 15) * 15

        for rawAzimuth in stride(from: minimum, through: maximum, by: 15) {
            let x = project(
                azimuth: rawAzimuth,
                elevation: viewport.elevation,
                size: size,
                viewport: viewport
            ).x
            guard x >= 0, x <= size.width else { continue }
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: size.height))
            let major = Int(rawAzimuth.rounded()).isMultiple(of: 45)
            context.stroke(line, with: .color(.white.opacity(major ? 0.11 : 0.045)), lineWidth: major ? 0.8 : 0.5)

            if major {
                let normalized = CoordinateTransforms.normalizedDegrees(rawAzimuth)
                context.draw(
                    Text(compassLabel(normalized))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(normalized < 1 || normalized > 359 ? .cyan : .white.opacity(0.66)),
                    at: CGPoint(x: x, y: 10),
                    anchor: .top
                )
            }
        }
    }

    private func drawHorizonMasks(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport
    ) {
        let groundSamples = horizonSamples(size: size, viewport: viewport) { azimuth in
            terrainHorizon?.minimumElevationDegrees(atAzimuth: azimuth) ?? 0
        }
        context.fill(areaBelow(samples: groundSamples, size: size), with: .linearGradient(
            Gradient(colors: [Color.brown.opacity(0.52), Color.black.opacity(0.84)]),
            startPoint: CGPoint(x: size.width / 2, y: size.height * 0.4),
            endPoint: CGPoint(x: size.width / 2, y: size.height)
        ))

        let rfSamples = horizonSamples(size: size, viewport: viewport) { azimuth in
            max(elevationMask, terrainHorizon?.rfHorizonDegrees(atAzimuth: azimuth) ?? 0)
        }
        let blockedArea = areaBetween(upper: rfSamples, lower: groundSamples)
        context.fill(blockedArea, with: .color(.orange.opacity(0.12)))

        context.stroke(
            polyline(groundSamples),
            with: .color(terrainHorizon == nil ? .white.opacity(0.52) : .mint.opacity(0.92)),
            style: StrokeStyle(lineWidth: 1.8, lineJoin: .round)
        )
        context.stroke(
            polyline(rfSamples),
            with: .color(.yellow.opacity(0.9)),
            style: StrokeStyle(lineWidth: 1.2, lineJoin: .round, dash: [5, 4])
        )
    }

    private func drawLinkEnvelopes(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport
    ) {
        let possible = linkEnvelopeSamples(size: size, viewport: viewport, targetMarginDB: 0)
        let dependable = linkEnvelopeSamples(
            size: size,
            viewport: viewport,
            targetMarginDB: D2CUplinkBudget.dependableMarginDB
        )
        context.stroke(
            polyline(possible),
            with: .color(.indigo.opacity(0.95)),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [5, 4])
        )
        context.stroke(
            polyline(dependable),
            with: .color(.pink.opacity(0.96)),
            style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawSatellites(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport,
        positions: [Int: HorizonSatellitePosition],
        pointedID: Int?
    ) {
        for observation in observations.reversed() {
            let position = positions[observation.id]
                ?? HorizonSatellitePosition(
                    azimuth: observation.azimuthDegrees,
                    elevation: observation.elevationDegrees
                )
            let point = project(
                azimuth: position.azimuth,
                elevation: position.elevation,
                size: size,
                viewport: viewport
            )
            guard contains(point, in: size, inset: -12) else { continue }

            let selected = observation.id == selectedID
            let candidate = observation.id == candidateID
            let pointed = observation.id == pointedID
            let terrainEdge = max(
                elevationMask,
                terrainHorizon?.rfHorizonDegrees(atAzimuth: position.azimuth) ?? 0
            )
            let assessment = D2CUplinkBudget.clearSkyAssessment(for: observation)
            let quality = position.elevation >= terrainEdge ? assessment.quality : .unavailable
            let radius: CGFloat = selected ? 7.5 : ((candidate || pointed) ? 6.2 : 4.2)

            if selected || candidate || pointed {
                let haloRadius: CGFloat = selected ? 16 : 13
                context.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - haloRadius,
                        y: point.y - haloRadius,
                        width: haloRadius * 2,
                        height: haloRadius * 2
                    )),
                    with: .color((selected ? Color.cyan : Color.mint).opacity(0.18))
                )
            }

            context.fill(
                Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)),
                with: .color(selected ? .cyan : satelliteColor(quality))
            )
            if candidate {
                context.stroke(
                    Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)),
                    with: .color(.mint.opacity(0.9)),
                    lineWidth: 1.2
                )
            }
            if pointed {
                context.stroke(
                    Path(ellipseIn: CGRect(x: point.x - 12, y: point.y - 12, width: 24, height: 24)),
                    with: .color(.cyan.opacity(0.92)),
                    style: StrokeStyle(lineWidth: 1.4, dash: [3, 2])
                )
            }
            if selected || candidate {
                let title = candidate ? "SERVING · \(shortName(observation.satellite.elements.name))" : shortName(observation.satellite.elements.name)
                context.draw(
                    Text(title)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white),
                    at: CGPoint(x: point.x, y: point.y - 14),
                    anchor: .bottom
                )
            }
        }

        drawServingEdgeIndicator(
            context: &context,
            size: size,
            viewport: viewport,
            positions: positions
        )
    }

    private func drawServingEdgeIndicator(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport,
        positions: [Int: HorizonSatellitePosition]
    ) {
        guard
            let candidateID,
            let observation = observations.first(where: { $0.id == candidateID })
        else { return }
        let position = positions[candidateID]
            ?? HorizonSatellitePosition(azimuth: observation.azimuthDegrees, elevation: observation.elevationDegrees)
        let target = project(
            azimuth: position.azimuth,
            elevation: position.elevation,
            size: size,
            viewport: viewport
        )
        guard !contains(target, in: size, inset: 12) else { return }

        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let dx = target.x - center.x
        let dy = target.y - center.y
        let scaleX = dx == 0 ? .infinity : (size.width / 2 - 18) / abs(dx)
        let scaleY = dy == 0 ? .infinity : (size.height / 2 - 18) / abs(dy)
        let scale = min(scaleX, scaleY)
        let anchor = CGPoint(x: center.x + dx * scale, y: center.y + dy * scale)
        let length = max(1, hypot(dx, dy))
        let unit = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -unit.y, y: unit.x)

        var arrow = Path()
        arrow.move(to: anchor)
        arrow.addLine(to: CGPoint(
            x: anchor.x - unit.x * 13 + normal.x * 5,
            y: anchor.y - unit.y * 13 + normal.y * 5
        ))
        arrow.addLine(to: CGPoint(
            x: anchor.x - unit.x * 13 - normal.x * 5,
            y: anchor.y - unit.y * 13 - normal.y * 5
        ))
        arrow.closeSubpath()
        context.fill(arrow, with: .color(.mint))

        let labelPoint = CGPoint(x: anchor.x - unit.x * 20, y: anchor.y - unit.y * 20)
        context.draw(
            Text("SERVING")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(.mint),
            at: labelPoint
        )
    }

    private func drawReticle(
        context: inout GraphicsContext,
        size: CGSize,
        viewport: HorizonViewport,
        locked: Bool
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        var reticle = Path()
        reticle.move(to: CGPoint(x: center.x - 22, y: center.y))
        reticle.addLine(to: CGPoint(x: center.x - 7, y: center.y))
        reticle.move(to: CGPoint(x: center.x + 7, y: center.y))
        reticle.addLine(to: CGPoint(x: center.x + 22, y: center.y))
        reticle.move(to: CGPoint(x: center.x, y: center.y - 22))
        reticle.addLine(to: CGPoint(x: center.x, y: center.y - 7))
        reticle.move(to: CGPoint(x: center.x, y: center.y + 7))
        reticle.addLine(to: CGPoint(x: center.x, y: center.y + 22))
        let reticleColor: Color = locked ? .mint : .cyan
        context.stroke(reticle, with: .color(reticleColor.opacity(0.95)), lineWidth: locked ? 2 : 1.5)
        context.stroke(
            Path(ellipseIn: CGRect(x: center.x - 4, y: center.y - 4, width: 8, height: 8)),
            with: .color(reticleColor.opacity(0.82)),
            lineWidth: locked ? 1.5 : 1
        )

        let normalizedHeading = CoordinateTransforms.normalizedDegrees(viewport.heading)
        context.draw(
            Text(String(format: "%03.0f° %@", normalizedHeading, compassLabel(normalizedHeading)))
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan),
            at: CGPoint(x: size.width / 2, y: size.height - 12),
            anchor: .bottom
        )
        context.draw(
            Text(String(format: "%+.0f° EL", viewport.elevation))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.75)),
            at: CGPoint(x: size.width - 10, y: size.height - 12),
            anchor: .bottomTrailing
        )
    }

    private func horizonSamples(
        size: CGSize,
        viewport: HorizonViewport,
        elevation: (Double) -> Double
    ) -> [CGPoint] {
        let count = max(60, Int(size.width / 4))
        return (0...count).map { index in
            let fraction = Double(index) / Double(count)
            let azimuth = viewport.heading + (fraction - 0.5) * horizontalFieldOfView
            return project(
                azimuth: azimuth,
                elevation: elevation(CoordinateTransforms.normalizedDegrees(azimuth)),
                size: size,
                viewport: viewport
            )
        }
    }

    private func linkEnvelopeSamples(
        size: CGSize,
        viewport: HorizonViewport,
        targetMarginDB: Double
    ) -> [CGPoint] {
        let count = max(60, Int(size.width / 4))
        return (0...count).map { index in
            let fraction = Double(index) / Double(count)
            let rawAzimuth = viewport.heading + (fraction - 0.5) * horizontalFieldOfView
            let azimuth = CoordinateTransforms.normalizedDegrees(rawAzimuth)
            let linkElevation = D2CUplinkBudget.minimumClearSkyElevationDegrees(
                satelliteAltitudeKilometers: representativeSatelliteAltitude,
                targetMarginDB: targetMarginDB
            )
            let terrainElevation = terrainHorizon?.rfHorizonDegrees(atAzimuth: azimuth) ?? 0
            return project(
                azimuth: rawAzimuth,
                elevation: max(linkElevation, terrainElevation),
                size: size,
                viewport: viewport
            )
        }
    }

    private func project(
        azimuth: Double,
        elevation: Double,
        size: CGSize,
        viewport: HorizonViewport
    ) -> CGPoint {
        let delta = shortestAngularDelta(from: viewport.heading, to: azimuth)
        return CGPoint(
            x: size.width / 2 + CGFloat(delta / horizontalFieldOfView) * size.width,
            y: size.height / 2 - CGFloat((elevation - viewport.elevation) / verticalFieldOfView) * size.height
        )
    }

    private func shortestAngularDelta(from origin: Double, to target: Double) -> Double {
        var delta = (target - origin).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    private func polyline(_ samples: [CGPoint]) -> Path {
        var path = Path()
        guard let first = samples.first else { return path }
        path.move(to: first)
        for point in samples.dropFirst() { path.addLine(to: point) }
        return path
    }

    private func areaBelow(samples: [CGPoint], size: CGSize) -> Path {
        var path = polyline(samples)
        guard let first = samples.first, let last = samples.last else { return path }
        path.addLine(to: CGPoint(x: last.x, y: size.height))
        path.addLine(to: CGPoint(x: first.x, y: size.height))
        path.closeSubpath()
        return path
    }

    private func areaBetween(upper: [CGPoint], lower: [CGPoint]) -> Path {
        var path = Path()
        guard let first = upper.first else { return path }
        path.move(to: first)
        for point in upper.dropFirst() { path.addLine(to: point) }
        for point in lower.reversed() { path.addLine(to: point) }
        path.closeSubpath()
        return path
    }

    private func contains(_ point: CGPoint, in size: CGSize, inset: CGFloat) -> Bool {
        CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset).contains(point)
    }

    private func satelliteColor(_ quality: D2CUplinkQuality) -> Color {
        switch quality {
        case .unavailable: .orange.opacity(0.62)
        case .possible: .indigo
        case .dependable: .white
        case .strong: .mint
        }
    }

    private func compassLabel(_ degrees: Double) -> String {
        let labels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        return labels[Int((CoordinateTransforms.normalizedDegrees(degrees) / 45).rounded()) % labels.count]
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "STARLINK-", with: "SL-")
    }

    private func retargetViewport(at date: Date, animated: Bool) {
        viewportMotion.retarget(
            heading: headingDegrees ?? 0,
            elevation: min(90, max(-25, viewportElevationDegrees ?? 0)),
            at: date,
            duration: animated ? 0.22 : 0
        )
    }

    private func updateSatelliteMotion(at date: Date) {
        let targets = Dictionary(uniqueKeysWithValues: observations.map {
            ($0.id, HorizonSatellitePosition(azimuth: $0.azimuthDegrees, elevation: $0.elevationDegrees))
        })
        satelliteMotion.retarget(
            to: targets,
            sampleDate: observations.first?.observedAt,
            at: date
        )
    }

    private func selectNearest(
        to point: CGPoint,
        size: CGSize,
        viewport: HorizonViewport,
        positions: [Int: HorizonSatellitePosition]
    ) {
        let nearest = observations.compactMap { observation -> (Int, CGFloat)? in
            let position = positions[observation.id]
                ?? HorizonSatellitePosition(azimuth: observation.azimuthDegrees, elevation: observation.elevationDegrees)
            let mapped = project(
                azimuth: position.azimuth,
                elevation: position.elevation,
                size: size,
                viewport: viewport
            )
            guard contains(mapped, in: size, inset: 0) else { return nil }
            return (observation.id, hypot(mapped.x - point.x, mapped.y - point.y))
        }.min { $0.1 < $1.1 }
        onSelect((nearest?.1 ?? .infinity) < 38 ? nearest?.0 : nil)
    }

    private func pointedSatellite(
        viewport: HorizonViewport,
        positions: [Int: HorizonSatellitePosition]
    ) -> PointedSatelliteTarget? {
        observations.compactMap { observation -> PointedSatelliteTarget? in
            let position = positions[observation.id]
                ?? HorizonSatellitePosition(
                    azimuth: observation.azimuthDegrees,
                    elevation: observation.elevationDegrees
                )
            let separation = D2CUplinkBudget.angularSeparationDegrees(
                firstAzimuthDegrees: position.azimuth,
                firstElevationDegrees: position.elevation,
                secondAzimuthDegrees: viewport.heading,
                secondElevationDegrees: viewport.elevation
            )
            guard separation <= 7.5 else { return nil }
            return PointedSatelliteTarget(
                observation: observation,
                position: position,
                separationDegrees: separation
            )
        }.min { $0.separationDegrees < $1.separationDegrees }
    }

    private func accessibilityValue(viewport: HorizonViewport) -> String {
        let heading = CoordinateTransforms.normalizedDegrees(viewport.heading)
        return "Heading \(Int(heading)) degrees, elevation \(Int(viewport.elevation)) degrees. Roll is ignored."
    }
}

private struct HorizonViewport {
    let heading: Double
    let elevation: Double
}

private struct PointedSatelliteTarget {
    let observation: SatelliteObservation
    let position: HorizonSatellitePosition
    let separationDegrees: Double
}

private struct PointedSatelliteHUD: View {
    let target: PointedSatelliteTarget
    let isLikelyServing: Bool
    let elevationMask: Double
    let terrainHorizon: TerrainHorizonProfile?

    private var assessment: D2CUplinkAssessment {
        D2CUplinkBudget.clearSkyAssessment(for: target.observation)
    }

    private var terrainClearanceDegrees: Double {
        target.position.elevation - max(
            elevationMask,
            terrainHorizon?.rfHorizonDegrees(atAzimuth: target.position.azimuth) ?? 0
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: isLikelyServing ? "antenna.radiowaves.left.and.right" : "scope")
                    .foregroundStyle(isLikelyServing ? .mint : .cyan)
                Text(shortName(target.observation.satellite.elements.name))
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                if isLikelyServing {
                    Text("SERVING")
                        .font(.system(size: 7, weight: .black, design: .rounded))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(.mint, in: Capsule())
                }
            }

            Text(String(
                format: "AZ %03.0f°  ·  EL %.1f°  ·  %.0f km",
                CoordinateTransforms.normalizedDegrees(target.position.azimuth),
                target.position.elevation,
                target.observation.slantRangeKilometers
            ))
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.78))

            HStack(spacing: 10) {
                Label(
                    String(format: "%+.1f dB", assessment.adjustedMarginDB),
                    systemImage: "arrow.up.to.line.compact"
                )
                .foregroundStyle(qualityColor(assessment.quality))

                Label(
                    terrainClearanceDegrees >= 0
                        ? String(format: "%+.1f° clear", terrainClearanceDegrees)
                        : "terrain blocked",
                    systemImage: terrainClearanceDegrees >= 0 ? "mountain.2" : "exclamationmark.triangle.fill"
                )
                .foregroundStyle(terrainClearanceDegrees >= 0 ? .yellow : .orange)
            }
            .font(.system(size: 9, weight: .semibold, design: .rounded))

            Text(String(format: "%.1f° off reticle · tap to select", target.separationDegrees))
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: 265, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((isLikelyServing ? Color.mint : Color.cyan).opacity(0.35), lineWidth: 1)
        }
    }

    private func shortName(_ name: String) -> String {
        name.replacingOccurrences(of: "STARLINK-", with: "SL-")
    }

    private func qualityColor(_ quality: D2CUplinkQuality) -> Color {
        switch quality {
        case .unavailable: .orange
        case .possible: .indigo
        case .dependable: .pink
        case .strong: .mint
        }
    }
}

private struct HorizonViewportMotion {
    private var start = HorizonViewport(heading: 0, elevation: 15)
    private var target = HorizonViewport(heading: 0, elevation: 15)
    private var startedAt = Date.distantPast
    private var duration: TimeInterval = 0
    private var initialized = false

    mutating func retarget(
        heading: Double,
        elevation: Double,
        at date: Date,
        duration requestedDuration: TimeInterval
    ) {
        guard initialized else {
            start = HorizonViewport(heading: heading, elevation: elevation)
            target = start
            startedAt = date
            duration = 0
            initialized = true
            return
        }

        let current = value(at: date)
        var headingDelta = (heading - current.heading).truncatingRemainder(dividingBy: 360)
        if headingDelta > 180 { headingDelta -= 360 }
        if headingDelta < -180 { headingDelta += 360 }
        start = current
        target = HorizonViewport(heading: current.heading + headingDelta, elevation: elevation)
        startedAt = date
        duration = requestedDuration
    }

    func value(at date: Date) -> HorizonViewport {
        guard duration > 0 else { return target }
        let linear = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
        let fraction = 1 - pow(1 - linear, 3)
        return HorizonViewport(
            heading: start.heading + (target.heading - start.heading) * fraction,
            elevation: start.elevation + (target.elevation - start.elevation) * fraction
        )
    }
}

private struct HorizonSatellitePosition {
    let azimuth: Double
    let elevation: Double
}

private struct HorizonSatelliteMotion {
    private var start: [Int: HorizonSatellitePosition] = [:]
    private var target: [Int: HorizonSatellitePosition] = [:]
    private var startedAt = Date.distantPast
    private var duration: TimeInterval = 0
    private var sampleDate: Date?

    mutating func retarget(
        to updated: [Int: HorizonSatellitePosition],
        sampleDate updatedSampleDate: Date?,
        at date: Date
    ) {
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
        if let sampleDate, let updatedSampleDate, updatedSampleDate > sampleDate {
            let sampleGap = updatedSampleDate.timeIntervalSince(sampleDate)
            duration = sampleGap <= 7.5 ? min(6, max(1, sampleGap)) : 0
        } else {
            duration = 0
        }
        sampleDate = updatedSampleDate
    }

    func positions(at date: Date) -> [Int: HorizonSatellitePosition] {
        guard duration > 0 else { return target }
        let fraction = min(1, max(0, date.timeIntervalSince(startedAt) / duration))
        return Dictionary(uniqueKeysWithValues: target.map { id, destination in
            guard let origin = start[id] else { return (id, destination) }
            var azimuthDelta = (destination.azimuth - origin.azimuth).truncatingRemainder(dividingBy: 360)
            if azimuthDelta > 180 { azimuthDelta -= 360 }
            if azimuthDelta < -180 { azimuthDelta += 360 }
            return (
                id,
                HorizonSatellitePosition(
                    azimuth: CoordinateTransforms.normalizedDegrees(origin.azimuth + azimuthDelta * fraction),
                    elevation: origin.elevation + (destination.elevation - origin.elevation) * fraction
                )
            )
        })
    }
}
