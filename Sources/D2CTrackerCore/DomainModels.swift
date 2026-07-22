import Foundation

public struct Vector3: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(x: Double, y: Double, z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public var magnitude: Double { sqrt(x * x + y * y + z * z) }
}

public struct ObserverLocation: Codable, Hashable, Sendable {
    public var latitude: Double
    public var longitude: Double
    public var altitudeKilometers: Double
    public var horizontalAccuracyKilometers: Double?

    public init(
        latitude: Double,
        longitude: Double,
        altitudeKilometers: Double = 0,
        horizontalAccuracyKilometers: Double? = nil
    ) {
        self.latitude = latitude
        self.longitude = longitude
        self.altitudeKilometers = altitudeKilometers
        self.horizontalAccuracyKilometers = horizontalAccuracyKilometers
    }
}

public enum DataSource: String, Codable, Sendable {
    case celesTrakJSON
    case celesTrakTLE
    case bundledSample
}

public struct OrbitalElements: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { noradID }
    public let noradID: Int
    public let name: String
    public let internationalDesignator: String
    public let epoch: Date
    public let eccentricity: Double
    public let inclinationDegrees: Double
    public let rightAscensionDegrees: Double
    public let argumentOfPerigeeDegrees: Double
    public let meanAnomalyDegrees: Double
    public let meanMotionRevolutionsPerDay: Double
    public let bstar: Double
    public let ephemerisType: Int
    public let classificationType: String
    public let elementSetNumber: Int
    public let revolutionAtEpoch: Int
    public let tleLine1: String?
    public let tleLine2: String?
    public let source: DataSource
    public let fetchedAt: Date

    public init(
        noradID: Int,
        name: String,
        internationalDesignator: String = "",
        epoch: Date,
        eccentricity: Double,
        inclinationDegrees: Double,
        rightAscensionDegrees: Double,
        argumentOfPerigeeDegrees: Double,
        meanAnomalyDegrees: Double,
        meanMotionRevolutionsPerDay: Double,
        bstar: Double = 0,
        ephemerisType: Int = 0,
        classificationType: String = "U",
        elementSetNumber: Int = 0,
        revolutionAtEpoch: Int = 0,
        tleLine1: String? = nil,
        tleLine2: String? = nil,
        source: DataSource,
        fetchedAt: Date
    ) {
        self.noradID = noradID
        self.name = name
        self.internationalDesignator = internationalDesignator
        self.epoch = epoch
        self.eccentricity = eccentricity
        self.inclinationDegrees = inclinationDegrees
        self.rightAscensionDegrees = rightAscensionDegrees
        self.argumentOfPerigeeDegrees = argumentOfPerigeeDegrees
        self.meanAnomalyDegrees = meanAnomalyDegrees
        self.meanMotionRevolutionsPerDay = meanMotionRevolutionsPerDay
        self.bstar = bstar
        self.ephemerisType = ephemerisType
        self.classificationType = classificationType
        self.elementSetNumber = elementSetNumber
        self.revolutionAtEpoch = revolutionAtEpoch
        self.tleLine1 = tleLine1
        self.tleLine2 = tleLine2
        self.source = source
        self.fetchedAt = fetchedAt
    }
}

public struct DirectToCellManifest: Codable, Hashable, Sendable {
    public let generatedAt: Date
    public let satellites: [Entry]

    public struct Entry: Codable, Hashable, Sendable {
        public let noradID: Int
        public let name: String
        public let directToCell: Bool
        public let status: OperationalStatus
        public let generation: String?
        public let confidence: Double

        enum CodingKeys: String, CodingKey {
            case noradID = "noradId"
            case name, directToCell, status, generation, confidence
        }
    }
}

public enum OperationalStatus: String, Codable, Hashable, Sendable {
    case operational
    case testing
    case inactive
    case unknown
}

