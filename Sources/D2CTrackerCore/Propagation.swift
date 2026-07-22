import Foundation
import SatelliteKit

public protocol OrbitPropagating: Sendable {
    func state(for elements: OrbitalElements, at date: Date) throws -> SatelliteState
    func observation(for satellite: SatelliteRecord, observer: ObserverLocation, at date: Date) throws -> SatelliteObservation
}

public enum PropagationError: Error, LocalizedError {
    case invalidElements(String)

    public var errorDescription: String? {
        switch self {
        case .invalidElements(let message): "Invalid SGP4 elements: \(message)"
        }
    }
}

public struct SatelliteKitPropagator: OrbitPropagating {
    public init() {}

    public func state(for elements: OrbitalElements, at date: Date) throws -> SatelliteState {
        let satellite = try makeSatellite(elements)
        let julian = CoordinateTransforms.julianDate(date)
        let eci = try satellite.position(julianDays: julian)
        let geodetic = try satellite.geoPosition(julianDays: julian)
        let eciVector = Vector3(x: eci.x, y: eci.y, z: eci.z)
        return SatelliteState(
            eciKilometers: eciVector,
            ecefKilometers: CoordinateTransforms.eciToECEF(eciVector, at: date),
            geodetic: GeodeticPosition(latitude: geodetic.lat, longitude: geodetic.lon, altitudeKilometers: geodetic.alt)
        )
    }

    public func observation(for satellite: SatelliteRecord, observer: ObserverLocation, at date: Date) throws -> SatelliteObservation {
        let propagated = try makeSatellite(satellite.elements)
        let julian = CoordinateTransforms.julianDate(date)
        let state = try state(for: satellite.elements, at: date)
        let top = try propagated.topPosition(
            julianDays: julian,
            observer: LatLonAlt(observer.latitude, observer.longitude, observer.altitudeKilometers)
        )
        return SatelliteObservation(
            satellite: satellite,
            state: state,
            azimuthDegrees: top.azim,
            elevationDegrees: top.elev,
            slantRangeKilometers: top.dist,
            offNadirDegrees: D2CLinkGeometry.offNadirDegrees(
                satelliteECEF: state.ecefKilometers,
                observer: observer
            ),
            freeSpacePathLossDB: D2CLinkGeometry.freeSpacePathLossDB(
                rangeKilometers: top.dist,
                frequencyHz: D2CLinkGeometry.downlinkFrequencyHz
            ),
            observerHorizontalAccuracyKilometers: observer.horizontalAccuracyKilometers,
            pass: nil,
            observedAt: date
        )
    }

    private func makeSatellite(_ value: OrbitalElements) throws -> Satellite {
        if let line1 = value.tleLine1, let line2 = value.tleLine2 {
            do { return Satellite(withTLE: try Elements(value.name, line1, line2)) }
            catch { throw PropagationError.invalidElements(error.localizedDescription) }
        }

        let payload: [String: Any] = [
            "OBJECT_NAME": value.name,
            "NORAD_CAT_ID": value.noradID,
            "OBJECT_ID": value.internationalDesignator,
            "EPOCH": ISO8601DateFormatter.formatFractional(value.epoch),
            "ECCENTRICITY": value.eccentricity,
            "INCLINATION": value.inclinationDegrees,
            "RA_OF_ASC_NODE": value.rightAscensionDegrees,
            "ARG_OF_PERICENTER": value.argumentOfPerigeeDegrees,
            "MEAN_ANOMALY": value.meanAnomalyDegrees,
            "MEAN_MOTION": value.meanMotionRevolutionsPerDay,
            "BSTAR": value.bstar,
            "EPHEMERIS_TYPE": value.ephemerisType,
            "CLASSIFICATION_TYPE": value.classificationType,
            "ELEMENT_SET_NO": value.elementSetNumber,
            "REV_AT_EPOCH": value.revolutionAtEpoch
        ]
        do {
            let data = try JSONSerialization.data(withJSONObject: payload)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let value = try decoder.singleValueContainer().decode(String.self)
                guard let date = ISO8601DateFormatter.parseFlexible(value) else {
                    throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid epoch"))
                }
                return date
            }
            return Satellite(withTLE: try decoder.decode(Elements.self, from: data))
        } catch {
            throw PropagationError.invalidElements(error.localizedDescription)
        }
    }
}

