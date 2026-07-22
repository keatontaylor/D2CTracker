import Foundation
import UIKit
import D2CTrackerCore

@MainActor
final class LinkQualityService: ObservableObject {
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Keys.enabled)
            if !isEnabled {
                satelliteTestingWindowActive = false
            } else if pathMode == .ultraConstrained {
                satelliteTestingWindowActive = true
            }
            reconcile()
        }
    }
    @Published var diagnosticOverride: Bool {
        didSet {
            UserDefaults.standard.set(diagnosticOverride, forKey: Keys.diagnosticOverride)
            reconcile()
        }
    }
    @Published var foregroundIntervalSeconds: TimeInterval {
        didSet {
            foregroundIntervalSeconds = Self.sanitizedInterval(
                foregroundIntervalSeconds,
                fallback: Constants.defaultForegroundInterval
            )
            UserDefaults.standard.set(foregroundIntervalSeconds, forKey: Keys.foregroundInterval)
            restartLoopForScheduleChange()
        }
    }
    @Published var backgroundIntervalSeconds: TimeInterval {
        didSet {
            backgroundIntervalSeconds = Self.sanitizedInterval(
                backgroundIntervalSeconds,
                fallback: Constants.defaultBackgroundInterval
            )
            UserDefaults.standard.set(backgroundIntervalSeconds, forKey: Keys.backgroundInterval)
            restartLoopForScheduleChange()
        }
    }
    @Published private(set) var isActivelyProbing = false
    @Published private(set) var isProbeInFlight = false
    @Published private(set) var samples: [LinkQualitySample]
    @Published private(set) var summary: LinkQualitySummary?
    @Published private(set) var lastError: String?

    var onSummaryUpdate: ((LinkQualitySummary?) -> Void)?

    private var pathMode: ConnectivityMode = .unknown
    private var systemQuality: SystemLinkQuality = .unknown
    private var isForeground = true
    private var backgroundTrackingActive = false
    private var hasStarted = false
    private var satelliteTestingWindowActive = false
    private var satelliteEstimate: ServingCandidateDiagnostics?
    private var satelliteUplinkAssessment: D2CUplinkAssessment?
    private var loopTask: Task<Void, Never>?
    private lazy var session = URLSession(configuration: Self.sessionConfiguration())

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.bool(forKey: Keys.enabled)
        diagnosticOverride = defaults.bool(forKey: Keys.diagnosticOverride)
        foregroundIntervalSeconds = Self.sanitizedInterval(
            defaults.object(forKey: Keys.foregroundInterval) as? TimeInterval,
            fallback: Constants.defaultForegroundInterval
        )
        backgroundIntervalSeconds = Self.sanitizedInterval(
            defaults.object(forKey: Keys.backgroundInterval) as? TimeInterval,
            fallback: Constants.defaultBackgroundInterval
        )
        if let data = defaults.data(forKey: Keys.history),
           let decoded = try? JSONDecoder().decode([LinkQualitySample].self, from: data) {
            samples = Array(decoded.suffix(Constants.maximumSamples))
        } else {
            samples = []
        }
        summary = LinkQualityScorer.summarize(samples)
    }

    deinit { loopTask?.cancel() }

    var shouldProbeOnCurrentPath: Bool {
        if diagnosticOverride || pathMode == .ultraConstrained { return true }
        return satelliteTestingWindowActive && (pathMode == .offline || pathMode == .unknown)
    }

    var statusText: String {
        guard isEnabled else { return "Tracking off" }
        guard shouldProbeOnCurrentPath else { return "Waiting for an ultra-constrained path" }
        guard isForeground || backgroundTrackingActive else { return "Paused in background" }
        if pathMode == .offline { return "Offline · recording missed probes" }
        return isProbeInFlight ? "Testing Internet path…" : "Active"
    }

    var recordedTrafficBytes: Int64 {
        samples.reduce(0) { $0 + $1.requestBytes + $1.responseBytes }
    }

    func start(
        pathMode: ConnectivityMode,
        systemQuality: SystemLinkQuality,
        backgroundTrackingActive: Bool
    ) {
        self.pathMode = pathMode
        self.systemQuality = systemQuality
        self.backgroundTrackingActive = backgroundTrackingActive
        satelliteTestingWindowActive = pathMode == .ultraConstrained
        hasStarted = true
        reconcile()
    }

    func updatePath(mode: ConnectivityMode, systemQuality: SystemLinkQuality) {
        let priorMode = pathMode
        pathMode = mode
        self.systemQuality = systemQuality
        switch mode {
        case .ultraConstrained:
            satelliteTestingWindowActive = true
        case .wifi, .wiredEthernet, .terrestrialCellular, .constrained:
            satelliteTestingWindowActive = false
        case .offline, .unknown:
            break
        }
        if mode == .offline,
           priorMode != .offline,
           isEnabled,
           shouldProbeOnCurrentPath,
           isForeground || backgroundTrackingActive {
            recordOfflineSnapshot(at: .now)
        }
        reconcile()
    }

    func setForeground(_ foreground: Bool) {
        isForeground = foreground
        reconcile()
    }

    func setBackgroundTrackingActive(_ active: Bool) {
        backgroundTrackingActive = active
        reconcile()
    }

    func updateSatelliteEstimate(
        _ estimate: ServingCandidateDiagnostics?,
        observation: SatelliteObservation?,
        phoneHeadingDegrees: Double?,
        phonePointingElevationDegrees: Double?
    ) {
        satelliteEstimate = estimate
        satelliteUplinkAssessment = observation.map {
            D2CUplinkBudget.assessment(
                for: $0,
                phoneHeadingDegrees: phoneHeadingDegrees,
                phonePointingElevationDegrees: phonePointingElevationDegrees
            )
        }
    }

    func runProbeNow() async {
        guard isEnabled, shouldProbeOnCurrentPath else { return }
        await performProbe(forceFreshConnection: true)
    }

    func clearHistory() {
        samples = []
        summary = nil
        lastError = nil
        UserDefaults.standard.removeObject(forKey: Keys.history)
        onSummaryUpdate?(nil)
    }

    func makePrivacyScrubbedDiagnosticExport() throws -> URL {
        let captureStart = samples.first?.measuredAt
        let sanitizedSamples = samples.map { sample in
            PrivacyScrubbedDiagnosticReport.Sample(
                secondsSinceCaptureStart: captureStart.map {
                    max(0, Int(sample.measuredAt.timeIntervalSince($0).rounded()))
                } ?? 0,
                pathMode: sample.pathMode.rawValue,
                systemLinkQuality: sample.systemLinkQuality.rawValue,
                diagnosticOverride: sample.diagnosticOverride,
                succeeded: sample.succeeded,
                statusCode: sample.statusCode,
                timeToFirstByteMilliseconds: sample.timeToFirstByteMilliseconds,
                totalDurationMilliseconds: sample.totalDurationMilliseconds,
                dnsMilliseconds: sample.dnsMilliseconds,
                connectMilliseconds: sample.connectMilliseconds,
                tlsMilliseconds: sample.tlsMilliseconds,
                protocolName: sample.protocolName,
                reusedConnection: sample.reusedConnection,
                requestBytes: sample.requestBytes,
                responseBytes: sample.responseBytes,
                qualityScore: sample.qualityScore,
                errorCategory: Self.errorCategory(for: sample),
                hasSatelliteEstimate: sample.satelliteID != nil,
                estimatedSatelliteSignalScore: sample.estimatedSatelliteSignalScore,
                satelliteServingProbability: sample.satelliteServingProbability,
                satelliteElevationDegrees: sample.satelliteElevationDegrees,
                satelliteSlantRangeKilometers: sample.satelliteSlantRangeKilometers,
                satelliteFreeSpacePathLossDB: sample.satelliteFreeSpacePathLossDB,
                satelliteScanLossDB: sample.satelliteScanLossDB,
                satelliteUplinkMarginDB: sample.satelliteUplinkMarginDB
            )
        }
        let report = PrivacyScrubbedDiagnosticReport(
            schemaVersion: 1,
            generatedAt: .now,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            appBuild: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            operatingSystem: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            deviceClass: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone",
            currentPathMode: pathMode.rawValue,
            currentSystemLinkQuality: systemQuality.rawValue,
            foregroundIntervalSeconds: foregroundIntervalSeconds,
            backgroundIntervalSeconds: backgroundIntervalSeconds,
            diagnosticOverrideEnabled: diagnosticOverride,
            recordedTrafficBytes: recordedTrafficBytes,
            captureDurationSeconds: captureStart.flatMap { start in
                samples.last.map { max(0, Int($0.measuredAt.timeIntervalSince(start).rounded())) }
            } ?? 0,
            omittedForPrivacy: [
                "location coordinates and altitude",
                "IP addresses and device or user identifiers",
                "satellite catalog IDs and names",
                "headings, phone orientation, and absolute sample timestamps",
                "raw transport error descriptions"
            ],
            samples: sanitizedSamples
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("D2CTracker-TestFlight-Diagnostics.json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private var shouldRun: Bool {
        hasStarted
            && isEnabled
            && shouldProbeOnCurrentPath
            && (isForeground || backgroundTrackingActive)
    }

    private func reconcile() {
        guard hasStarted else { return }
        if shouldRun {
            guard loopTask == nil else { return }
            startLoop()
        } else {
            loopTask?.cancel()
            loopTask = nil
            isActivelyProbing = false
            if !isEnabled { onSummaryUpdate?(nil) }
        }
    }

    private func restartLoopForScheduleChange() {
        guard hasStarted else { return }
        loopTask?.cancel()
        loopTask = nil
        isActivelyProbing = false
        reconcile()
    }

    private func startLoop() {
        isActivelyProbing = true
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.shouldRun {
                let cycleStartedAt = Date()
                let forceFreshConnection = self.samples.isEmpty
                    || self.samples.count.isMultiple(of: Constants.freshTransportSampleInterval)
                await self.performProbe(forceFreshConnection: forceFreshConnection)
                let delay = max(0, self.samplingInterval - Date().timeIntervalSince(cycleStartedAt))
                try? await Task.sleep(for: .seconds(delay))
            }
            guard !Task.isCancelled else { return }
            self.loopTask = nil
            self.isActivelyProbing = false
        }
    }

    private var samplingInterval: TimeInterval {
        isForeground ? foregroundIntervalSeconds : backgroundIntervalSeconds
    }

    private func performProbe(forceFreshConnection: Bool = false) async {
        guard !isProbeInFlight else { return }
        isProbeInFlight = true
        defer { isProbeInFlight = false }

        let measuredAt = Date()
        let probePathMode = pathMode
        let probeSystemQuality = systemQuality
        let probeDiagnosticOverride = diagnosticOverride && probePathMode != .ultraConstrained
        let probeSatelliteEstimate = satelliteEstimate
        let probeUplinkAssessment = satelliteUplinkAssessment

        if probePathMode == .offline {
            recordOfflineSnapshot(
                at: measuredAt,
                systemQuality: probeSystemQuality,
                diagnosticOverride: probeDiagnosticOverride,
                satelliteEstimate: probeSatelliteEstimate
            )
            return
        }

        if forceFreshConnection {
            session.invalidateAndCancel()
            session = URLSession(configuration: Self.sessionConfiguration())
        }

        let collector = ProbeMetricsCollector()
        var request = URLRequest(
            url: Constants.probeURL,
            cachePolicy: .reloadIgnoringLocalAndRemoteCacheData,
            timeoutInterval: Constants.timeout
        )
        request.httpMethod = "GET"
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("D2CTracker-LinkProbe/1", forHTTPHeaderField: "User-Agent")
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
        if #available(iOS 26.1, *) {
            request.allowsUltraConstrainedNetworkAccess = true
        }

        let clockStart = ContinuousClock.now
        let data: Data?
        let response: URLResponse?
        let caughtError: Error?
        do {
            let result = try await session.data(for: request, delegate: collector)
            data = result.0
            response = result.1
            caughtError = nil
        } catch {
            data = nil
            response = nil
            caughtError = error
        }
        let wallDuration = clockStart.duration(to: .now).components
        let wallMilliseconds = Double(wallDuration.seconds) * 1_000
            + Double(wallDuration.attoseconds) / 1e15
        let metrics = await collector.waitForMetrics()
        let transaction = metrics?.transactionMetrics.last
        let statusCode = (response as? HTTPURLResponse)?.statusCode
        let succeeded = caughtError == nil
            && statusCode.map { (200..<300).contains($0) } == true
            && data != nil
        let totalMilliseconds = metrics.map { $0.taskInterval.duration * 1_000 } ?? wallMilliseconds
        let ttfb = intervalMilliseconds(transaction?.requestStartDate, transaction?.responseStartDate)
        let requestBytes = metrics?.transactionMetrics.reduce(Int64(0)) {
            $0 + $1.countOfRequestHeaderBytesSent + $1.countOfRequestBodyBytesSent
        } ?? 0
        let responseBytes = metrics?.transactionMetrics.reduce(Int64(0)) {
            $0 + $1.countOfResponseHeaderBytesReceived + $1.countOfResponseBodyBytesReceived
        } ?? Int64(data?.count ?? 0)
        let score = LinkQualityScorer.sampleScore(
            succeeded: succeeded,
            timeToFirstByteMilliseconds: ttfb,
            totalDurationMilliseconds: totalMilliseconds,
            systemQuality: probeSystemQuality
        )
        let sample = LinkQualitySample(
            measuredAt: measuredAt,
            pathMode: probePathMode,
            systemLinkQuality: probeSystemQuality,
            diagnosticOverride: probeDiagnosticOverride,
            succeeded: succeeded,
            statusCode: statusCode,
            timeToFirstByteMilliseconds: ttfb,
            totalDurationMilliseconds: totalMilliseconds,
            dnsMilliseconds: intervalMilliseconds(transaction?.domainLookupStartDate, transaction?.domainLookupEndDate),
            connectMilliseconds: intervalMilliseconds(transaction?.connectStartDate, transaction?.connectEndDate),
            tlsMilliseconds: intervalMilliseconds(transaction?.secureConnectionStartDate, transaction?.secureConnectionEndDate),
            protocolName: transaction?.networkProtocolName,
            reusedConnection: transaction?.isReusedConnection ?? false,
            requestBytes: requestBytes,
            responseBytes: responseBytes,
            qualityScore: score,
            errorDescription: caughtError?.localizedDescription,
            satelliteID: probeSatelliteEstimate?.id,
            satelliteName: probeSatelliteEstimate?.satellite.elements.name,
            estimatedSatelliteSignalScore: probeSatelliteEstimate.flatMap {
                SatelliteSignalQualityEstimator.score(
                    from: $0,
                    adjustedUplinkMarginDB: probeUplinkAssessment?.adjustedMarginDB
                )
            },
            satelliteServingProbability: probeSatelliteEstimate?.probability,
            satelliteElevationDegrees: probeSatelliteEstimate?.elevationDegrees,
            satelliteSlantRangeKilometers: probeSatelliteEstimate?.slantRangeKilometers,
            satelliteFreeSpacePathLossDB: probeSatelliteEstimate?.freeSpacePathLossDB,
            satelliteScanLossDB: probeSatelliteEstimate?.estimatedScanLossDB,
            satelliteUplinkMarginDB: probeUplinkAssessment?.adjustedMarginDB,
            phoneOrientationLossDB: probeUplinkAssessment?.phoneOrientationLossDB
        )
        record(sample, error: succeeded ? nil : caughtError?.localizedDescription ?? "HTTP \(statusCode ?? 0)")
    }

    private func recordOfflineSnapshot(
        at measuredAt: Date,
        systemQuality: SystemLinkQuality? = nil,
        diagnosticOverride: Bool? = nil,
        satelliteEstimate: ServingCandidateDiagnostics? = nil
    ) {
        if let latest = samples.last,
           latest.pathMode == .offline,
           measuredAt.timeIntervalSince(latest.measuredAt) < 2 {
            return
        }
        let estimate = satelliteEstimate ?? self.satelliteEstimate
        let sample = LinkQualitySample(
            measuredAt: measuredAt,
            pathMode: .offline,
            systemLinkQuality: systemQuality ?? self.systemQuality,
            diagnosticOverride: diagnosticOverride ?? self.diagnosticOverride,
            succeeded: false,
            statusCode: nil,
            timeToFirstByteMilliseconds: nil,
            totalDurationMilliseconds: 0,
            dnsMilliseconds: nil,
            connectMilliseconds: nil,
            tlsMilliseconds: nil,
            protocolName: nil,
            reusedConnection: false,
            requestBytes: 0,
            responseBytes: 0,
            qualityScore: 0,
            errorDescription: "Offline — no Internet path available",
            satelliteID: estimate?.id,
            satelliteName: estimate?.satellite.elements.name,
            estimatedSatelliteSignalScore: estimate.flatMap {
                SatelliteSignalQualityEstimator.score(
                    from: $0,
                    adjustedUplinkMarginDB: satelliteUplinkAssessment?.adjustedMarginDB
                )
            },
            satelliteServingProbability: estimate?.probability,
            satelliteElevationDegrees: estimate?.elevationDegrees,
            satelliteSlantRangeKilometers: estimate?.slantRangeKilometers,
            satelliteFreeSpacePathLossDB: estimate?.freeSpacePathLossDB,
            satelliteScanLossDB: estimate?.estimatedScanLossDB,
            satelliteUplinkMarginDB: satelliteUplinkAssessment?.adjustedMarginDB,
            phoneOrientationLossDB: satelliteUplinkAssessment?.phoneOrientationLossDB
        )
        record(sample, error: sample.errorDescription)
    }

    private func record(_ sample: LinkQualitySample, error: String?) {
        samples.append(sample)
        if samples.count > Constants.maximumSamples {
            samples.removeFirst(samples.count - Constants.maximumSamples)
        }
        summary = LinkQualityScorer.summarize(samples)
        lastError = error
        persistHistory()
        onSummaryUpdate?(summary)
    }

    private func persistHistory() {
        guard let data = try? JSONEncoder().encode(samples) else { return }
        UserDefaults.standard.set(data, forKey: Keys.history)
    }

    private func intervalMilliseconds(_ start: Date?, _ end: Date?) -> Double? {
        guard let start, let end else { return nil }
        return max(0, end.timeIntervalSince(start) * 1_000)
    }

    private static func sessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = Constants.timeout
        configuration.timeoutIntervalForResource = Constants.timeout
        configuration.waitsForConnectivity = false
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true
        if #available(iOS 26.1, *) {
            configuration.allowsUltraConstrainedNetworkAccess = true
        }
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    private static func sanitizedInterval(_ value: TimeInterval?, fallback: TimeInterval) -> TimeInterval {
        guard let value, value.isFinite else { return fallback }
        return min(3_600, max(15, value))
    }

    private static func errorCategory(for sample: LinkQualitySample) -> String? {
        guard !sample.succeeded else { return nil }
        if sample.pathMode == .offline { return "offline" }
        if sample.statusCode != nil { return "http" }
        if sample.errorDescription?.localizedCaseInsensitiveContains("timed out") == true {
            return "timeout"
        }
        return "transport"
    }

    private enum Keys {
        static let enabled = "linkQualityTrackingEnabled"
        static let diagnosticOverride = "linkQualityDiagnosticOverride"
        static let history = "linkQualityHistoryV1"
        static let foregroundInterval = "linkQualityForegroundIntervalSeconds"
        static let backgroundInterval = "linkQualityBackgroundIntervalSeconds"
    }

    private enum Constants {
        static let probeURL = URL(string: "https://speed.cloudflare.com/__down?bytes=0")!
        static let timeout: TimeInterval = 5
        static let defaultForegroundInterval: TimeInterval = 60
        static let defaultBackgroundInterval: TimeInterval = 5 * 60
        static let maximumSamples = 720
        static let freshTransportSampleInterval = 10
    }
}