public enum ClassificationSource: String, Codable, Hashable, Sendable {
    case manifest
    case gpObjectNameDTC
    case unclassified
}

public struct SatelliteRecord: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { elements.noradID }
    public let elements: OrbitalElements
    public let directToCell: Bool
    public let operationalStatus: OperationalStatus
    public let generation: String?
    public let classificationConfidence: Double
    public let classificationSource: ClassificationSource?

    public init(
        elements: OrbitalElements,
        directToCell: Bool,
        operationalStatus: OperationalStatus,
        generation: String?,
        classificationConfidence: Double,
        classificationSource: ClassificationSource
    ) {
        self.elements = elements
        self.directToCell = directToCell
        self.operationalStatus = operationalStatus
        self.generation = generation
        self.classificationConfidence = classificationConfidence
        self.classificationSource = classificationSource
    }
}

public struct CatalogSnapshot: Codable, Sendable {
    public let records: [SatelliteRecord]
    public let fetchedAt: Date
    public let manifestGeneratedAt: Date
    public let etag: String?
    public let lastModified: String?
    public let sourceURL: URL?

    public init(
        records: [SatelliteRecord],
        fetchedAt: Date,
        manifestGeneratedAt: Date,
        etag: String? = nil,
        lastModified: String? = nil,
        sourceURL: URL? = nil
    ) {
        self.records = records
        self.fetchedAt = fetchedAt
        self.manifestGeneratedAt = manifestGeneratedAt
        self.etag = etag
        self.lastModified = lastModified
        self.sourceURL = sourceURL
    }
}

public enum CatalogFreshness: String, Codable, Sendable {
    case fresh
    case aging
    case stale
    case veryStale

    public static func classify(age: TimeInterval) -> Self {
        switch age {
        case ..<(6 * 3_600): .fresh
        case ..<(24 * 3_600): .aging
        case ..<(72 * 3_600): .stale
        default: .veryStale
        }
    }
}

/// Operational age of the orbital-element epoch. This is intentionally separate
/// from `CatalogFreshness`: a newly downloaded catalog can legitimately contain
/// the provider's latest element set with an epoch many hours in the past.
public enum TLEEpochFreshness: String, Codable, Sendable {
    case current
    case aging
    case stale

    public static func classify(age: TimeInterval) -> Self {
        switch age {
        case ..<(36 * 3_600): .current
        case ..<(72 * 3_600): .aging
        default: .stale
        }
    }
}

public enum ConnectivityMode: String, Codable, CaseIterable, Sendable {
    case wifi
    case wiredEthernet
    case terrestrialCellular
    case constrained
    case ultraConstrained
    case offline
    case unknown

    public var permitsCatalogRefresh: Bool {
        switch self {
        case .wifi, .wiredEthernet, .terrestrialCellular, .constrained, .ultraConstrained: true
        case .offline, .unknown: false
        }
    }
}

public struct GeodeticPosition: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let altitudeKilometers: Double
}

public struct SatelliteState: Codable, Hashable, Sendable {
    public let eciKilometers: Vector3
    public let ecefKilometers: Vector3
    public let geodetic: GeodeticPosition
}

public struct SatellitePass: Codable, Hashable, Sendable {
    public let rise: Date
    public let culmination: Date
    public let set: Date
    public let maximumElevationDegrees: Double
}

public struct SatelliteObservation: Codable, Hashable, Sendable, Identifiable {
    public var id: Int { satellite.id }
    public let satellite: SatelliteRecord
    public let state: SatelliteState
    public let azimuthDegrees: Double
    public let elevationDegrees: Double
    public let slantRangeKilometers: Double
    public let rangeRateKilometersPerSecond: Double
    public let elevationRateDegreesPerSecond: Double
    public let offNadirDegrees: Double
    public let predictedUplinkDopplerHz: Double
    public let predictedDownlinkDopplerHz: Double
    public let predictedDownlinkDopplerRateHzPerSecond: Double
    public let freeSpacePathLossDB: Double
    public let observerHorizontalAccuracyKilometers: Double?
    public let pass: SatellitePass?
    public let observedAt: Date

