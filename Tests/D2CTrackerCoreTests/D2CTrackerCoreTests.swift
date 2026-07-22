import XCTest
@testable import D2CTrackerCore

final class GeographicResourceTests: XCTestCase {
    func testDetailedLandAndAdministrativeBoundariesLoad() throws {
        let land = try SampleDataLoader.detailedLandBoundaries()
        let countries = try SampleDataLoader.countryBoundaries()
        let states = try SampleDataLoader.stateProvinceBoundaries()

        XCTAssertGreaterThan(land.count, 1_000)
        XCTAssertGreaterThan(countries.count, 350)
        XCTAssertGreaterThan(states.count, 500)
        XCTAssertTrue((land + countries + states).joined().allSatisfy {
            (-90...90).contains($0.latitude) && (-180...180).contains($0.longitude)
        })
    }
}

final class OrbitalParserTests: XCTestCase {
    func testParsesCelesTrakJSONWithNumericStrings() throws {
        let data = Data("""
        [{
          "OBJECT_NAME":"STARLINK-TEST","NORAD_CAT_ID":"60001","OBJECT_ID":"2024-001A",
          "EPOCH":"2026-07-18T12:00:00.000Z","ECCENTRICITY":"0.00015","INCLINATION":"53.16",
          "RA_OF_ASC_NODE":"12.5","ARG_OF_PERICENTER":"90","MEAN_ANOMALY":"270",
          "MEAN_MOTION":"15.28","BSTAR":"0.00012","EPHEMERIS_TYPE":"0",
          "CLASSIFICATION_TYPE":"U","ELEMENT_SET_NO":"10","REV_AT_EPOCH":"1200"
        }]
        """.utf8)
        let values = try GPJSONParser.parse(data, fetchedAt: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values[0].noradID, 60001)
        XCTAssertEqual(values[0].meanMotionRevolutionsPerDay, 15.28, accuracy: 1e-12)
    }

    func testRejectsMalformedCatalog() {
        XCTAssertThrowsError(try GPJSONParser.parse(Data("[]".utf8)))
    }

    func testParsesCelesTrakUTCEpochWithoutZoneSuffix() throws {
        let data = Data("""
        [{
          "OBJECT_NAME":"STARLINK-11072 [DTC]","NORAD_CAT_ID":58705,"OBJECT_ID":"2024-002A",
          "EPOCH":"2026-07-18T19:47:27.208608","ECCENTRICITY":0.0001363,"INCLINATION":53.1605,
          "RA_OF_ASC_NODE":347.5659,"ARG_OF_PERICENTER":47.333,"MEAN_ANOMALY":312.7802,
          "MEAN_MOTION":15.697073,"BSTAR":-0.0000055806,"EPHEMERIS_TYPE":0,
          "CLASSIFICATION_TYPE":"U","ELEMENT_SET_NO":999,"REV_AT_EPOCH":14703
        }]
        """.utf8)
        let value = try XCTUnwrap(GPJSONParser.parse(data).first)
        XCTAssertEqual(value.name, "STARLINK-11072 [DTC]")
        XCTAssertEqual(value.epoch.timeIntervalSince1970, 1_784_404_047.208608, accuracy: 0.001)
    }

    func testParsesTraditionalTLE() throws {
        let text = """
        VANGUARD 1
        1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753
        2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667
        """
        let values = try TLEParser.parse(text)
        XCTAssertEqual(values.first?.noradID, 5)
        XCTAssertEqual(values.first?.eccentricity ?? 0, 0.1859667, accuracy: 1e-10)
    }

    func testRejectsTLEWithBadChecksum() {
        let text = """
        VANGUARD 1
        1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4754
        2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667
        """
        XCTAssertThrowsError(try TLEParser.parse(text))
    }
}

