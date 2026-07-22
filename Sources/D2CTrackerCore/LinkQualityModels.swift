import Foundation

public enum SystemLinkQuality: String, Codable, CaseIterable, Sendable {
    case good
    case moderate
    case minimal
    case unknown
}

public enum InternetLinkGrade: String, Codable, Sendable {
    case excellent
    case good
    case fair
    case poor
    case unavailable
}

public struct LinkQualitySample: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let measuredAt: Date
    public let pathMode: ConnectivityMode
    public let systemLinkQuality: SystemLinkQuality
    public let diagnosticOverride: Bool
    public let succeeded: Bool
    public let statusCode: Int?
    public let timeToFirstByteMilliseconds: Double?
    public let totalDurationMilliseconds: Double
    public let dnsMilliseconds: Double?
    public let connectMilliseconds: Double?
    public let tlsMilliseconds: Double?
    public let protocolName: String?
    public let reusedConnection: Bool
    public let requestBytes: Int64
    public let responseBytes: Int64
    public let qualityScore: Double
    public let errorDescription: String?
    public let satelliteID: Int?
    public let satelliteName: String?
    public let estimatedSatelliteSignalScore: Double?
    public let satelliteServingProbability: Double?
    public let satelliteElevationDegrees: Double?
    public let satelliteSlantRangeKilometers: Double?
    public let satelliteFreeSpacePathLossDB: Double?
    public let satelliteScanLossDB: Double?
    public let satelliteUplinkMarginDB: Double?
    public let phoneOrientationLossDB: Double?

    public init(
        id: UUID = UUID(),
        measuredAt: Date,
        pathMode: ConnectivityMode,
        systemLinkQuality: SystemLinkQuality,
        diagnosticOverride: Bool,
        succeeded: Bool,
        statusCode: Int?,
        timeToFirstByteMilliseconds: Double?,
        totalDurationMilliseconds: Double,
        dnsMilliseconds: Double?,
        connectMilliseconds: Double?,
        tlsMilliseconds: Double?,
        protocolName: String?,
        reusedConnection: Bool,
        requestBytes: Int64,
        responseBytes: Int64,
        qualityScore: Double,
        errorDescription: String?,
        satelliteID: Int? = nil,
        satelliteName: String? = nil,
        estimatedSatelliteSignalScore: Double? = nil,
        satelliteServingProbability: Double? = nil,
        satelliteElevationDegrees: Double? = nil,
        satelliteSlantRangeKilometers: Double? = nil,
        satelliteFreeSpacePathLossDB: Double? = nil,
        satelliteScanLossDB: Double? = nil,
        satelliteUplinkMarginDB: Double? = nil,
        phoneOrientationLossDB: Double? = nil
    ) {
        self.id = id
        self.measuredAt = measuredAt
        self.pathMode = pathMode
        self.systemLinkQuality = systemLinkQuality
        self.diagnosticOverride = diagnosticOverride
        self.succeeded = succeeded
        self.statusCode = statusCode
        self.timeToFirstByteMilliseconds = timeToFirstByteMilliseconds
        self.totalDurationMilliseconds = totalDurationMilliseconds
        self.dnsMilliseconds = dnsMilliseconds
        self.connectMilliseconds = connectMilliseconds
        self.tlsMilliseconds = tlsMilliseconds
        self.protocolName = protocolName
        self.reusedConnection = reusedConnection
        self.requestBytes = requestBytes
        self.responseBytes = responseBytes
        self.qualityScore = qualityScore
        self.errorDescription = errorDescription
        self.satelliteID = satelliteID
        self.satelliteName = satelliteName
        self.estimatedSatelliteSignalScore = estimatedSatelliteSignalScore
        self.satelliteServingProbability = satelliteServingProbability
        self.satelliteElevationDegrees = satelliteElevationDegrees
        self.satelliteSlantRangeKilometers = satelliteSlantRangeKilometers
        self.satelliteFreeSpacePathLossDB = satelliteFreeSpacePathLossDB
        self.satelliteScanLossDB = satelliteScanLossDB
        self.satelliteUplinkMarginDB = satelliteUplinkMarginDB
        self.phoneOrientationLossDB = phoneOrientationLossDB
    }
}

public enum SatelliteSignalQualityEstimator {
    /// A normalized RF-geometry estimate. This deliberately excludes tracker continuity,
    /// dwell, TLE freshness, and classification confidence so it can be compared with
    /// measured Internet quality as a signal-strength-like series.
    public static func score(
        from diagnostics: ServingCandidateDiagnostics,
        adjustedUplinkMarginDB: Double? = nil
    ) -> Double? {
        guard let geometryScore = score(from: diagnostics.scoreComponents) else { return nil }
        guard let adjustedUplinkMarginDB else { return geometryScore }
        return min(geometryScore, D2CUplinkBudget.qualityScore(forAdjustedMarginDB: adjustedUplinkMarginDB))
    }