    public var isAboveHorizon: Bool { elevationDegrees >= 0 }

    public init(
        satellite: SatelliteRecord,
        state: SatelliteState,
        azimuthDegrees: Double,
        elevationDegrees: Double,
        slantRangeKilometers: Double,
        rangeRateKilometersPerSecond: Double = 0,
        elevationRateDegreesPerSecond: Double = 0,
        offNadirDegrees: Double = 0,
        predictedUplinkDopplerHz: Double = 0,
        predictedDownlinkDopplerHz: Double = 0,
        predictedDownlinkDopplerRateHzPerSecond: Double = 0,
        freeSpacePathLossDB: Double = 0,
        observerHorizontalAccuracyKilometers: Double? = nil,
        pass: SatellitePass?,
        observedAt: Date
    ) {
        self.satellite = satellite
        self.state = state
        self.azimuthDegrees = azimuthDegrees
        self.elevationDegrees = elevationDegrees
        self.slantRangeKilometers = slantRangeKilometers
        self.rangeRateKilometersPerSecond = rangeRateKilometersPerSecond
        self.elevationRateDegreesPerSecond = elevationRateDegreesPerSecond
        self.offNadirDegrees = offNadirDegrees
        self.predictedUplinkDopplerHz = predictedUplinkDopplerHz
        self.predictedDownlinkDopplerHz = predictedDownlinkDopplerHz
        self.predictedDownlinkDopplerRateHzPerSecond = predictedDownlinkDopplerRateHzPerSecond
        self.freeSpacePathLossDB = freeSpacePathLossDB
        self.observerHorizontalAccuracyKilometers = observerHorizontalAccuracyKilometers
        self.pass = pass
        self.observedAt = observedAt
    }
}

public struct GroundTrackPoint: Codable, Hashable, Sendable {
    public let date: Date
    public let latitude: Double
    public let longitude: Double
}

public enum EstimateConfidence: String, Codable, Sendable {
    case high, medium, low
    case insufficientEvidence = "insufficient evidence"

    @available(*, deprecated, renamed: "insufficientEvidence")
    public static var unavailable: Self { .insufficientEvidence }
}

public enum SatelliteMotionState: String, Codable, Sendable {
    case rising, setting, nearCulmination
}

public struct ServingScoreComponent: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public let name: String
    public let normalizedValue: Double
    public let weight: Double
    public let contribution: Double

    public init(name: String, normalizedValue: Double, weight: Double) {
        self.name = name
        self.normalizedValue = normalizedValue
        self.weight = weight
        contribution = normalizedValue * weight
    }
}

public struct ServingCandidateDiagnostics: Codable, Sendable, Identifiable {
    public var id: Int { satellite.id }
    public let satellite: SatelliteRecord
    public let suitability: Double
    public var probability: Double
    public let elevationDegrees: Double
    public let slantRangeKilometers: Double
    public let rangeRateKilometersPerSecond: Double
    public let offNadirDegrees: Double
    public let predictedUplinkDopplerHz: Double
    public let predictedDownlinkDopplerHz: Double
    public let predictedDownlinkDopplerRateHzPerSecond: Double
    public let freeSpacePathLossDB: Double
    public let estimatedScanLossDB: Double
    public let estimatedUplinkMarginDB: Double?
    public let remainingDwellSeconds: TimeInterval
    public let motionState: SatelliteMotionState
    public let tleAgeSeconds: TimeInterval
    public let terrainClearanceQuality: Double?
    public let scoreComponents: [ServingScoreComponent]

