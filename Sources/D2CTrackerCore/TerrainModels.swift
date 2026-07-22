import Foundation

public struct TerrainCoordinate: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public struct TerrainPolygon: Codable, Hashable, Sendable {
    public let rings: [[TerrainCoordinate]]

    public init(rings: [[TerrainCoordinate]]) {
        self.rings = rings
    }

    public func contains(_ point: TerrainCoordinate) -> Bool {
        guard let outer = rings.first, Self.ringContains(point, ring: outer) else { return false }
        return !rings.dropFirst().contains { Self.ringContains(point, ring: $0) }
    }

    private static func ringContains(_ point: TerrainCoordinate, ring: [TerrainCoordinate]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i]
            let b = ring[j]
            let crossesLatitude = (a.latitude > point.latitude) != (b.latitude > point.latitude)
            if crossesLatitude {
                let longitudeAtLatitude = (b.longitude - a.longitude)
                    * (point.latitude - a.latitude)
                    / (b.latitude - a.latitude)
                    + a.longitude
                if point.longitude < longitudeAtLatitude { inside.toggle() }
            }
            j = i
        }
        return inside
    }
}

public struct TerrainRegionBoundary: Codable, Hashable, Sendable {
    public let polygons: [TerrainPolygon]

    public init(polygons: [TerrainPolygon]) {
        self.polygons = polygons
    }

    public func contains(_ point: TerrainCoordinate) -> Bool {
        polygons.contains { $0.contains(point) }
    }

    public var coordinates: [TerrainCoordinate] {
        polygons.flatMap(\.rings).flatMap { $0 }
    }

    public var bounds: (minimumLatitude: Double, minimumLongitude: Double, maximumLatitude: Double, maximumLongitude: Double)? {
        let values = coordinates
        guard let first = values.first else { return nil }
        return values.dropFirst().reduce(
            (first.latitude, first.longitude, first.latitude, first.longitude)
        ) { result, coordinate in
            (
                min(result.0, coordinate.latitude),
                min(result.1, coordinate.longitude),
                max(result.2, coordinate.latitude),
                max(result.3, coordinate.longitude)
            )
        }
    }

    /// A local equirectangular approximation is sufficiently accurate for tile inclusion bands.
    public func approximateDistanceKilometers(to point: TerrainCoordinate) -> Double {
        if contains(point) { return 0 }
        var best = Double.infinity
        for polygon in polygons {
            for ring in polygon.rings where ring.count > 1 {
                for index in 1..<ring.count {
                    best = min(best, Self.distanceToSegment(point, ring[index - 1], ring[index]))
                }
            }
        }
        return best
    }

    private static func distanceToSegment(
        _ point: TerrainCoordinate,
        _ start: TerrainCoordinate,
        _ end: TerrainCoordinate
    ) -> Double {
        let referenceLatitude = point.latitude * .pi / 180
        let kilometersPerLongitudeDegree = 111.32 * cos(referenceLatitude)
        let px = point.longitude * kilometersPerLongitudeDegree
        let py = point.latitude * 110.574
        let ax = start.longitude * kilometersPerLongitudeDegree
        let ay = start.latitude * 110.574
        let bx = end.longitude * kilometersPerLongitudeDegree
        let by = end.latitude * 110.574
        let dx = bx - ax
        let dy = by - ay
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(px - ax, py - ay) }
        let fraction = max(0, min(1, ((px - ax) * dx + (py - ay) * dy) / lengthSquared))
        return hypot(px - (ax + fraction * dx), py - (ay + fraction * dy))
    }
}

public struct TerrainTileKey: Codable, Hashable, Sendable, Identifiable {
    /// Integer southwest corner of a one-degree Skadi/HGT cell.
    public let latitude: Int
    public let longitude: Int

    public init(latitude: Int, longitude: Int) {
        self.latitude = latitude
        self.longitude = longitude
    }

    public var latitudeName: String {
        String(format: "%@%02d", latitude >= 0 ? "N" : "S", abs(latitude))
    }

    public var longitudeName: String {
        String(format: "%@%03d", longitude >= 0 ? "E" : "W", abs(longitude))
    }

    public var fileName: String { "\(latitudeName)\(longitudeName).hgt.gz" }
    public var id: String { "\(latitudeName)\(longitudeName)" }
    public var relativePath: String { "skadi/\(latitudeName)/\(fileName)" }
}

public struct TerrainTilePlan: Sendable {
    public let tiles: [TerrainTileKey]

    public init(tiles: [TerrainTileKey]) {
        self.tiles = tiles
    }

    public var estimatedBytes: Int64 {
        // Terrain-dependent gzip ratios vary considerably. Ten MiB per one-degree
        // 1-arc-second cell is a conservative planning estimate for the US.
        Int64(tiles.count) * 10 * 1_024 * 1_024
    }
}

