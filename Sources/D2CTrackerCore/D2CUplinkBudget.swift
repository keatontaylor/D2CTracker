import Foundation

/// A deliberately conservative, inspectable return-link estimate for a stock LTE handset.
///
/// Filed values: PCS G uplink frequency, approximately -5 dBi handset antenna gain, and
/// 38 dBi peak space-station antenna gain. The remaining values are engineering priors,
/// not measurements of Starlink's receiver or scheduler, and should be calibrated against
/// real link-quality samples as they become available.
public struct D2CUplinkBudgetAssumptions: Hashable, Sendable {
    public var handsetTransmitPowerDBm: Double
    public var handsetAntennaGainDBI: Double
    public var satellitePeakReceiveGainDBI: Double
    public var satelliteNoiseFigureDB: Double
    public var allocatedBandwidthHz: Double
    public var requiredCarrierToNoiseDB: Double
    public var polarizationLossDB: Double
    public var implementationAndFadeReserveDB: Double
    public var satelliteScanLossExponent: Double
    public var maximumPhoneOrientationLossDB: Double
    public var unknownPhoneOrientationLossDB: Double

    public init(
        handsetTransmitPowerDBm: Double = 23,
        handsetAntennaGainDBI: Double = -5,
        satellitePeakReceiveGainDBI: Double = 38,
        satelliteNoiseFigureDB: Double = 3,
        allocatedBandwidthHz: Double = 1_400_000,
        requiredCarrierToNoiseDB: Double = -4,
        polarizationLossDB: Double = 3,
        implementationAndFadeReserveDB: Double = 2,
        satelliteScanLossExponent: Double = 1.6,
        maximumPhoneOrientationLossDB: Double = 8,
        unknownPhoneOrientationLossDB: Double = 4
    ) {
        self.handsetTransmitPowerDBm = handsetTransmitPowerDBm
        self.handsetAntennaGainDBI = handsetAntennaGainDBI
        self.satellitePeakReceiveGainDBI = satellitePeakReceiveGainDBI
        self.satelliteNoiseFigureDB = satelliteNoiseFigureDB
        self.allocatedBandwidthHz = allocatedBandwidthHz
        self.requiredCarrierToNoiseDB = requiredCarrierToNoiseDB
        self.polarizationLossDB = polarizationLossDB
        self.implementationAndFadeReserveDB = implementationAndFadeReserveDB
        self.satelliteScanLossExponent = satelliteScanLossExponent
        self.maximumPhoneOrientationLossDB = maximumPhoneOrientationLossDB
        self.unknownPhoneOrientationLossDB = unknownPhoneOrientationLossDB
    }

    public static let nominal = D2CUplinkBudgetAssumptions()
}

public enum D2CUplinkQuality: String, Codable, Hashable, Sendable {
    case unavailable
    case possible
    case dependable
    case strong
}

public struct D2CUplinkAssessment: Hashable, Sendable {
    public let clearSkyMarginDB: Double
    public let phoneOrientationLossDB: Double
    public let isPhoneOrientationMeasured: Bool
    public let adjustedMarginDB: Double
    public let quality: D2CUplinkQuality

    public init(
        clearSkyMarginDB: Double,
        phoneOrientationLossDB: Double,
        isPhoneOrientationMeasured: Bool,
        adjustedMarginDB: Double,
        quality: D2CUplinkQuality
    ) {
        self.clearSkyMarginDB = clearSkyMarginDB
        self.phoneOrientationLossDB = phoneOrientationLossDB
        self.isPhoneOrientationMeasured = isPhoneOrientationMeasured
        self.adjustedMarginDB = adjustedMarginDB
        self.quality = quality
    }
}

public enum D2CUplinkBudget {
    public static let earthRadiusKilometers = 6_371.0088
    public static let thermalNoiseDensityDBmPerHz = -174.0
    public static let dependableMarginDB = 5.0
    public static let strongMarginDB = 8.0

