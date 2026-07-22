import Foundation

/// Physics-based link geometry for the midpoint of SpaceX's paired PCS G Block allocation.
public enum D2CLinkGeometry {
    public static let uplinkFrequencyHz = 1_912_500_000.0
    public static let downlinkFrequencyHz = 1_992_500_000.0
    public static let speedOfLightKilometersPerSecond = 299_792.458

    public static func observerECEF(_ observer: ObserverLocation) -> Vector3 {
        let latitude = observer.latitude * .pi / 180
        let longitude = observer.longitude * .pi / 180
        let semiMajorAxis = 6_378.137
        let eccentricitySquared = 6.69437999014e-3
        let primeVertical = semiMajorAxis / sqrt(1 - eccentricitySquared * pow(sin(latitude), 2))
        let height = observer.altitudeKilometers
        return Vector3(
            x: (primeVertical + height) * cos(latitude) * cos(longitude),
            y: (primeVertical + height) * cos(latitude) * sin(longitude),
            z: (primeVertical * (1 - eccentricitySquared) + height) * sin(latitude)
        )
    }

    public static func offNadirDegrees(satelliteECEF: Vector3, observer: ObserverLocation) -> Double {
        let ground = observerECEF(observer)
        let nadir = Vector3(x: -satelliteECEF.x, y: -satelliteECEF.y, z: -satelliteECEF.z)
        let lineOfSight = Vector3(
            x: ground.x - satelliteECEF.x,
            y: ground.y - satelliteECEF.y,
            z: ground.z - satelliteECEF.z
        )
        let denominator = nadir.magnitude * lineOfSight.magnitude
        guard denominator > 0 else { return 0 }
        let cosine = clamped(dot(nadir, lineOfSight) / denominator, lower: -1, upper: 1)
        return acos(cosine) * 180 / .pi
    }

    /// Positive shift means an approaching satellite because range rate is negative while approaching.
    public static func dopplerShiftHz(rangeRateKilometersPerSecond: Double, frequencyHz: Double) -> Double {
        -rangeRateKilometersPerSecond / speedOfLightKilometersPerSecond * frequencyHz
    }

    public static func dopplerRateHzPerSecond(
        rangeAccelerationKilometersPerSecondSquared: Double,
        frequencyHz: Double
    ) -> Double {
        -rangeAccelerationKilometersPerSecondSquared / speedOfLightKilometersPerSecond * frequencyHz
    }

    public static func freeSpacePathLossDB(rangeKilometers: Double, frequencyHz: Double) -> Double {
        guard rangeKilometers > 0, frequencyHz > 0 else { return 0 }
        let frequencyMHz = frequencyHz / 1_000_000
        return 32.44 + 20 * log10(rangeKilometers) + 20 * log10(frequencyMHz)
    }

    /// Heuristic phased-array scan loss based on a cos^n projected-aperture model.
    public static func estimatedScanLossDB(offNadirDegrees: Double, exponent: Double) -> Double {
        let limited = min(max(abs(offNadirDegrees), 0), 89.5) * .pi / 180
        return -10 * max(0, exponent) * log10(max(cos(limited), 1e-6))
    }

    private static func dot(_ lhs: Vector3, _ rhs: Vector3) -> Double {
        lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
    }

    private static func clamped(_ value: Double, lower: Double, upper: Double) -> Double {
        min(max(value, lower), upper)
    }
}