private struct PrivacyScrubbedDiagnosticReport: Encodable {
    let schemaVersion: Int
    let generatedAt: Date
    let appVersion: String
    let appBuild: String
    let operatingSystem: String
    let deviceClass: String
    let currentPathMode: String
    let currentSystemLinkQuality: String
    let foregroundIntervalSeconds: TimeInterval
    let backgroundIntervalSeconds: TimeInterval
    let diagnosticOverrideEnabled: Bool
    let recordedTrafficBytes: Int64
    let captureDurationSeconds: Int
    let omittedForPrivacy: [String]
    let samples: [Sample]

    struct Sample: Encodable {
        let secondsSinceCaptureStart: Int
        let pathMode: String
        let systemLinkQuality: String
        let diagnosticOverride: Bool
        let succeeded: Bool
        let statusCode: Int?
        let timeToFirstByteMilliseconds: Double?
        let totalDurationMilliseconds: Double
        let dnsMilliseconds: Double?
        let connectMilliseconds: Double?
        let tlsMilliseconds: Double?
        let protocolName: String?
        let reusedConnection: Bool
        let requestBytes: Int64
        let responseBytes: Int64
        let qualityScore: Double
        let errorCategory: String?
        let hasSatelliteEstimate: Bool
        let estimatedSatelliteSignalScore: Double?
        let satelliteServingProbability: Double?
        let satelliteElevationDegrees: Double?
        let satelliteSlantRangeKilometers: Double?
        let satelliteFreeSpacePathLossDB: Double?
        let satelliteScanLossDB: Double?
        let satelliteUplinkMarginDB: Double?
    }
}

private final class ProbeMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var metrics: URLSessionTaskMetrics?

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        lock.lock()
        self.metrics = metrics
        lock.unlock()
    }

    func snapshot() -> URLSessionTaskMetrics? {
        lock.lock()
        defer { lock.unlock() }
        return metrics
    }

    func waitForMetrics() async -> URLSessionTaskMetrics? {
        for _ in 0..<20 {
            if let value = snapshot() { return value }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return snapshot()
    }
}