final class SGP4ReferenceTests: XCTestCase {
    func testValladoSatelliteFiveAtEpoch() throws {
        // Vallado et al., Revisiting Spacetrack Report #3, published verification case 00005.
        let text = """
        VANGUARD 1
        1 00005U 58002B   00179.78495062  .00000023  00000-0  28098-4 0  4753
        2 00005  34.2682 348.7242 1859667 331.7664  19.3264 10.82419157413667
        """
        let elements = try XCTUnwrap(TLEParser.parse(text).first)
        let state = try SatelliteKitPropagator().state(for: elements, at: elements.epoch)
        XCTAssertEqual(state.eciKilometers.x, 7022.46529266, accuracy: 0.001)
        XCTAssertEqual(state.eciKilometers.y, -1400.08296755, accuracy: 0.001)
        XCTAssertEqual(state.eciKilometers.z, 0.03995155, accuracy: 0.001)
    }

    func testECIToECEFPreservesRange() {
        let input = Vector3(x: 7000, y: -1200, z: 400)
        let output = CoordinateTransforms.eciToECEF(input, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(input.magnitude, output.magnitude, accuracy: 1e-9)
    }

    func testObserverAtSubpointSeesSatelliteNearZenith() throws {
        let record = try XCTUnwrap(SampleDataLoader.catalog().records.first)
        let propagator = SatelliteKitPropagator()
        let state = try propagator.state(for: record.elements, at: record.elements.epoch)
        let observer = ObserverLocation(latitude: state.geodetic.latitude, longitude: state.geodetic.longitude)
        let observation = try propagator.observation(for: record, observer: observer, at: record.elements.epoch)
        XCTAssertGreaterThan(observation.elevationDegrees, 89.9)
        XCTAssertEqual(observation.slantRangeKilometers, state.geodetic.altitudeKilometers, accuracy: 5)
    }
}

final class RefreshPolicyTests: XCTestCase {
    func testEligibleModes() {
        XCTAssertTrue(ConnectivityMode.wifi.permitsCatalogRefresh)
        XCTAssertTrue(ConnectivityMode.terrestrialCellular.permitsCatalogRefresh)
        XCTAssertTrue(ConnectivityMode.wiredEthernet.permitsCatalogRefresh)
        XCTAssertTrue(ConnectivityMode.constrained.permitsCatalogRefresh)
        XCTAssertTrue(ConnectivityMode.ultraConstrained.permitsCatalogRefresh)
        XCTAssertFalse(ConnectivityMode.offline.permitsCatalogRefresh)
    }

    func testFreshnessThresholds() {
        XCTAssertEqual(CatalogFreshness.classify(age: 5 * 3_600), .fresh)
        XCTAssertEqual(CatalogFreshness.classify(age: 7 * 3_600), .aging)
        XCTAssertEqual(CatalogFreshness.classify(age: 30 * 3_600), .stale)
        XCTAssertEqual(CatalogFreshness.classify(age: 80 * 3_600), .veryStale)
    }

    func testTLEEpochFreshnessUsesOperationalThresholds() {
        XCTAssertEqual(TLEEpochFreshness.classify(age: 19 * 3_600), .current)
        XCTAssertEqual(TLEEpochFreshness.classify(age: 36 * 3_600), .aging)
        XCTAssertEqual(TLEEpochFreshness.classify(age: 71 * 3_600), .aging)
        XCTAssertEqual(TLEEpochFreshness.classify(age: 72 * 3_600), .stale)
    }

    func testPolicyUsesDeterministicClock() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = RefreshPolicy(staleAfter: 100)
        XCTAssertFalse(policy.shouldRefresh(lastSuccessfulFetch: now.addingTimeInterval(-99), now: now, mode: .wifi))
        XCTAssertTrue(policy.shouldRefresh(lastSuccessfulFetch: now.addingTimeInterval(-100), now: now, mode: .wifi))
        XCTAssertTrue(policy.shouldRefresh(lastSuccessfulFetch: nil, now: now, mode: .constrained))
        XCTAssertTrue(policy.shouldRefresh(lastSuccessfulFetch: nil, now: now, mode: .ultraConstrained))
    }