    public static func score(from components: [ServingScoreComponent]) -> Double? {
        let radioGeometry = components.filter { component in
            switch component.name {
            case "Elevation", "Range / path loss", "Off-nadir steering", "Estimated scan loss":
                true
            default:
                false
            }
        }
        let totalWeight = radioGeometry.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        let weightedValue = radioGeometry.reduce(0) { $0 + $1.contribution } / totalWeight
        return min(max(weightedValue * 100, 0), 100)
    }
}

public struct LinkQualitySummary: Codable, Hashable, Sendable {
    public let score: Double
    public let grade: InternetLinkGrade
    public let successRate: Double
    public let medianTimeToFirstByteMilliseconds: Double?
    public let jitterMilliseconds: Double?
    public let sampleCount: Int
    public let measuredAt: Date
    public let pathMode: ConnectivityMode
    public let systemLinkQuality: SystemLinkQuality
    public let diagnosticOverride: Bool
    public let cumulativeProbeBytes: Int64

    public init(
        score: Double,
        grade: InternetLinkGrade,
        successRate: Double,
        medianTimeToFirstByteMilliseconds: Double?,
        jitterMilliseconds: Double?,
        sampleCount: Int,
        measuredAt: Date,
        pathMode: ConnectivityMode,
        systemLinkQuality: SystemLinkQuality,
        diagnosticOverride: Bool,
        cumulativeProbeBytes: Int64
    ) {
        self.score = score
        self.grade = grade
        self.successRate = successRate
        self.medianTimeToFirstByteMilliseconds = medianTimeToFirstByteMilliseconds
        self.jitterMilliseconds = jitterMilliseconds
        self.sampleCount = sampleCount
        self.measuredAt = measuredAt
        self.pathMode = pathMode
        self.systemLinkQuality = systemLinkQuality
        self.diagnosticOverride = diagnosticOverride
        self.cumulativeProbeBytes = cumulativeProbeBytes
    }
}

public enum LinkQualityScorer {
    public static func sampleScore(
        succeeded: Bool,
        timeToFirstByteMilliseconds: Double?,
        totalDurationMilliseconds: Double,
        systemQuality: SystemLinkQuality
    ) -> Double {
        guard succeeded, let timeToFirstByteMilliseconds else { return 0 }
        let latency = exp(-max(0, timeToFirstByteMilliseconds - 350) / 4_000) * 100
        let completion = exp(-max(0, totalDurationMilliseconds - 500) / 6_000) * 100
        let passive: Double = switch systemQuality {
        case .good: 95
        case .moderate: 70
        case .minimal: 35
        case .unknown: 60
        }
        return clamped(0.60 * latency + 0.20 * completion + 0.20 * passive)
    }

    public static func summarize(_ samples: [LinkQualitySample], windowCount: Int = 12) -> LinkQualitySummary? {
        guard let latest = samples.last else { return nil }
        let recent = Array(samples.suffix(max(1, windowCount)))
        let successRate = Double(recent.filter(\.succeeded).count) / Double(recent.count)
        let successfulLatencies = recent.compactMap {
            $0.succeeded ? $0.timeToFirstByteMilliseconds : nil
        }.sorted()
        let median = median(successfulLatencies)
        let jitter: Double?
        if successfulLatencies.count >= 2 {
            let chronological = recent.compactMap {
                $0.succeeded ? $0.timeToFirstByteMilliseconds : nil
            }
            let differences = zip(chronological, chronological.dropFirst()).map { abs($0.1 - $0.0) }
            jitter = differences.reduce(0, +) / Double(differences.count)
        } else {
            jitter = nil
        }
        // The headline score drives the app and Live Activity, so it represents the
        // newest availability snapshot. Reliability and latency remain rolling stats.
        let score = clamped(latest.qualityScore)
        let grade: InternetLinkGrade = switch score {
        case 85...: .excellent
        case 70...: .good
        case 50...: .fair
        case 25...: .poor
        default: .unavailable
        }
        return LinkQualitySummary(
            score: score,
            grade: grade,
            successRate: successRate,
            medianTimeToFirstByteMilliseconds: median,
            jitterMilliseconds: jitter,
            sampleCount: recent.count,
            measuredAt: latest.measuredAt,
            pathMode: latest.pathMode,
            systemLinkQuality: latest.systemLinkQuality,
            diagnosticOverride: latest.diagnosticOverride,
            cumulativeProbeBytes: samples.reduce(0) { $0 + $1.requestBytes + $1.responseBytes }
        )
    }

    private static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }

    private static func clamped(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}
