import Charts
import SwiftUI
import D2CTrackerCore

struct TrackingView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var connectivity: ConnectivityMonitor
    @EnvironmentObject private var location: LocationService
    @EnvironmentObject private var linkQuality: LinkQualityService
    @State private var scoreComponentsExpanded = false

    var body: some View {
        ZStack {
            AppBackdrop()
            ScrollView {
                LazyVStack(spacing: 14) {
                    statusStrip
                    candidateCard
                    if linkQuality.isEnabled || !linkQuality.samples.isEmpty {
                        linkQualityCard
                    }
                    if let observation = model.observations.first(where: { $0.id == model.estimate.satellite?.id }) {
                        geometryCard(observation)
                    }
                    if let diagnostics = model.estimate.selectedDiagnostics {
                        linkDiagnosticsCard(diagnostics)
                        alternativesCard(diagnostics)
                    }
                    backgroundTrackingCard
                    explanationCard
                    dataCard
                    disclaimer
                }
                .padding()
            }
        }
        .navigationTitle("Direct to Cell")
        .preferredColorScheme(.dark)
    }

    private var statusStrip: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Label(connectivity.mode.displayName, systemImage: connectivity.mode.symbol)
                Spacer()
                Label(locationLabel, systemImage: location.location == nil && !model.usesManualLocation ? "location.slash" : "location.fill")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)

            InputStatusBadges(statuses: model.inputStatuses)
        }
    }

    private var locationLabel: String {
        if model.usesManualLocation { return "Manual location" }
        if location.location != nil { return location.isReducedAccuracy ? "Approximate location" : "Current location" }
        return location.authorization == .notDetermined ? "Waiting for location access" : "Waiting for GPS"
    }

    private var candidateCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Likely serving satellite", systemImage: "antenna.radiowaves.left.and.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.cyan)
                    Spacer()
                    ConfidenceBadge(confidence: model.estimate.confidence)
                }

                Text(model.estimate.satellite?.elements.name ?? "No candidate visible")
                    .font(.title2.weight(.bold))
                    .contentTransition(.numericText())

                Text(candidateSummary)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                if let handoffAt = model.estimate.estimatedHandoffAt,
                   model.estimate.satellite != nil {
                    Label("Likely handoff in \(timeUntil(handoffAt))", systemImage: "arrow.trianglehead.swap")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.mint)
                }

                Divider().overlay(.white.opacity(0.12))

                Label("Satellite connection not confirmed by iOS", systemImage: "exclamationmark.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var candidateSummary: String {
        guard let diagnostics = model.estimate.selectedDiagnostics else {
            return "Waiting for a geometrically visible Direct-to-Cell satellite."
        }
        return "\(Int((diagnostics.probability * 100).rounded()))% relative probability · \(diagnostics.motionState.rawValue) · inferred, not confirmed"
    }

    private var linkQualityCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Label("Internet link quality", systemImage: "network")
                            .font(.headline)
                        Text(linkQuality.statusText)
                            .font(.caption)
                            .foregroundStyle(linkQuality.isActivelyProbing ? .mint : .secondary)
                    }
                    Spacer()
                    if let summary = linkQuality.summary {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text("\(Int(summary.score.rounded()))")
                                .font(.title2.weight(.heavy).monospacedDigit())
                                .foregroundStyle(linkScoreColor(summary.score))
                            Text(summary.grade.rawValue.uppercased())
                                .font(.system(size: 8, weight: .black))
                                .foregroundStyle(linkScoreColor(summary.score))
                        }
                    }
                }

                HStack(spacing: 7) {
                    linkBadge(
                        linkQuality.summary?.diagnosticOverride == true ? "DIAGNOSTIC" : connectivity.mode == .ultraConstrained ? "SATELLITE PATH" : connectivity.mode.displayName.uppercased(),
                        color: connectivity.mode == .ultraConstrained ? .orange : .cyan
                    )
                    linkBadge("SYSTEM \(connectivity.systemLinkQuality.rawValue.uppercased())", color: .secondary)
                }

                if !linkQuality.samples.isEmpty {
                    LinkQualityHistoryChart(samples: linkQuality.samples)
                } else {
                    ContentUnavailableView(
                        "No link samples yet",
                        systemImage: "waveform.path.ecg",
                        description: Text("The first tiny probe runs when an ultra-constrained path is detected, or when diagnostic mode is enabled.")
                    )
                    .frame(minHeight: 120)
                }

                if let summary = linkQuality.summary {
                    Grid(horizontalSpacing: 14, verticalSpacing: 12) {
                        GridRow {
                            MetricView(label: "Median TTFB", value: milliseconds(summary.medianTimeToFirstByteMilliseconds), symbol: "hourglass")
                            MetricView(label: "Success", value: "\(Int((summary.successRate * 100).rounded()))%", symbol: "checkmark.circle")
                        }
                        GridRow {
                            MetricView(label: "Jitter", value: milliseconds(summary.jitterMilliseconds), symbol: "waveform.path")
                            MetricView(label: "Recorded traffic", value: byteCount(linkQuality.recordedTrafficBytes), symbol: "arrow.up.arrow.down")
                        }
                        GridRow {
                            MetricView(label: "Est. satellite signal", value: latestSatelliteSignalText, symbol: "satellite")
                            MetricView(label: "Signal correlation", value: satelliteCorrelationText, symbol: "point.3.connected.trianglepath.dotted")
                        }
                    }
                }

                if let latest = linkQuality.samples.last {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Label(
                                latest.reusedConnection ? "Connection reused" : "Fresh connection",
                                systemImage: latest.reusedConnection ? "arrow.trianglehead.2.clockwise.rotate.90" : "point.3.connected.trianglepath.dotted"
                            )
                            Spacer()
                            Text(latest.protocolName?.uppercased() ?? "PROTOCOL UNKNOWN")
                        }

                        if latest.reusedConnection {
                            if let setupSample = latestTransportSetupSample {
                                transportTimingRow(sample: setupSample, prefix: "Last setup")
                            } else {
                                Text("DNS, connect, and TLS were skipped because the existing transport was reused.")
                            }
                        } else {
                            transportTimingRow(sample: latest, prefix: "This setup")
                        }
                    }
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.tertiary)
                }

                if let error = linkQuality.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }

                Text("Internet quality is measured from the HTTPS probe. Satellite signal is a separate RF-geometry estimate from elevation, path loss, off-nadir steering, and scan loss—not modem signal strength or confirmation of the serving satellite.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var latestSatelliteSignalText: String {
        guard let score = linkQuality.samples.compactMap(\.estimatedSatelliteSignalScore).last else { return "—" }
        return "\(Int(score.rounded())) / 100"
    }

    private var satelliteCorrelationText: String {
        let pairs = linkQuality.samples.compactMap { sample -> (Double, Double)? in
            guard sample.pathMode == .ultraConstrained,
                  sample.succeeded,
                  let signal = sample.estimatedSatelliteSignalScore else { return nil }
            return (signal, sample.qualityScore)
        }
        guard pairs.count >= 3 else { return "Need 3 sat samples" }
        let signalMean = pairs.reduce(0) { $0 + $1.0 } / Double(pairs.count)
        let linkMean = pairs.reduce(0) { $0 + $1.1 } / Double(pairs.count)
        let numerator = pairs.reduce(0) { result, pair in
            result + (pair.0 - signalMean) * (pair.1 - linkMean)
        }
        let signalSpread = sqrt(pairs.reduce(0) { $0 + pow($1.0 - signalMean, 2) })
        let linkSpread = sqrt(pairs.reduce(0) { $0 + pow($1.1 - linkMean, 2) })
        guard signalSpread > 0, linkSpread > 0 else { return "No variation" }
        return String(format: "r = %+.2f", numerator / (signalSpread * linkSpread))
    }

    private var latestTransportSetupSample: LinkQualitySample? {
        linkQuality.samples.last(where: { !$0.reusedConnection })
    }

    private func transportTimingRow(sample: LinkQualitySample, prefix: String) -> some View {
        HStack(spacing: 9) {
            Text(prefix)
            Text("DNS \(transportMilliseconds(sample.dnsMilliseconds, fallback: "cached"))")
            Text("Connect \(transportMilliseconds(sample.connectMilliseconds, fallback: "not reported"))")
            Text("TLS \(transportMilliseconds(sample.tlsMilliseconds, fallback: "not reported"))")
        }
    }

    private func linkBadge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .black))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(color.opacity(0.1), in: Capsule())
    }

    private func linkScoreColor(_ score: Double) -> Color {
        switch score {
        case 85...: .mint
        case 70...: .green
        case 50...: .yellow
        case 25...: .orange
        default: .red
        }
    }

    private func milliseconds(_ value: Double?) -> String {
        guard let value else { return "—" }
        if value >= 1_000 { return String(format: "%.1fs", value / 1_000) }
        return "\(Int(value.rounded()))ms"
    }

    private func transportMilliseconds(_ value: Double?, fallback: String) -> String {
        value.map { milliseconds($0) } ?? fallback
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func geometryCard(_ observation: SatelliteObservation) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Live geometry").font(.headline)
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow {
                        MetricView(label: "Elevation", value: observation.elevationDegrees.formatted(.number.precision(.fractionLength(1))) + "°", symbol: "arrow.up.right")
                        MetricView(label: "Azimuth", value: observation.azimuthDegrees.formatted(.number.precision(.fractionLength(0))) + "°", symbol: "safari")
                    }
                    GridRow {
                        MetricView(label: "Range", value: observation.slantRangeKilometers.formatted(.number.precision(.fractionLength(0))) + " km", symbol: "ruler")
                        MetricView(label: "Loss of view", value: timeUntil(observation.pass?.set), symbol: "horizon")
                    }
                    GridRow {
                        MetricView(label: "Closest approach", value: timeUntil(observation.pass?.culmination), symbol: "arrow.down.to.line.compact")
                        MetricView(label: "Altitude", value: observation.state.geodetic.altitudeKilometers.formatted(.number.precision(.fractionLength(0))) + " km", symbol: "mountain.2")
                    }
                }
            }
        }
    }

    private func linkDiagnosticsCard(_ diagnostics: ServingCandidateDiagnostics) -> some View {
        let uplinkAssessment = model.observations
            .first { $0.id == diagnostics.id }
            .map {
                D2CUplinkBudget.assessment(
                    for: $0,
                    phoneHeadingDegrees: location.headingDegrees,
                    phonePointingElevationDegrees: location.phonePointingElevationDegrees
                )
            }
        return GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("D2C link diagnostics", systemImage: "wave.3.right.circle.fill")
                        .font(.headline)
                    Spacer()
                    Text(model.estimate.modelVersion)
                        .font(.system(size: 9, weight: .bold).monospaced())
                        .foregroundStyle(.secondary)
                }

                Grid(horizontalSpacing: 14, verticalSpacing: 14) {
                    GridRow {
                        MetricView(label: "Range rate", value: signed(diagnostics.rangeRateKilometersPerSecond, suffix: " km/s", digits: 2), symbol: "arrow.left.and.right")
                        MetricView(label: "Off nadir", value: degrees(diagnostics.offNadirDegrees, digits: 1), symbol: "angle")
                    }
                    GridRow {
                        MetricView(label: "Uplink Doppler", value: kilohertz(diagnostics.predictedUplinkDopplerHz), symbol: "arrow.up.circle")
                        MetricView(label: "Downlink Doppler", value: kilohertz(diagnostics.predictedDownlinkDopplerHz), symbol: "arrow.down.circle")
                    }
                    GridRow {
                        MetricView(label: "Doppler rate", value: signed(diagnostics.predictedDownlinkDopplerRateHzPerSecond, suffix: " Hz/s", digits: 1), symbol: "waveform.path")
                        MetricView(label: "Free-space loss", value: String(format: "%.1f dB", diagnostics.freeSpacePathLossDB), symbol: "antenna.radiowaves.left.and.right.slash")
                    }
                    GridRow {
                        MetricView(label: "Estimated scan loss", value: String(format: "%.1f dB", diagnostics.estimatedScanLossDB), symbol: "dot.radiowaves.up.forward")
                        MetricView(label: "Remaining dwell", value: duration(diagnostics.remainingDwellSeconds), symbol: "timer")
                    }
                    if let uplinkAssessment {
                        GridRow {
                            MetricView(label: "Adjusted uplink", value: signed(uplinkAssessment.adjustedMarginDB, suffix: " dB", digits: 1), symbol: "arrow.up.to.line.compact")
                            MetricView(label: "Phone attitude loss", value: String(format: "%.1f dB", uplinkAssessment.phoneOrientationLossDB), symbol: "iphone.gen3.radiowaves.left.and.right")
                        }
                    }
                    GridRow {
                        MetricView(label: "Motion", value: diagnostics.motionState.rawValue.capitalized, symbol: diagnostics.motionState == .rising ? "arrow.up.right" : diagnostics.motionState == .setting ? "arrow.down.right" : "equal")
                        MetricView(label: "TLE age", value: duration(diagnostics.tleAgeSeconds), symbol: "clock.badge.exclamationmark")
                    }
                }

                Divider().overlay(.white.opacity(0.1))

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: handoffSymbol)
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(handoffTitle)
                            .font(.caption.weight(.bold))
                        Text(model.estimate.handoff.reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                DisclosureGroup("Individual score components", isExpanded: $scoreComponentsExpanded) {
                    VStack(spacing: 8) {
                        ForEach(diagnostics.scoreComponents) { component in
                            VStack(spacing: 3) {
                                HStack {
                                    Text(component.name)
                                    Spacer()
                                    Text(String(format: "%.2f × %.2f = %.3f", component.normalizedValue, component.weight, component.contribution))
                                        .monospacedDigit()
                                        .foregroundStyle(.secondary)
                                }
                                ProgressView(value: component.normalizedValue)
                                    .tint(.cyan)
                            }
                            .font(.caption2)
                        }
                    }
                    .padding(.top, 8)
                }
                .font(.caption.weight(.semibold))

                Text("Raw Doppler is predicted orbital geometry at 1912.5 MHz uplink and 1992.5 MHz downlink. SpaceX network compensation means the handset should not observe the full shift.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func alternativesCard(_ selected: ServingCandidateDiagnostics) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top alternatives").font(.headline)
                if model.estimate.alternatives.isEmpty {
                    Text("No other D2C satellite is currently above the mask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.estimate.alternatives) { candidate in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(candidate.satellite.elements.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(degrees(candidate.elevationDegrees, digits: 0)) elevation · \(Int(candidate.slantRangeKilometers.rounded())) km · \(candidate.motionState.rawValue)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(Int((candidate.probability * 100).rounded()))%")
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.cyan)
                        }
                        if candidate.id != model.estimate.alternatives.last?.id {
                            Divider().overlay(.white.opacity(0.08))
                        }
                    }
                }
            }
        }
    }

    private var handoffSymbol: String {
        switch model.estimate.handoff.phase {
        case .stable: "checkmark.circle.fill"
        case .evaluatingChallenger: "hourglass.circle.fill"
        case .deferred: "pause.circle.fill"
        case .handedOff, .incumbentLost: "arrow.trianglehead.swap"
        case .insufficientEvidence: "questionmark.circle.fill"
        }
    }

    private var handoffTitle: String {
        switch model.estimate.handoff.phase {
        case .stable: "Stable candidate"
        case .evaluatingChallenger: "Evaluating challenger"
        case .deferred: "Handoff deferred"
        case .handedOff: "Stable handoff completed"
        case .incumbentLost: "Incumbent geometry lost"
        case .insufficientEvidence: "Insufficient evidence"
        }
    }

    private var explanationCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Why this candidate").font(.headline)
                ForEach(Array(model.estimate.reasons.enumerated()), id: \.offset) { _, reason in
                    Label(reason, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var backgroundTrackingCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 11) {
                HStack {
                    Label("Dynamic Island tracking", systemImage: "platter.filled.top.iphone")
                        .font(.headline)
                    Spacer()
                    Text(model.liveActivity.isActive ? "LIVE" : "OFF")
                        .font(.caption2.weight(.black))
                        .foregroundStyle(model.liveActivity.isActive ? .mint : .secondary)
                }

                Text("The arrow points from the phone's current heading toward the satellite. Satellite bearing remains referenced to true north. Continuous location keeps updates running in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button {
                    Task {
                        if model.liveActivity.isActive || location.backgroundTrackingEnabled {
                            await model.stopBackgroundSatelliteTracking()
                        } else {
                            await model.startBackgroundSatelliteTracking()
                        }
                    }
                } label: {
                    Label(
                        model.liveActivity.isActive ? "Stop Background Tracking" : "Start Background Tracking",
                        systemImage: model.liveActivity.isActive ? "stop.circle" : "location.north.circle.fill"
                    )
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(model.liveActivity.isActive ? .gray : .cyan)
                .disabled(!model.liveActivity.isActive && model.estimate.satellite == nil)

                if let error = model.liveActivity.errorMessage ?? location.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.orange)
                } else if location.backgroundTrackingEnabled {
                    Label("Continuous location active · higher battery use", systemImage: "location.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private var dataCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Orbital data").font(.headline)
                    Spacer()
                    Text(model.freshness?.rawValue.capitalized ?? "Unavailable")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(model.freshness == .fresh ? .green : .orange)
                }
                LabeledContent("Catalog records", value: "\(model.catalog?.records.count ?? 0)")
                LabeledContent("Classified Direct-to-Cell", value: "\(model.catalog?.records.filter(\.directToCell).count ?? 0)")
                LabeledContent("Data age", value: dataAge)
                if model.usesBundledSample {
                    Label("Development sample: classifications and orbital elements are synthetic fixtures.", systemImage: "testtube.2")
                        .font(.caption).foregroundStyle(.orange)
                }
                if let message = model.refreshMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.subheadline)
        }
    }

    private var disclaimer: some View {
        Text("All visibility and serving-candidate calculations happen on this iPhone. Your location is never sent to the orbital-data provider.")
            .font(.footnote)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 8)
    }

    private var dataAge: String {
        guard let date = model.catalog?.fetchedAt else { return "Unknown" }
        return date.formatted(.relative(presentation: .numeric))
    }

    private func timeUntil(_ date: Date?) -> String {
        guard let date else { return "—" }
        let seconds = max(0, Int(date.timeIntervalSinceNow))
        if seconds < 60 { return "\(seconds)s" }
        return "\(seconds / 60)m \(seconds % 60)s"
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "\(value)s" }
        if value < 3_600 { return "\(value / 60)m \(value % 60)s" }
        if value < 86_400 { return String(format: "%.1fh", Double(value) / 3_600) }
        return String(format: "%.1fd", Double(value) / 86_400)
    }

    private func degrees(_ value: Double, digits: Int) -> String {
        String(format: "%.*f°", digits, value)
    }

    private func kilohertz(_ value: Double) -> String {
        String(format: "%+.1f kHz", value / 1_000)
    }

    private func signed(_ value: Double, suffix: String, digits: Int) -> String {
        String(format: "%+.*f%@", digits, value, suffix)
    }
}