    func testBundledFallbackNeverSuppressesEligibleBootstrapRefresh() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = RefreshPolicy(staleAfter: 6 * 3_600)
        XCTAssertTrue(policy.shouldRefresh(
            lastSuccessfulFetch: now,
            now: now,
            mode: .wifi,
            isFallbackCatalog: true
        ))
        XCTAssertFalse(policy.shouldRefresh(
            lastSuccessfulFetch: now,
            now: now,
            mode: .offline,
            isFallbackCatalog: true
        ))
    }

    func testTwoHourRequestFloorIncludesManualAndFallbackRefreshes() {
        let now = Date(timeIntervalSince1970: 100_000)
        let policy = RefreshPolicy(staleAfter: 0, minimumRequestInterval: 2 * 3_600)
        let recentAttempt = now.addingTimeInterval(-(2 * 3_600 - 1))

        XCTAssertFalse(policy.shouldRefresh(
            lastSuccessfulFetch: nil,
            now: now,
            mode: .wifi,
            manual: true,
            isFallbackCatalog: true,
            lastRequestAttempt: recentAttempt
        ))
        XCTAssertTrue(policy.shouldRefresh(
            lastSuccessfulFetch: nil,
            now: now,
            mode: .wifi,
            manual: true,
            isFallbackCatalog: true,
            lastRequestAttempt: now.addingTimeInterval(-2 * 3_600)
        ))
    }

    func testRequestValidationReturnsNextAllowedTime() throws {
        let now = Date(timeIntervalSince1970: 100_000)
        let attemptedAt = now.addingTimeInterval(-60)
        let policy = RefreshPolicy(minimumRequestInterval: 2 * 3_600)
        XCTAssertThrowsError(try policy.validateRequest(
            mode: .wifi,
            lastRequestAttempt: attemptedAt,
            now: now
        )) { error in
            XCTAssertEqual(
                error as? OrbitalDataError,
                .requestThrottled(nextAllowedAt: attemptedAt.addingTimeInterval(2 * 3_600))
            )
        }
    }

    func testHTTPStatusErrorPreservesServerDetails() {
        let error = OrbitalDataError.httpStatus(statusCode: 429, retryAfter: "30")
        XCTAssertEqual(error.errorDescription, "CelesTrak returned HTTP 429 (retry after 30).")
    }
}

final class CatalogStoreTests: XCTestCase {
    func testAtomicReplacementAndIncompleteRejection() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = CatalogStore(directory: directory)
        let sample = try SampleDataLoader.catalog()
        try await store.replaceAtomically(with: sample)
        let firstLoad = try await store.load()
        XCTAssertEqual(firstLoad?.records.count, sample.records.count)

        let empty = CatalogSnapshot(records: [], fetchedAt: .now, manifestGeneratedAt: .now)
        do {
            try await store.replaceAtomically(with: empty, minimumRecordCount: 1)
            XCTFail("Expected incomplete catalog rejection")
        } catch let error as OrbitalDataError {
            XCTAssertEqual(error, .incomplete(expectedAtLeast: 1, actual: 0))
        }
        let secondLoad = try await store.load()
        XCTAssertEqual(secondLoad?.records.count, sample.records.count)
        try? FileManager.default.removeItem(at: directory)
    }
}

final class CandidateSelectorTests: XCTestCase {
    func testHigherElevationCandidateWins() throws {
        let sample = try SampleDataLoader.catalog()
        let now = Date(timeIntervalSince1970: 1_000)
        let low = observation(record: sample.records[0], elevation: 20, range: 1_500, now: now)
        let high = observation(record: sample.records[1], elevation: 70, range: 700, now: now)
        let result = ServingCandidateSelector().select(
            from: [low, high], catalogFetchedAt: now, networkMode: .wifi, previousSatelliteID: nil, now: now
        )
        XCTAssertEqual(result.satellite?.id, high.id)
    }