    public static func estimatedMarginDB(
        rangeKilometers: Double,
        offNadirDegrees: Double,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> Double {
        let receivedPowerDBm = assumptions.handsetTransmitPowerDBm
            + assumptions.handsetAntennaGainDBI
            + assumptions.satellitePeakReceiveGainDBI
            - D2CLinkGeometry.freeSpacePathLossDB(
                rangeKilometers: rangeKilometers,
                frequencyHz: D2CLinkGeometry.uplinkFrequencyHz
            )
            - D2CLinkGeometry.estimatedScanLossDB(
                offNadirDegrees: offNadirDegrees,
                exponent: assumptions.satelliteScanLossExponent
            )
            - assumptions.polarizationLossDB
        let receiverNoiseDBm = thermalNoiseDensityDBmPerHz
            + 10 * log10(max(1, assumptions.allocatedBandwidthHz))
            + assumptions.satelliteNoiseFigureDB
        let requiredPowerDBm = receiverNoiseDBm
            + assumptions.requiredCarrierToNoiseDB
            + assumptions.implementationAndFadeReserveDB
        return receivedPowerDBm - requiredPowerDBm
    }

    public static func assessment(
        for observation: SatelliteObservation,
        phoneHeadingDegrees: Double?,
        phonePointingElevationDegrees: Double?,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> D2CUplinkAssessment {
        let clearSkyMargin = estimatedMarginDB(for: observation, assumptions: assumptions)
        let measuredLoss = phoneOrientationLossDB(
            satelliteAzimuthDegrees: observation.azimuthDegrees,
            satelliteElevationDegrees: observation.elevationDegrees,
            phoneHeadingDegrees: phoneHeadingDegrees,
            phonePointingElevationDegrees: phonePointingElevationDegrees,
            assumptions: assumptions
        )
        let appliedLoss = measuredLoss ?? assumptions.unknownPhoneOrientationLossDB
        let adjustedMargin = clearSkyMargin - appliedLoss
        return D2CUplinkAssessment(
            clearSkyMarginDB: clearSkyMargin,
            phoneOrientationLossDB: appliedLoss,
            isPhoneOrientationMeasured: measuredLoss != nil,
            adjustedMarginDB: adjustedMargin,
            quality: quality(forAdjustedMarginDB: adjustedMargin)
        )
    }

    /// A phone-attitude-independent reference for visualization. This keeps the
    /// sky envelope stable while the serving model can still apply measured attitude.
    public static func clearSkyAssessment(
        for observation: SatelliteObservation,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> D2CUplinkAssessment {
        let margin = estimatedMarginDB(for: observation, assumptions: assumptions)
        return D2CUplinkAssessment(
            clearSkyMarginDB: margin,
            phoneOrientationLossDB: 0,
            isPhoneOrientationMeasured: false,
            adjustedMarginDB: margin,
            quality: quality(forAdjustedMarginDB: margin)
        )
    }

    /// A smooth engineering prior for handset attitude, not a measured iPhone antenna pattern.
    /// Alignment with the top edge costs 0 dB, a perpendicular path costs half of the cap,
    /// and a path directly behind the top edge reaches the configured maximum loss.
    public static func phoneOrientationLossDB(
        satelliteAzimuthDegrees: Double,
        satelliteElevationDegrees: Double,
        phoneHeadingDegrees: Double?,
        phonePointingElevationDegrees: Double?,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> Double? {
        guard let phoneHeadingDegrees, let phonePointingElevationDegrees else { return nil }
        let separation = angularSeparationDegrees(
            firstAzimuthDegrees: satelliteAzimuthDegrees,
            firstElevationDegrees: satelliteElevationDegrees,
            secondAzimuthDegrees: phoneHeadingDegrees,
            secondElevationDegrees: phonePointingElevationDegrees
        )
        let halfAngle = separation * .pi / 360
        return max(0, assumptions.maximumPhoneOrientationLossDB) * pow(sin(halfAngle), 2)
    }

    public static func angularSeparationDegrees(
        firstAzimuthDegrees: Double,
        firstElevationDegrees: Double,
        secondAzimuthDegrees: Double,
        secondElevationDegrees: Double
    ) -> Double {
        let firstElevation = firstElevationDegrees * .pi / 180
        let secondElevation = secondElevationDegrees * .pi / 180
        let azimuthDifference = (firstAzimuthDegrees - secondAzimuthDegrees) * .pi / 180
        let cosine = sin(firstElevation) * sin(secondElevation)
            + cos(firstElevation) * cos(secondElevation) * cos(azimuthDifference)
        return acos(min(1, max(-1, cosine))) * 180 / .pi
    }

    public static func quality(forAdjustedMarginDB marginDB: Double) -> D2CUplinkQuality {
        switch marginDB {
        case ..<0: .unavailable
        case ..<dependableMarginDB: .possible
        case ..<strongMarginDB: .dependable
        default: .strong
        }
    }

    public static func qualityScore(forAdjustedMarginDB marginDB: Double) -> Double {
        min(100, max(0, (marginDB + 3) / 13 * 100))
    }

    public static func estimatedMarginDB(
        for observation: SatelliteObservation,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> Double {
        estimatedMarginDB(
            rangeKilometers: observation.slantRangeKilometers,
            offNadirDegrees: observation.offNadirDegrees,
            assumptions: assumptions
        )
    }

    /// Clear-sky elevation where the nominal handset return link crosses 0 dB margin.
    /// Terrain and Fresnel clearance should be applied separately by taking the higher edge.
    public static func minimumClearSkyElevationDegrees(
        satelliteAltitudeKilometers: Double,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> Double {
        minimumClearSkyElevationDegrees(
            satelliteAltitudeKilometers: satelliteAltitudeKilometers,
            targetMarginDB: 0,
            assumptions: assumptions
        )
    }

    /// Clear-sky elevation where the nominal handset return link reaches a requested margin.
    public static func minimumClearSkyElevationDegrees(
        satelliteAltitudeKilometers: Double,
        targetMarginDB: Double,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> Double {
        let altitude = max(100, satelliteAltitudeKilometers)
        if marginAtElevation(0, satelliteAltitudeKilometers: altitude, assumptions: assumptions) >= targetMarginDB {
            return 0
        }
        if marginAtElevation(90, satelliteAltitudeKilometers: altitude, assumptions: assumptions) < targetMarginDB {
            return 90
        }

        var lower = 0.0
        var upper = 90.0
        for _ in 0..<36 {
            let middle = (lower + upper) / 2
            if marginAtElevation(middle, satelliteAltitudeKilometers: altitude, assumptions: assumptions) >= targetMarginDB {
                upper = middle
            } else {
                lower = middle
            }
        }
        return upper
    }

    /// Lowest clear-sky elevation that reaches the requested adjusted link margin.
    /// The azimuth-dependent phone attitude loss makes this suitable for drawing a
    /// quality envelope rather than a single circular elevation mask.
    public static func minimumQualityElevationDegrees(
        satelliteAltitudeKilometers: Double,
        satelliteAzimuthDegrees: Double,
        targetAdjustedMarginDB: Double,
        phoneHeadingDegrees: Double?,
        phonePointingElevationDegrees: Double?,
        assumptions: D2CUplinkBudgetAssumptions = .nominal
    ) -> Double {
        let altitude = max(100, satelliteAltitudeKilometers)
        func adjustedMargin(at elevation: Double) -> Double {
            let geometry = geometry(
                elevationDegrees: elevation,
                satelliteAltitudeKilometers: altitude
            )
            let clearSky = estimatedMarginDB(
                rangeKilometers: geometry.rangeKilometers,
                offNadirDegrees: geometry.offNadirDegrees,
                assumptions: assumptions
            )
            let orientation = phoneOrientationLossDB(
                satelliteAzimuthDegrees: satelliteAzimuthDegrees,
                satelliteElevationDegrees: elevation,
                phoneHeadingDegrees: phoneHeadingDegrees,
                phonePointingElevationDegrees: phonePointingElevationDegrees,
                assumptions: assumptions
            ) ?? assumptions.unknownPhoneOrientationLossDB
            return clearSky - orientation
        }

        if adjustedMargin(at: 0) >= targetAdjustedMarginDB { return 0 }
        if adjustedMargin(at: 90) < targetAdjustedMarginDB { return 90 }
        var lower = 0.0
        var upper = 90.0
        for _ in 0..<32 {
            let middle = (lower + upper) / 2
            if adjustedMargin(at: middle) >= targetAdjustedMarginDB { upper = middle }
            else { lower = middle }
        }
        return upper
    }

    public static func geometry(
        elevationDegrees: Double,
        satelliteAltitudeKilometers: Double
    ) -> (rangeKilometers: Double, offNadirDegrees: Double) {
        let elevation = min(90, max(0, elevationDegrees)) * .pi / 180
        let orbitalRadius = earthRadiusKilometers + max(100, satelliteAltitudeKilometers)
        let projectedRadius = earthRadiusKilometers * cos(elevation)
        let range = sqrt(max(0, orbitalRadius * orbitalRadius - projectedRadius * projectedRadius))
            - earthRadiusKilometers * sin(elevation)
        let offNadirSine = min(1, max(0, earthRadiusKilometers / orbitalRadius * cos(elevation)))
        return (range, asin(offNadirSine) * 180 / .pi)
    }

    private static func marginAtElevation(
        _ elevationDegrees: Double,
        satelliteAltitudeKilometers: Double,
        assumptions: D2CUplinkBudgetAssumptions
    ) -> Double {
        let geometry = geometry(
            elevationDegrees: elevationDegrees,
            satelliteAltitudeKilometers: satelliteAltitudeKilometers
        )
        return estimatedMarginDB(
            rangeKilometers: geometry.rangeKilometers,
            offNadirDegrees: geometry.offNadirDegrees,
            assumptions: assumptions
        )
    }
}
