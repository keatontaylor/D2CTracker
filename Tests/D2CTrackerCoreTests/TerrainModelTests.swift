import XCTest
@testable import D2CTrackerCore

final class TerrainModelTests: XCTestCase {
    private let colorado = TerrainRegionBoundary(polygons: [
        TerrainPolygon(rings: [[
            TerrainCoordinate(latitude: 37.0, longitude: -109.05),
            TerrainCoordinate(latitude: 41.0, longitude: -109.05),
            TerrainCoordinate(latitude: 41.0, longitude: -102.05),
            TerrainCoordinate(latitude: 37.0, longitude: -102.05),
            TerrainCoordinate(latitude: 37.0, longitude: -109.05)
        ]])
    ])

    func testPolygonContainmentAndDistance() {
        XCTAssertTrue(colorado.contains(TerrainCoordinate(latitude: 39, longitude: -105.5)))
        XCTAssertFalse(colorado.contains(TerrainCoordinate(latitude: 42, longitude: -105.5)))
        XCTAssertEqual(
            colorado.approximateDistanceKilometers(to: TerrainCoordinate(latitude: 42, longitude: -105.5)),
            110.574,
            accuracy: 1
        )
    }

    func testColoradoStatePlanUsesSkadiDegreeCells() {
        let plan = TerrainTilePlanner.statePlan(for: colorado)
        XCTAssertGreaterThan(plan.tiles.count, 30)
        XCTAssertLessThan(plan.tiles.count, 100)
        XCTAssertTrue(plan.tiles.contains(TerrainTileKey(latitude: 39, longitude: -105)))
        XCTAssertEqual(plan.estimatedBytes, Int64(plan.tiles.count) * 10 * 1_024 * 1_024)
    }

    func testSkadiTileNamingAndCoordinateLookup() {
        let coloradoTile = TerrainTilePlanner.tileKey(containing: TerrainCoordinate(
            latitude: 39.7392,
            longitude: -104.9903
        ))
        XCTAssertEqual(coloradoTile, TerrainTileKey(latitude: 39, longitude: -105))
        XCTAssertEqual(coloradoTile.latitudeName, "N39")
        XCTAssertEqual(coloradoTile.longitudeName, "W105")
        XCTAssertEqual(coloradoTile.relativePath, "skadi/N39/N39W105.hgt.gz")

        let southernEasternTile = TerrainTileKey(latitude: -1, longitude: 5)
        XCTAssertEqual(southernEasternTile.fileName, "S01E005.hgt.gz")
    }

    func testHorizonProfileInterpolatesAcrossNorth() {
        let values = stride(from: 0.0, to: 360.0, by: 10).map { $0 / 10 }
        let profile = TerrainHorizonProfile(
            observer: TerrainCoordinate(latitude: 40, longitude: -105),
            observerElevationMeters: 1_600,
            azimuthStepDegrees: 10,
            elevationDegrees: values,
            maximumRangeKilometers: 400,
            generatedAt: Date(timeIntervalSince1970: 0),
            regionIdentifier: "08"
        )
        XCTAssertEqual(profile.minimumElevationDegrees(atAzimuth: 15), 1.5, accuracy: 1e-12)
        XCTAssertEqual(profile.minimumElevationDegrees(atAzimuth: -5), 17.5, accuracy: 1e-12)
    }

    func testEarthCurvatureLowersDistantTerrain() {
        let nearby = TerrainLineOfSight.apparentElevationDegrees(
            observerElevationMeters: 1_500,
            targetElevationMeters: 1_500,
            distanceKilometers: 1
        )
        let distant = TerrainLineOfSight.apparentElevationDegrees(
            observerElevationMeters: 1_500,
            targetElevationMeters: 1_500,
            distanceKilometers: 100
        )
        XCTAssertLessThan(nearby, 0)
        XCTAssertLessThan(distant, nearby)
    }

    func testNearbyRidgeRequiresMoreRFClearanceAndFadesIn() {
        let terrain = [Double](repeating: 30, count: 360)
        let nearby = TerrainHorizonProfile(
            observer: TerrainCoordinate(latitude: 38, longitude: -108),
            observerElevationMeters: 2_000,
            azimuthStepDegrees: 1,
            elevationDegrees: terrain,
            obstructionDistanceKilometers: [Double](repeating: 0.2, count: 360),
            maximumRangeKilometers: 400,
            generatedAt: .now,
            regionIdentifier: "08"
        )
        let distant = TerrainHorizonProfile(
            observer: nearby.observer,
            observerElevationMeters: 2_000,
            azimuthStepDegrees: 1,
            elevationDegrees: terrain,
            obstructionDistanceKilometers: [Double](repeating: 20, count: 360),
            maximumRangeKilometers: 400,
            generatedAt: .now,
            regionIdentifier: "08"
        )
        XCTAssertGreaterThan(
            nearby.requiredRFClearanceDegrees(atAzimuth: 90),
            distant.requiredRFClearanceDegrees(atAzimuth: 90)
        )
        let rfHorizon = nearby.rfHorizonDegrees(atAzimuth: 90)
        XCTAssertEqual(nearby.clearanceQuality(satelliteElevationDegrees: rfHorizon, atAzimuth: 90), 0, accuracy: 1e-12)
        XCTAssertEqual(nearby.clearanceQuality(satelliteElevationDegrees: rfHorizon + 5, atAzimuth: 90), 1, accuracy: 1e-12)
    }
}