public enum CoordinateTransforms {
    public static func julianDate(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    public static func greenwichMeanSiderealTimeRadians(at date: Date) -> Double {
        let jd = julianDate(date)
        let centuries = (jd - 2_451_545.0) / 36_525.0
        let degrees = 280.46061837 + 360.98564736629 * (jd - 2_451_545.0)
            + 0.000387933 * centuries * centuries
            - centuries * centuries * centuries / 38_710_000
        return normalizedDegrees(degrees) * .pi / 180
    }

    public static func eciToECEF(_ eci: Vector3, at date: Date) -> Vector3 {
        let theta = greenwichMeanSiderealTimeRadians(at: date)
        return Vector3(
            x: cos(theta) * eci.x + sin(theta) * eci.y,
            y: -sin(theta) * eci.x + cos(theta) * eci.y,
            z: eci.z
        )
    }

    public static func normalizedDegrees(_ degrees: Double) -> Double {
        let value = degrees.truncatingRemainder(dividingBy: 360)
        return value < 0 ? value + 360 : value
    }
}

public actor PropagationService {
    private let propagator: any OrbitPropagating
    private var trackCache: [TrackKey: [GroundTrackPoint]] = [:]
    private var passCache: [PassKey: SatellitePass] = [:]

    public init(propagator: any OrbitPropagating = SatelliteKitPropagator()) {
        self.propagator = propagator
    }

    public func observations(
        for satellites: [SatelliteRecord],
        observer: ObserverLocation,
        at date: Date,
        elevationMask: Double = 10
    ) -> [SatelliteObservation] {
        satellites.compactMap { satellite in
            guard let observation = try? propagator.observation(for: satellite, observer: observer, at: date) else { return nil }
            guard observation.elevationDegrees >= elevationMask else { return observation }
            let pass = cachedPass(
                for: satellite,
                observer: observer,
                from: date,
                elevationMask: elevationMask
            )
            return enriched(
                observation,
                satellite: satellite,
                observer: observer,
                pass: pass,
                at: date
            )
        }
    }

    public func groundTrack(
        for satellite: SatelliteRecord,
        centeredAt date: Date,
        window: TimeInterval = 5_400,
        step: TimeInterval = 120
    ) -> [GroundTrackPoint] {
        let bucket = Int(date.timeIntervalSince1970 / 300)
        let key = TrackKey(noradID: satellite.id, bucket: bucket, window: Int(window), step: Int(step))
        if let cached = trackCache[key] { return cached }
        let points = stride(from: -window, through: window, by: step).compactMap { offset -> GroundTrackPoint? in
            let sampleDate = date.addingTimeInterval(offset)
            guard let state = try? propagator.state(for: satellite.elements, at: sampleDate) else { return nil }
            return GroundTrackPoint(date: sampleDate, latitude: state.geodetic.latitude, longitude: state.geodetic.longitude)
        }
        trackCache[key] = points
        if trackCache.count > 24 { trackCache.removeAll(keepingCapacity: true) }
        return points
    }

    public func predictCurrentOrNextPass(
        for satellite: SatelliteRecord,
        observer: ObserverLocation,
        from start: Date,
        elevationMask: Double = 10,
        horizon: TimeInterval = 24 * 3_600,
        step: TimeInterval = 30
    ) -> SatellitePass? {
        var previousDate = start
        var previousElevation = elevation(for: satellite, observer: observer, date: start) ?? -90
        var rise: Date? = previousElevation >= elevationMask ? start : nil
        var maximum = previousElevation
        var culmination = start

        for offset in stride(from: step, through: horizon, by: step) {
            let date = start.addingTimeInterval(offset)
            guard let current = elevation(for: satellite, observer: observer, date: date) else { continue }
            if rise == nil, previousElevation < elevationMask, current >= elevationMask {
                rise = refinedCrossing(satellite, observer: observer, lower: previousDate, upper: date, mask: elevationMask)
                maximum = current
                culmination = date
            }
            if rise != nil, current > maximum {
                maximum = current
                culmination = date
            }
            if let rise, previousElevation >= elevationMask, current < elevationMask {
                let set = refinedCrossing(satellite, observer: observer, lower: previousDate, upper: date, mask: elevationMask)
                return SatellitePass(rise: rise, culmination: culmination, set: set, maximumElevationDegrees: maximum)
            }
            previousDate = date
            previousElevation = current
        }
        return nil
    }

    private func elevation(for satellite: SatelliteRecord, observer: ObserverLocation, date: Date) -> Double? {
        try? propagator.observation(for: satellite, observer: observer, at: date).elevationDegrees
    }

    private func enriched(
        _ observation: SatelliteObservation,
        satellite: SatelliteRecord,
        observer: ObserverLocation,
        pass: SatellitePass?,
        at date: Date
    ) -> SatelliteObservation {
        let interval = 2.0
        let previous = try? propagator.observation(
            for: satellite,
            observer: observer,
            at: date.addingTimeInterval(-interval)
        )
        let next = try? propagator.observation(
            for: satellite,
            observer: observer,
            at: date.addingTimeInterval(interval)
        )
        let rangeRate: Double
        let elevationRate: Double
        let rangeAcceleration: Double
        if let previous, let next {
            rangeRate = (next.slantRangeKilometers - previous.slantRangeKilometers) / (2 * interval)
            elevationRate = (next.elevationDegrees - previous.elevationDegrees) / (2 * interval)
            rangeAcceleration = (
                next.slantRangeKilometers
                    - 2 * observation.slantRangeKilometers
                    + previous.slantRangeKilometers
            ) / (interval * interval)
        } else {
            rangeRate = 0
            elevationRate = 0
            rangeAcceleration = 0
        }

        return SatelliteObservation(
            satellite: observation.satellite,
            state: observation.state,
            azimuthDegrees: observation.azimuthDegrees,
            elevationDegrees: observation.elevationDegrees,
            slantRangeKilometers: observation.slantRangeKilometers,
            rangeRateKilometersPerSecond: rangeRate,
            elevationRateDegreesPerSecond: elevationRate,
            offNadirDegrees: observation.offNadirDegrees,
            predictedUplinkDopplerHz: D2CLinkGeometry.dopplerShiftHz(
                rangeRateKilometersPerSecond: rangeRate,
                frequencyHz: D2CLinkGeometry.uplinkFrequencyHz
            ),
            predictedDownlinkDopplerHz: D2CLinkGeometry.dopplerShiftHz(
                rangeRateKilometersPerSecond: rangeRate,
                frequencyHz: D2CLinkGeometry.downlinkFrequencyHz
            ),
            predictedDownlinkDopplerRateHzPerSecond: D2CLinkGeometry.dopplerRateHzPerSecond(
                rangeAccelerationKilometersPerSecondSquared: rangeAcceleration,
                frequencyHz: D2CLinkGeometry.downlinkFrequencyHz
            ),
            freeSpacePathLossDB: observation.freeSpacePathLossDB,
            observerHorizontalAccuracyKilometers: observer.horizontalAccuracyKilometers,
            pass: pass,
            observedAt: observation.observedAt
        )
    }

    private func cachedPass(for satellite: SatelliteRecord, observer: ObserverLocation, from date: Date, elevationMask: Double) -> SatellitePass? {
        let key = PassKey(
            noradID: satellite.id,
            latitude: Int((observer.latitude * 100).rounded()),
            longitude: Int((observer.longitude * 100).rounded()),
            mask: Int(elevationMask.rounded()),
            minute: Int(date.timeIntervalSince1970 / 60)
        )
        if let cached = passCache[key] { return cached }
        let value = predictCurrentOrNextPass(for: satellite, observer: observer, from: date, elevationMask: elevationMask, horizon: 3 * 3_600)
        if let value { passCache[key] = value }
        if passCache.count > 128 { passCache.removeAll(keepingCapacity: true) }
        return value
    }

    private func refinedCrossing(_ satellite: SatelliteRecord, observer: ObserverLocation, lower: Date, upper: Date, mask: Double) -> Date {
        var low = lower
        var high = upper
        let rising = (elevation(for: satellite, observer: observer, date: upper) ?? -90) >= mask
        for _ in 0..<8 {
            let middle = low.addingTimeInterval(high.timeIntervalSince(low) / 2)
            let above = (elevation(for: satellite, observer: observer, date: middle) ?? -90) >= mask
            if above == rising { high = middle } else { low = middle }
        }
        return high
    }

    private struct TrackKey: Hashable {
        let noradID: Int
        let bucket: Int
        let window: Int
        let step: Int
    }

    private struct PassKey: Hashable {
        let noradID: Int
        let latitude: Int
        let longitude: Int
        let mask: Int
        let minute: Int
    }
}