public enum TerrainTilePlanner {
    public static let serviceRangeKilometers = 48.2803

    /// Skadi provides one-degree HGT cells at approximately 30 m resolution in the US.
    /// A 30-mile margin preserves terrain that can affect the modeled D2C service
    /// envelope without downloading a general-purpose 250-mile terrain pyramid.
    public static func statePlan(for boundary: TerrainRegionBoundary) -> TerrainTilePlan {
        var result = Set<TerrainTileKey>()
        for region in planningRegions(for: boundary) {
            result.formUnion(tiles(for: region, outerKilometers: serviceRangeKilometers))
        }
        return TerrainTilePlan(tiles: result.sorted {
            if $0.latitude != $1.latitude { return $0.latitude < $1.latitude }
            return $0.longitude < $1.longitude
        })
    }

    private static func tiles(
        for boundary: TerrainRegionBoundary,
        outerKilometers: Double
    ) -> Set<TerrainTileKey> {
        guard let bounds = boundary.bounds else { return [] }
        let latitudePadding = outerKilometers / 110.574
        let middleLatitude = (bounds.minimumLatitude + bounds.maximumLatitude) / 2
        let longitudePadding = outerKilometers / max(20, 111.32 * cos(middleLatitude * .pi / 180))
        let minimumLongitude = Int(floor(bounds.minimumLongitude - longitudePadding))
        let maximumLongitude = Int(floor(bounds.maximumLongitude + longitudePadding - 1e-9))
        let minimumLatitude = max(-90, Int(floor(bounds.minimumLatitude - latitudePadding)))
        let maximumLatitude = min(89, Int(floor(bounds.maximumLatitude + latitudePadding - 1e-9)))
        var values = Set<TerrainTileKey>()
        guard minimumLongitude <= maximumLongitude, minimumLatitude <= maximumLatitude else { return values }
        for longitude in minimumLongitude...maximumLongitude {
            for latitude in minimumLatitude...maximumLatitude {
                let center = TerrainCoordinate(
                    latitude: Double(latitude) + 0.5,
                    longitude: Double(longitude) + 0.5
                )
                let halfDiagonal = degreeCellHalfDiagonalKilometers(latitude: center.latitude)
                let distance = boundary.approximateDistanceKilometers(to: center)
                if distance <= outerKilometers + halfDiagonal {
                    values.insert(TerrainTileKey(
                        latitude: latitude,
                        longitude: normalizedLongitudeCell(longitude)
                    ))
                }
            }
        }
        return values
    }

    public static func tileKey(containing coordinate: TerrainCoordinate) -> TerrainTileKey {
        TerrainTileKey(
            latitude: max(-90, min(89, Int(floor(coordinate.latitude)))),
            longitude: normalizedLongitudeCell(Int(floor(coordinate.longitude)))
        )
    }

    private static func planningRegions(for boundary: TerrainRegionBoundary) -> [TerrainRegionBoundary] {
        boundary.polygons.map { polygon in
            let longitudes = polygon.rings.flatMap { $0.map(\.longitude) }
            guard let minimum = longitudes.min(), let maximum = longitudes.max(), maximum - minimum > 180 else {
                return TerrainRegionBoundary(polygons: [polygon])
            }
            let shifted = TerrainPolygon(rings: polygon.rings.map { ring in
                ring.map { coordinate in
                    TerrainCoordinate(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude < 0 ? coordinate.longitude + 360 : coordinate.longitude
                    )
                }
            })
            return TerrainRegionBoundary(polygons: [shifted])
        }
    }

    private static func normalizedLongitudeCell(_ longitude: Int) -> Int {
        var value = longitude % 360
        if value < -180 { value += 360 }
        if value >= 180 { value -= 360 }
        return value
    }

    private static func degreeCellHalfDiagonalKilometers(latitude: Double) -> Double {
        hypot(110.574 / 2, 111.32 * cos(latitude * .pi / 180) / 2)
    }
}

public struct TerrainHorizonProfile: Codable, Hashable, Sendable {
    public let observer: TerrainCoordinate
    public let observerElevationMeters: Double
    public let azimuthStepDegrees: Double
    public let elevationDegrees: [Double]
    public let obstructionDistanceKilometers: [Double]?
    public let maximumRangeKilometers: Double
    public let generatedAt: Date
    public let regionIdentifier: String

    public init(
        observer: TerrainCoordinate,
        observerElevationMeters: Double,
        azimuthStepDegrees: Double,
        elevationDegrees: [Double],
        obstructionDistanceKilometers: [Double]? = nil,
        maximumRangeKilometers: Double,
        generatedAt: Date,
        regionIdentifier: String
    ) {
        self.observer = observer
        self.observerElevationMeters = observerElevationMeters
        self.azimuthStepDegrees = azimuthStepDegrees
        self.elevationDegrees = elevationDegrees
        self.obstructionDistanceKilometers = obstructionDistanceKilometers
        self.maximumRangeKilometers = maximumRangeKilometers
        self.generatedAt = generatedAt
        self.regionIdentifier = regionIdentifier
    }