private struct LinkQualityHistoryChart: View {
    let samples: [LinkQualitySample]

    @State private var selectedDate: Date?
    @State private var visibleDuration: TimeInterval
    @State private var pinchBaselineDuration: TimeInterval?
    @State private var scrollPosition: Date
    @State private var followsLatest = true

    init(samples: [LinkQualitySample]) {
        self.samples = samples
        let initialDuration: TimeInterval = 30 * 60
        _visibleDuration = State(initialValue: initialDuration)
        _scrollPosition = State(
            initialValue: samples.last?.measuredAt.addingTimeInterval(-initialDuration) ?? .now
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                networkLegend("Wi-Fi", color: wifiColor)
                networkLegend("Cellular", color: cellularColor)
                networkLegend("Satellite", color: satelliteColor)
                networkLegend("Offline", color: .red)
                Spacer(minLength: 0)
                Button {
                    followsLatest = true
                    scrollPosition = latestScrollPosition
                } label: {
                    Label("Latest", systemImage: "forward.end.fill")
                        .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .foregroundStyle(followsLatest ? .cyan : .secondary)
                .accessibilityLabel("Jump to latest link sample")
            }

            HStack(spacing: 6) {
                Capsule()
                    .fill(signalColor)
                    .frame(width: 20, height: 2)
                Text("Estimated satellite signal")
                Spacer()
                Text("\(durationLabel(visibleDuration)) window · swipe, tap, pinch")
            }
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(.secondary)

            Chart {
                ForEach(networkRuns) { run in
                    ForEach(run.samples) { sample in
                        LineMark(
                            x: .value("Time", sample.measuredAt),
                            y: .value("Internet quality", sample.qualityScore),
                            series: .value("Network run", "network-\(run.id.uuidString)")
                        )
                        .interpolationMethod(.linear)
                        .foregroundStyle(networkColor(run.pathMode))
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

                        PointMark(
                            x: .value("Time", sample.measuredAt),
                            y: .value("Internet quality", sample.qualityScore)
                        )
                        .symbolSize(sample.succeeded ? 10 : 38)
                        .foregroundStyle(sample.succeeded ? networkColor(run.pathMode) : .red)
                    }
                }

                ForEach(signalRuns) { run in
                    ForEach(run.samples) { sample in
                        if let signal = sample.estimatedSatelliteSignalScore {
                            LineMark(
                                x: .value("Time", sample.measuredAt),
                                y: .value("Estimated satellite signal", signal),
                                series: .value("Signal run", "signal-\(run.id.uuidString)")
                            )
                            .interpolationMethod(.linear)
                            .foregroundStyle(signalColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        }
                    }
                }

                RuleMark(y: .value("Good", 70))
                    .foregroundStyle(.white.opacity(0.12))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 4]))

                if let selectedDate {
                    RuleMark(x: .value("Selected", selectedDate))
                        .foregroundStyle(.white.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 0.75))
                }
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 25, 50, 75, 100]) {
                    AxisGridLine().foregroundStyle(.white.opacity(0.05))
                    AxisTick()
                    AxisValueLabel()
                }
                AxisMarks(position: .trailing, values: [0, 25, 50, 75, 100]) { value in
                    AxisTick().foregroundStyle(signalColor.opacity(0.6))
                    AxisValueLabel {
                        if let score = value.as(Double.self) {
                            Text("\(Int(score))")
                                .foregroundStyle(signalColor)
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) {
                    AxisGridLine().foregroundStyle(.white.opacity(0.05))
                    AxisValueLabel(format: .dateTime.hour().minute())
                }
            }
            .chartScrollableAxes(.horizontal)
            .chartXVisibleDomain(length: visibleDuration)
            .chartScrollPosition(x: $scrollPosition)
            .chartXSelection(value: $selectedDate)
            .frame(height: 190)
            .simultaneousGesture(
                MagnificationGesture()
                    .onChanged { magnification in
                        if pinchBaselineDuration == nil {
                            pinchBaselineDuration = visibleDuration
                        }
                        guard let pinchBaselineDuration else { return }
                        followsLatest = false
                        visibleDuration = min(
                            maximumVisibleDuration,
                            max(minimumVisibleDuration, pinchBaselineDuration / Double(magnification))
                        )
                    }
                    .onEnded { _ in
                        pinchBaselineDuration = nil
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { _ in followsLatest = false }
            )
            .onChange(of: samples.last?.id) { _, _ in
                guard followsLatest else { return }
                scrollPosition = latestScrollPosition
            }

            if let selectedSample {
                selectedSampleDetails(selectedSample)
            }
        }
    }

    private var networkRuns: [NetworkRun] {
        var runs: [NetworkRun] = []
        for sample in samples {
            if let lastIndex = runs.indices.last, runs[lastIndex].pathMode == sample.pathMode {
                runs[lastIndex].samples.append(sample)
            } else {
                runs.append(NetworkRun(id: sample.id, pathMode: sample.pathMode, samples: [sample]))
            }
        }
        return runs
    }

    private var signalRuns: [SignalRun] {
        var runs: [SignalRun] = []
        var current: [LinkQualitySample] = []
        for sample in samples {
            if sample.estimatedSatelliteSignalScore != nil {
                current.append(sample)
            } else if let first = current.first {
                runs.append(SignalRun(id: first.id, samples: current))
                current = []
            }
        }
        if let first = current.first {
            runs.append(SignalRun(id: first.id, samples: current))
        }
        return runs
    }

    private var selectedSample: LinkQualitySample? {
        guard let selectedDate else { return nil }
        return samples.min {
            abs($0.measuredAt.timeIntervalSince(selectedDate))
                < abs($1.measuredAt.timeIntervalSince(selectedDate))
        }
    }

    private var minimumVisibleDuration: TimeInterval { 2 * 60 }

    private var maximumVisibleDuration: TimeInterval {
        guard let first = samples.first, let last = samples.last else { return 30 * 60 }
        return max(30 * 60, last.measuredAt.timeIntervalSince(first.measuredAt) + 2 * 60)
    }

    private var latestScrollPosition: Date {
        samples.last?.measuredAt.addingTimeInterval(-visibleDuration) ?? .now
    }

    private func selectedSampleDetails(_ sample: LinkQualitySample) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(networkColor(sample.pathMode))
                    .frame(width: 7, height: 7)
                Text(networkName(sample.pathMode))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(networkColor(sample.pathMode))
                Text(sample.succeeded ? "AVAILABLE" : "MISSED")
                    .font(.system(size: 7, weight: .black))
                    .foregroundStyle(sample.succeeded ? .mint : .red)
                Spacer()
                Text(sample.measuredAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                chartReadout("INTERNET", "\(Int(sample.qualityScore.rounded()))", networkColor(sample.pathMode))
                chartReadout(
                    "SAT SIGNAL",
                    sample.estimatedSatelliteSignalScore.map { "\(Int($0.rounded()))" } ?? "—",
                    signalColor
                )
                chartReadout(
                    "TTFB",
                    sample.timeToFirstByteMilliseconds.map(milliseconds) ?? "—",
                    .white
                )
            }

            if let satelliteName = sample.satelliteName {
                Text(satelliteDetails(sample, name: satelliteName))
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if !sample.succeeded, let error = sample.errorDescription {
                Label(error, systemImage: sample.pathMode == .offline ? "wifi.slash" : "clock.badge.exclamationmark")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.red)
            }
        }
        .padding(9)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.5)
        }
    }

    private func chartReadout(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func satelliteDetails(_ sample: LinkQualitySample, name: String) -> String {
        var values = [name]
        if let elevation = sample.satelliteElevationDegrees {
            values.append("elev \(Int(elevation.rounded()))°")
        }
        if let range = sample.satelliteSlantRangeKilometers {
            values.append("\(Int(range.rounded())) km")
        }
        if let loss = sample.satelliteFreeSpacePathLossDB {
            values.append(String(format: "FSPL %.1f dB", loss))
        }
        if let scan = sample.satelliteScanLossDB {
            values.append(String(format: "scan %.1f dB", scan))
        }
        if let margin = sample.satelliteUplinkMarginDB {
            values.append(String(format: "uplink %+.1f dB", margin))
        }
        if let orientationLoss = sample.phoneOrientationLossDB {
            values.append(String(format: "attitude %.1f dB", orientationLoss))
        }
        if let probability = sample.satelliteServingProbability {
            values.append("serving \(Int((probability * 100).rounded()))%")
        }
        return values.joined(separator: " · ")
    }

    private func networkLegend(_ name: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(name)
        }
        .font(.system(size: 8, weight: .bold))
        .foregroundStyle(.secondary)
    }

    private func networkColor(_ mode: ConnectivityMode) -> Color {
        switch mode {
        case .wifi, .wiredEthernet: wifiColor
        case .terrestrialCellular, .constrained: cellularColor
        case .ultraConstrained: satelliteColor
        case .offline: .red
        case .unknown: .gray
        }
    }

    private func networkName(_ mode: ConnectivityMode) -> String {
        switch mode {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Wired"
        case .terrestrialCellular: "Cellular"
        case .constrained: "Constrained cellular"
        case .ultraConstrained: "Satellite"
        case .offline: "Offline"
        case .unknown: "Unknown"
        }
    }

    private func durationLabel(_ duration: TimeInterval) -> String {
        if duration < 60 * 60 { return "\(Int((duration / 60).rounded()))m" }
        return String(format: "%.1fh", duration / 3_600)
    }

    private func milliseconds(_ value: Double) -> String {
        if value >= 1_000 { return String(format: "%.1fs", value / 1_000) }
        return "\(Int(value.rounded()))ms"
    }

    private var wifiColor: Color { Color(red: 0.16, green: 0.58, blue: 1.0) }
    private var cellularColor: Color { Color(red: 0.89, green: 0.0, blue: 0.46) }
    private var satelliteColor: Color { Color(red: 0.22, green: 0.82, blue: 0.46) }
    private var signalColor: Color { .orange }

    private struct NetworkRun: Identifiable {
        let id: UUID
        let pathMode: ConnectivityMode
        var samples: [LinkQualitySample]
    }

    private struct SignalRun: Identifiable {
        let id: UUID
        let samples: [LinkQualitySample]
    }
}

struct MetricView: View {
    let label: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(label, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit()).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct ConfidenceBadge: View {
    let confidence: EstimateConfidence
    var body: some View {
        Text(confidence.rawValue.capitalized)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
            .accessibilityLabel("Confidence \(confidence.rawValue)")
    }

    private var color: Color {
        switch confidence {
        case .high: .green
        case .medium: .cyan
        case .low: .orange
        case .insufficientEvidence: .secondary
        }
    }
}