    public init(
        satellite: SatelliteRecord,
        suitability: Double,
        probability: Double = 0,
        elevationDegrees: Double,
        slantRangeKilometers: Double,
        rangeRateKilometersPerSecond: Double,
        offNadirDegrees: Double,
        predictedUplinkDopplerHz: Double,
        predictedDownlinkDopplerHz: Double,
        predictedDownlinkDopplerRateHzPerSecond: Double,
        freeSpacePathLossDB: Double,
        estimatedScanLossDB: Double,
        estimatedUplinkMarginDB: Double? = nil,
        remainingDwellSeconds: TimeInterval,
        motionState: SatelliteMotionState,
        tleAgeSeconds: TimeInterval,
        terrainClearanceQuality: Double? = nil,
        scoreComponents: [ServingScoreComponent]
    ) {
        self.satellite = satellite
        self.suitability = suitability
        self.probability = probability
        self.elevationDegrees = elevationDegrees
        self.slantRangeKilometers = slantRangeKilometers
        self.rangeRateKilometersPerSecond = rangeRateKilometersPerSecond
        self.offNadirDegrees = offNadirDegrees
        self.predictedUplinkDopplerHz = predictedUplinkDopplerHz
        self.predictedDownlinkDopplerHz = predictedDownlinkDopplerHz
        self.predictedDownlinkDopplerRateHzPerSecond = predictedDownlinkDopplerRateHzPerSecond
        self.freeSpacePathLossDB = freeSpacePathLossDB
        self.estimatedScanLossDB = estimatedScanLossDB
        self.estimatedUplinkMarginDB = estimatedUplinkMarginDB
        self.remainingDwellSeconds = remainingDwellSeconds
        self.motionState = motionState
        self.tleAgeSeconds = tleAgeSeconds
        self.terrainClearanceQuality = terrainClearanceQuality
        self.scoreComponents = scoreComponents
    }
}

public enum HandoffPhase: String, Codable, Sendable {
    case stable
    case evaluatingChallenger
    case deferred
    case handedOff
    case incumbentLost
    case insufficientEvidence
}

public struct HandoffStatus: Codable, Sendable {
    public let phase: HandoffPhase
    public let incumbentSatelliteID: Int?
    public let challengerSatelliteID: Int?
    public let reason: String

    public init(
        phase: HandoffPhase,
        incumbentSatelliteID: Int?,
        challengerSatelliteID: Int?,
        reason: String
    ) {
        self.phase = phase
        self.incumbentSatelliteID = incumbentSatelliteID
        self.challengerSatelliteID = challengerSatelliteID
        self.reason = reason
    }
}

public struct ServingSatelliteEstimate: Codable, Sendable {
    public let satellite: SatelliteRecord?
    public let confidence: EstimateConfidence
    public let score: Double
    public let reasons: [String]
    public let selectedDiagnostics: ServingCandidateDiagnostics?
    public let alternatives: [ServingCandidateDiagnostics]
    public let handoff: HandoffStatus
    public let estimatedHandoffAt: Date?
    public let modelVersion: String
    public let estimatedAt: Date

    public init(
        satellite: SatelliteRecord?,
        confidence: EstimateConfidence,
        score: Double,
        reasons: [String],
        selectedDiagnostics: ServingCandidateDiagnostics? = nil,
        alternatives: [ServingCandidateDiagnostics] = [],
        handoff: HandoffStatus = HandoffStatus(
            phase: .insufficientEvidence,
            incumbentSatelliteID: nil,
            challengerSatelliteID: nil,
            reason: "No serving candidate has been inferred."
        ),
        estimatedHandoffAt: Date? = nil,
        modelVersion: String = "legacy",
        estimatedAt: Date
    ) {
        self.satellite = satellite
        self.confidence = confidence
        self.score = score
        self.reasons = reasons
        self.selectedDiagnostics = selectedDiagnostics
        self.alternatives = alternatives
        self.handoff = handoff
        self.estimatedHandoffAt = estimatedHandoffAt
        self.modelVersion = modelVersion
        self.estimatedAt = estimatedAt
    }
}