    public func minimumElevationDegrees(atAzimuth azimuth: Double) -> Double {
        interpolatedValue(in: elevationDegrees, atAzimuth: azimuth) ?? 0
    }

    public func obstructionDistanceKilometers(atAzimuth azimuth: Double) -> Double? {
        guard let obstructionDistanceKilometers else { return nil }
        return interpolatedValue(in: obstructionDistanceKilometers, atAzimuth: azimuth)
    }

    /// Extra angular clearance above the physical ridge. This includes 60% of the
    /// first Fresnel zone at the D2C downlink wavelength, representative DEM height
    /// uncertainty, and a small clutter/refraction allowance.
    public func requiredRFClearanceDegrees(atAzimuth azimuth: Double) -> Double {
        let terrainAngle = minimumElevationDegrees(atAzimuth: azimuth)
        guard terrainAngle > 0.1 else { return 0 }
        guard let distanceKilometers = obstructionDistanceKilometers(atAzimuth: azimuth),
              distanceKilometers > 0.05 else { return 1.5 }
        let distanceMeters = distanceKilometers * 1_000
        let wavelengthMeters = 299_792_458 / D2CLinkGeometry.downlinkFrequencyHz
        let firstFresnelRadiusMeters = sqrt(wavelengthMeters * distanceMeters)
        let fresnelAngle = atan2(0.6 * firstFresnelRadiusMeters, distanceMeters) * 180 / .pi
        let demUncertaintyAngle = atan2(12.0, distanceMeters) * 180 / .pi
        return max(1.0, min(4.0, 0.75 + fresnelAngle + demUncertaintyAngle))
    }

    public func rfHorizonDegrees(atAzimuth azimuth: Double) -> Double {
        minimumElevationDegrees(atAzimuth: azimuth) + requiredRFClearanceDegrees(atAzimuth: azimuth)
    }

    public func clearanceQuality(
        satelliteElevationDegrees: Double,
        atAzimuth azimuth: Double,
        transitionDegrees: Double = 5
    ) -> Double {
        let terrainAngle = minimumElevationDegrees(atAzimuth: azimuth)
        guard terrainAngle > 0.1 else { return 1 }
        let excess = satelliteElevationDegrees - rfHorizonDegrees(atAzimuth: azimuth)
        let linear = max(0, min(1, excess / max(0.1, transitionDegrees)))
        return linear * linear * (3 - 2 * linear)
    }

    private func interpolatedValue(in values: [Double], atAzimuth azimuth: Double) -> Double? {
        guard !values.isEmpty, azimuthStepDegrees > 0 else { return nil }
        let normalized = ((azimuth.truncatingRemainder(dividingBy: 360)) + 360)
            .truncatingRemainder(dividingBy: 360)
        let index = normalized / azimuthStepDegrees
        let lower = Int(floor(index)) % values.count
        let upper = (lower + 1) % values.count
        let fraction = index - floor(index)
        return values[lower] + (values[upper] - values[lower]) * fraction
    }
}

public enum TerrainLineOfSight {
    public static func apparentElevationDegrees(
        observerElevationMeters: Double,
        targetElevationMeters: Double,
        distanceKilometers: Double,
        effectiveEarthRadiusKilometers: Double = 6_371.0088 * 4 / 3
    ) -> Double {
        guard distanceKilometers > 0 else { return -90 }
        let curvatureDropMeters = distanceKilometers * distanceKilometers
            / (2 * effectiveEarthRadiusKilometers) * 1_000
        let relativeMeters = targetElevationMeters - observerElevationMeters - curvatureDropMeters
        return atan2(relativeMeters, distanceKilometers * 1_000) * 180 / .pi
    }

    public static func destination(
        from origin: TerrainCoordinate,
        azimuthDegrees: Double,
        distanceKilometers: Double
    ) -> TerrainCoordinate {
        let angularDistance = distanceKilometers / 6_371.0088
        let bearing = azimuthDegrees * .pi / 180
        let latitude = origin.latitude * .pi / 180
        let longitude = origin.longitude * .pi / 180
        let destinationLatitude = asin(
            sin(latitude) * cos(angularDistance)
                + cos(latitude) * sin(angularDistance) * cos(bearing)
        )
        let destinationLongitude = longitude + atan2(
            sin(bearing) * sin(angularDistance) * cos(latitude),
            cos(angularDistance) - sin(latitude) * sin(destinationLatitude)
        )
        return TerrainCoordinate(
            latitude: destinationLatitude * 180 / .pi,
            longitude: ((destinationLongitude * 180 / .pi + 540).truncatingRemainder(dividingBy: 360)) - 180
        )
    }
}