    func testHysteresisRetainsNearlyEqualPreviousCandidate() throws {
        let sample = try SampleDataLoader.catalog()
        let now = Date(timeIntervalSince1970: 1_000)
        let previous = observation(record: sample.records[0], elevation: 50, range: 900, now: now)
        let challenger = observation(record: sample.records[1], elevation: 51, range: 890, now: now)
        let result = ServingCandidateSelector(switchMargin: 0.1).select(
            from: [previous, challenger], catalogFetchedAt: now, networkMode: .wifi, previousSatelliteID: previous.id, now: now
        )
        XCTAssertEqual(result.satellite?.id, previous.id)
    }

    func testNoVisibleSatelliteHasInsufficientEvidence() throws {
        let result = ServingCandidateSelector().select(
            from: [], catalogFetchedAt: .now, networkMode: .offline, previousSatelliteID: nil, now: .now
        )
        XCTAssertEqual(result.confidence, .insufficientEvidence)
        XCTAssertNil(result.satellite)
    }

    private func observation(record: SatelliteRecord, elevation: Double, range: Double, now: Date) -> SatelliteObservation {
        SatelliteObservation(
            satellite: record,
            state: SatelliteState(
                eciKilometers: .init(x: 1, y: 2, z: 3),
                ecefKilometers: .init(x: 1, y: 2, z: 3),
                geodetic: .init(latitude: 0, longitude: 0, altitudeKilometers: 550)
            ),
            azimuthDegrees: 180,
            elevationDegrees: elevation,
            slantRangeKilometers: range,
            pass: .init(rise: now.addingTimeInterval(-100), culmination: now, set: now.addingTimeInterval(600), maximumElevationDegrees: elevation),
            observedAt: now
        )
    }
}

final class DirectToCellClassifierTests: XCTestCase {
    func testDTCNameTokenIsHighConfidenceClassification() {
        let record = DirectToCellClassifier.classify(
            elements: elements(id: 60728, name: "STARLINK-11249 [DTC]"),
            manifestEntry: nil
        )
        XCTAssertTrue(record.directToCell)
        XCTAssertEqual(record.classificationSource, .gpObjectNameDTC)
        XCTAssertEqual(record.classificationConfidence, 0.98, accuracy: 1e-12)
    }

    func testDTCNameMatchingIsCaseInsensitiveAndTokenBounded() {
        XCTAssertTrue(DirectToCellClassifier.hasDTCTag("STARLINK-12345 [dtc]"))
        XCTAssertTrue(DirectToCellClassifier.hasDTCTag("STARLINK-DTC-12345"))
        XCTAssertFalse(DirectToCellClassifier.hasDTCTag("STARLINK-NOTDTC-12345"))
        XCTAssertFalse(DirectToCellClassifier.hasDTCTag("STARLINK-12345"))
    }

    func testManifestCanOverrideDTCNameForReviewedException() {
        let entry = DirectToCellManifest.Entry(
            noradID: 60728,
            name: "STARLINK-11249 [DTC]",
            directToCell: false,
            status: .inactive,
            generation: "v2-mini",
            confidence: 1
        )
        let record = DirectToCellClassifier.classify(
            elements: elements(id: 60728, name: "STARLINK-11249 [DTC]"),
            manifestEntry: entry
        )
        XCTAssertFalse(record.directToCell)
        XCTAssertEqual(record.classificationSource, .manifest)
    }

    private func elements(id: Int, name: String) -> OrbitalElements {
        OrbitalElements(
            noradID: id,
            name: name,
            epoch: Date(timeIntervalSince1970: 1_000),
            eccentricity: 0.0001,
            inclinationDegrees: 53.2,
            rightAscensionDegrees: 10,
            argumentOfPerigeeDegrees: 90,
            meanAnomalyDegrees: 270,
            meanMotionRevolutionsPerDay: 15.7,
            source: .celesTrakJSON,
            fetchedAt: Date(timeIntervalSince1970: 1_000)
        )
    }
}
