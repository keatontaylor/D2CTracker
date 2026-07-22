import XCTest
@testable import D2CTrackerCore

final class D2CLinkGeometryTests: XCTestCase {
    func testOffNadirIsZeroAtSatelliteSubpoint() {
        let observer = ObserverLocation(latitude: 0, longitude: 0)
        let satellite = Vector3(x: 6_928.137, y: 0, z: 0)
        XCTAssertEqual(
            D2CLinkGeometry.offNadirDegrees(satelliteECEF: satellite, observer: observer),
            0,
            accuracy: 1e-9
        )
    }

    func testDopplerAtD2CFrequenciesUsesRangeRateSign() {
        let approachingRate = -7.0
        let uplink = D2CLinkGeometry.dopplerShiftHz(
            rangeRateKilometersPerSecond: approachingRate,
            frequencyHz: D2CLinkGeometry.uplinkFrequencyHz
        )
        let downlink = D2CLinkGeometry.dopplerShiftHz(
            rangeRateKilometersPerSecond: approachingRate,
            frequencyHz: D2CLinkGeometry.downlinkFrequencyHz
        )
        XCTAssertGreaterThan(uplink, 0)
        XCTAssertGreaterThan(downlink, uplink)
        XCTAssertEqual(
            downlink,
            -approachingRate / D2CLinkGeometry.speedOfLightKilometersPerSecond
                * D2CLinkGeometry.downlinkFrequencyHz,
            accuracy: 1e-9
        )
    }

    func testFreeSpacePathLoss() {
        let loss = D2CLinkGeometry.freeSpacePathLossDB(
            rangeKilometers: 1_000,
            frequencyHz: 2_000_000_000
        )
        XCTAssertEqual(loss, 158.46, accuracy: 0.03)
    }

    func testScanLossPenaltyIsNonlinear() {
        let atZero = D2CLinkGeometry.estimatedScanLossDB(offNadirDegrees: 0, exponent: 1.6)
        let atThirty = D2CLinkGeometry.estimatedScanLossDB(offNadirDegrees: 30, exponent: 1.6)
        let atSixty = D2CLinkGeometry.estimatedScanLossDB(offNadirDegrees: 60, exponent: 1.6)
        XCTAssertEqual(atZero, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(atThirty, 0)
        XCTAssertGreaterThan(atSixty, atThirty * 3)
    }

    func testNominalUplinkEnvelopeCrossesNearTwentyDegreesAt525Kilometers() {
        let edge = D2CUplinkBudget.minimumClearSkyElevationDegrees(satelliteAltitudeKilometers: 525)
        XCTAssertGreaterThan(edge, 17)
        XCTAssertLessThan(edge, 24)

        let below = D2CUplinkBudget.geometry(elevationDegrees: edge - 1, satelliteAltitudeKilometers: 525)
        let above = D2CUplinkBudget.geometry(elevationDegrees: edge + 1, satelliteAltitudeKilometers: 525)
        XCTAssertLessThan(
            D2CUplinkBudget.estimatedMarginDB(
                rangeKilometers: below.rangeKilometers,
                offNadirDegrees: below.offNadirDegrees
            ),
            0
        )
        XCTAssertGreaterThan(
            D2CUplinkBudget.estimatedMarginDB(
                rangeKilometers: above.rangeKilometers,
                offNadirDegrees: above.offNadirDegrees
            ),
            0
        )
    }

    func testDependableClearSkyRingIsInsidePossibleClearSkyRing() {
        let possibleEdge = D2CUplinkBudget.minimumClearSkyElevationDegrees(
            satelliteAltitudeKilometers: 525,
            targetMarginDB: 0
        )
        let dependableEdge = D2CUplinkBudget.minimumClearSkyElevationDegrees(
            satelliteAltitudeKilometers: 525,
            targetMarginDB: D2CUplinkBudget.dependableMarginDB
        )

        XCTAssertGreaterThan(dependableEdge, possibleEdge)
        XCTAssertLessThan(dependableEdge, 90)
    }

    func testUplinkMarginFallsWithLowerElevation() {
        let overhead = D2CUplinkBudget.geometry(elevationDegrees: 90, satelliteAltitudeKilometers: 525)
        let low = D2CUplinkBudget.geometry(elevationDegrees: 10, satelliteAltitudeKilometers: 525)
        let overheadMargin = D2CUplinkBudget.estimatedMarginDB(
            rangeKilometers: overhead.rangeKilometers,
            offNadirDegrees: overhead.offNadirDegrees
        )
        let lowMargin = D2CUplinkBudget.estimatedMarginDB(
            rangeKilometers: low.rangeKilometers,
            offNadirDegrees: low.offNadirDegrees
        )
        XCTAssertGreaterThan(overheadMargin, 10)
        XCTAssertLessThan(lowMargin, 0)
    }

    func testPhoneOrientationLossIsSmoothAndCapped() throws {
        let aligned = try XCTUnwrap(D2CUplinkBudget.phoneOrientationLossDB(
            satelliteAzimuthDegrees: 90,
            satelliteElevationDegrees: 30,
            phoneHeadingDegrees: 90,
            phonePointingElevationDegrees: 30
        ))
        let perpendicular = try XCTUnwrap(D2CUplinkBudget.phoneOrientationLossDB(
            satelliteAzimuthDegrees: 90,
            satelliteElevationDegrees: 0,
            phoneHeadingDegrees: 0,
            phonePointingElevationDegrees: 0
        ))
        let opposite = try XCTUnwrap(D2CUplinkBudget.phoneOrientationLossDB(
            satelliteAzimuthDegrees: 180,
            satelliteElevationDegrees: 0,
            phoneHeadingDegrees: 0,
            phonePointingElevationDegrees: 0
        ))
        XCTAssertEqual(aligned, 0, accuracy: 1e-9)
        XCTAssertEqual(perpendicular, 4, accuracy: 1e-9)
        XCTAssertEqual(opposite, 8, accuracy: 1e-9)
    }

    func testDependableEnvelopeIsInsidePossibleEnvelope() {
        let possible = D2CUplinkBudget.minimumQualityElevationDegrees(
            satelliteAltitudeKilometers: 360,
            satelliteAzimuthDegrees: 90,
            targetAdjustedMarginDB: 0,
            phoneHeadingDegrees: 90,
            phonePointingElevationDegrees: 20
        )
        let dependable = D2CUplinkBudget.minimumQualityElevationDegrees(
            satelliteAltitudeKilometers: 360,
            satelliteAzimuthDegrees: 90,
            targetAdjustedMarginDB: D2CUplinkBudget.dependableMarginDB,
            phoneHeadingDegrees: 90,
            phonePointingElevationDegrees: 20
        )
        XCTAssertGreaterThan(dependable, possible)
        XCTAssertGreaterThan(dependable, 20)
    }
}

final class D2CServingTrackerTests: XCTestCase {
    func testCombinedGeometryCanBeatHigherElevation() throws {
        let records = try SampleDataLoader.catalog().records
        let now = records[0].elements.epoch.addingTimeInterval(600)
        let highButPoor = observation(
            records[0], now: now, elevation: 70, range: 1_850, offNadir: 58,
            elevationRate: -0.04, dwell: 55
        )
        let lowerButUseful = observation(
            records[1], now: now, elevation: 38, range: 680, offNadir: 18,
            elevationRate: 0.04, dwell: 420
        )
        var tracker = ServingCandidateTracker()
        let result = tracker.update(
            from: [highButPoor, lowerButUseful], catalogFetchedAt: now,
            networkMode: .wifi, now: now
        )
        XCTAssertEqual(result.satellite?.id, lowerButUseful.id)
    }

    func testHandoffRequiresSustainedAdvantage() throws {
        var config = D2CServingModelConfiguration.v1
        config.handoffConfirmationDuration = 20
        config.urgentHandoffConfirmationDuration = 20
        config.handoffCooldownDuration = 0
        let records = try SampleDataLoader.catalog().records
        let start = records[0].elements.epoch.addingTimeInterval(600)
        var tracker = ServingCandidateTracker(configuration: config)

        let initial = tracker.update(
            from: [
                observation(records[0], now: start, elevation: 55, range: 700, offNadir: 18, elevationRate: -0.01, dwell: 360),
                observation(records[1], now: start, elevation: 30, range: 1_200, offNadir: 42, elevationRate: 0.03, dwell: 500)
            ],
            catalogFetchedAt: start, networkMode: .wifi, now: start
        )
        XCTAssertEqual(initial.satellite?.id, records[0].id)

        let firstChallenge = start.addingTimeInterval(5)
        let pending = tracker.update(
            from: challengerDominant(records, now: firstChallenge),
            catalogFetchedAt: start, networkMode: .wifi, now: firstChallenge
        )
        XCTAssertEqual(pending.satellite?.id, records[0].id)
        XCTAssertEqual(pending.handoff.phase, .evaluatingChallenger)

        let confirmedAt = start.addingTimeInterval(26)
        let switched = tracker.update(
            from: challengerDominant(records, now: confirmedAt),
            catalogFetchedAt: start, networkMode: .wifi, now: confirmedAt
        )
        XCTAssertEqual(switched.satellite?.id, records[1].id)
        XCTAssertEqual(switched.handoff.phase, .handedOff)
    }

    func testPingPongPreventionHoldsNewIncumbent() throws {
        var config = D2CServingModelConfiguration.v1
        config.handoffConfirmationDuration = 0
        config.urgentHandoffConfirmationDuration = 0
        config.handoffCooldownDuration = 60
        let records = try SampleDataLoader.catalog().records
        let start = records[0].elements.epoch.addingTimeInterval(600)
        var tracker = ServingCandidateTracker(configuration: config)

        _ = tracker.update(
            from: [
                observation(records[0], now: start, elevation: 55, range: 700, offNadir: 18, elevationRate: 0.01, dwell: 400),
                observation(records[1], now: start, elevation: 25, range: 1_400, offNadir: 48, elevationRate: 0.01, dwell: 400)
            ], catalogFetchedAt: start, networkMode: .wifi, now: start
        )
        let switchTime = start.addingTimeInterval(5)
        let switched = tracker.update(
            from: challengerDominant(records, now: switchTime),
            catalogFetchedAt: start, networkMode: .wifi, now: switchTime
        )
        XCTAssertEqual(switched.satellite?.id, records[1].id)

        let reversalTime = start.addingTimeInterval(10)
        let reversal = tracker.update(
            from: [
                observation(records[0], now: reversalTime, elevation: 52, range: 710, offNadir: 19, elevationRate: 0.01, dwell: 380),
                observation(records[1], now: reversalTime, elevation: 49, range: 760, offNadir: 21, elevationRate: -0.01, dwell: 370)
            ], catalogFetchedAt: start, networkMode: .wifi, now: reversalTime
        )
        XCTAssertEqual(reversal.satellite?.id, records[1].id)
        XCTAssertNotEqual(reversal.handoff.phase, .handedOff)
    }

    func testLongerDwellBreaksOtherwiseSimilarGeometry() throws {
        let records = try SampleDataLoader.catalog().records
        let now = records[0].elements.epoch.addingTimeInterval(600)
        var tracker = ServingCandidateTracker()
        let short = observation(records[0], now: now, elevation: 45, range: 800, offNadir: 25, elevationRate: 0, dwell: 45)
        let long = observation(records[1], now: now, elevation: 45, range: 800, offNadir: 25, elevationRate: 0, dwell: 480)
        let result = tracker.update(from: [short, long], catalogFetchedAt: now, networkMode: .wifi, now: now)
        XCTAssertEqual(result.satellite?.id, long.id)
    }

    func testTerrainClearancePenaltyPrefersOpenSkyCandidate() throws {
        let records = try SampleDataLoader.catalog().records
        let now = records[0].elements.epoch.addingTimeInterval(600)
        let ridgeSkimming = observation(
            records[0], now: now, elevation: 45, range: 800,
            offNadir: 25, elevationRate: 0.01, dwell: 300
        )
        let openSky = observation(
            records[1], now: now, elevation: 45, range: 800,
            offNadir: 25, elevationRate: 0.01, dwell: 300
        )
        var tracker = ServingCandidateTracker()
        let result = tracker.update(
            from: [ridgeSkimming, openSky],
            catalogFetchedAt: now,
            networkMode: .wifi,
            candidateClearanceQuality: [ridgeSkimming.id: 0, openSky.id: 1],
            now: now
        )
        XCTAssertEqual(result.satellite?.id, openSky.id)
        XCTAssertEqual(result.selectedDiagnostics?.terrainClearanceQuality, 1)
    }

    func testOrientationAdjustedUplinkMarginChangesServingCandidate() throws {
        let records = try SampleDataLoader.catalog().records
        let now = records[0].elements.epoch.addingTimeInterval(600)
        let first = observation(records[0], now: now, elevation: 45, range: 800, offNadir: 25, elevationRate: 0.01, dwell: 300)
        let second = observation(records[1], now: now, elevation: 45, range: 800, offNadir: 25, elevationRate: 0.01, dwell: 300)
        var tracker = ServingCandidateTracker()
        let result = tracker.update(
            from: [first, second],
            catalogFetchedAt: now,
            networkMode: .wifi,
            candidateAdjustedUplinkMarginDB: [first.id: -2, second.id: 8],
            now: now
        )
        XCTAssertEqual(result.satellite?.id, second.id)
        XCTAssertEqual(result.selectedDiagnostics?.estimatedUplinkMarginDB, 8)
    }

    func testNearlyEqualCandidatesReduceConfidence() throws {
        let records = try SampleDataLoader.catalog().records
        let now = records[0].elements.epoch.addingTimeInterval(600)
        var tracker = ServingCandidateTracker()
        let first = observation(records[0], now: now, elevation: 45, range: 800, offNadir: 25, elevationRate: 0.01, dwell: 300)
        let second = observation(records[1], now: now, elevation: 45.1, range: 799, offNadir: 24.9, elevationRate: 0.01, dwell: 301)
        let result = tracker.update(from: [first, second], catalogFetchedAt: now, networkMode: .wifi, now: now)
        XCTAssertEqual(result.confidence, .low)
    }

    func testStaleOrbitalEpochReducesConfidence() throws {
        let record = try SampleDataLoader.catalog().records[0]
        let now = record.elements.epoch.addingTimeInterval(80 * 3_600)
        var tracker = ServingCandidateTracker()
        let candidate = observation(record, now: now, elevation: 60, range: 650, offNadir: 15, elevationRate: 0.01, dwell: 400)
        let result = tracker.update(from: [candidate], catalogFetchedAt: now, networkMode: .wifi, now: now)
        XCTAssertEqual(result.confidence, .low)
    }

    func testSimulatedPassMakesOneStableHandoff() throws {
        var config = D2CServingModelConfiguration.v1
        config.handoffConfirmationDuration = 10
        config.urgentHandoffConfirmationDuration = 5
        config.handoffCooldownDuration = 60
        let records = try SampleDataLoader.catalog().records
        let start = records[0].elements.epoch.addingTimeInterval(600)
        var tracker = ServingCandidateTracker(configuration: config)
        var selectedIDs: [Int] = []
        var handoffCount = 0

        for step in 0...8 {
            let now = start.addingTimeInterval(Double(step * 5))
            let incumbentQuality = Double(8 - step) / 8
            let challengerQuality = Double(step) / 8
            let setting = observation(
                records[0], now: now,
                elevation: 58 - Double(step * 5),
                range: 650 + (1 - incumbentQuality) * 900,
                offNadir: 16 + (1 - incumbentQuality) * 42,
                elevationRate: -0.04,
                dwell: max(20, 180 - Double(step * 20))
            )
            let rising = observation(
                records[1], now: now,
                elevation: 18 + Double(step * 5),
                range: 1_500 - challengerQuality * 850,
                offNadir: 56 - challengerQuality * 40,
                elevationRate: 0.04,
                dwell: 420
            )
            let result = tracker.update(
                from: [setting, rising], catalogFetchedAt: start,
                networkMode: .wifi, now: now
            )
            selectedIDs.append(result.satellite?.id ?? -1)
            if result.handoff.phase == .handedOff { handoffCount += 1 }
        }

        XCTAssertEqual(selectedIDs.first, records[0].id)
        XCTAssertEqual(selectedIDs.last, records[1].id)
        XCTAssertEqual(handoffCount, 1)
        let transitions = zip(selectedIDs, selectedIDs.dropFirst()).filter { $0.0 != $0.1 }.count
        XCTAssertEqual(transitions, 1)
    }

    private func challengerDominant(_ records: [SatelliteRecord], now: Date) -> [SatelliteObservation] {
        [
            observation(records[0], now: now, elevation: 30, range: 1_250, offNadir: 48, elevationRate: -0.04, dwell: 160),
            observation(records[1], now: now, elevation: 58, range: 650, offNadir: 15, elevationRate: 0.04, dwell: 430)
        ]
    }

    private func observation(
        _ record: SatelliteRecord,
        now: Date,
        elevation: Double,
        range: Double,
        offNadir: Double,
        elevationRate: Double,
        dwell: TimeInterval,
        locationAccuracy: Double? = 0.02
    ) -> SatelliteObservation {
        let rangeRate = elevationRate >= 0 ? -4.5 : 4.5
        return SatelliteObservation(
            satellite: record,
            state: SatelliteState(
                eciKilometers: .init(x: 6_900, y: 0, z: 0),
                ecefKilometers: .init(x: 6_900, y: 0, z: 0),
                geodetic: .init(latitude: 0, longitude: 0, altitudeKilometers: 550)
            ),
            azimuthDegrees: 180,
            elevationDegrees: elevation,
            slantRangeKilometers: range,
            rangeRateKilometersPerSecond: rangeRate,
            elevationRateDegreesPerSecond: elevationRate,
            offNadirDegrees: offNadir,
            predictedUplinkDopplerHz: D2CLinkGeometry.dopplerShiftHz(
                rangeRateKilometersPerSecond: rangeRate,
                frequencyHz: D2CLinkGeometry.uplinkFrequencyHz
            ),
            predictedDownlinkDopplerHz: D2CLinkGeometry.dopplerShiftHz(
                rangeRateKilometersPerSecond: rangeRate,
                frequencyHz: D2CLinkGeometry.downlinkFrequencyHz
            ),
            predictedDownlinkDopplerRateHzPerSecond: 12,
            freeSpacePathLossDB: D2CLinkGeometry.freeSpacePathLossDB(
                rangeKilometers: range,
                frequencyHz: D2CLinkGeometry.downlinkFrequencyHz
            ),
            observerHorizontalAccuracyKilometers: locationAccuracy,
            pass: SatellitePass(
                rise: now.addingTimeInterval(-300),
                culmination: now.addingTimeInterval(elevationRate >= 0 ? 60 : -60),
                set: now.addingTimeInterval(dwell),
                maximumElevationDegrees: max(elevation, 70)
            ),
            observedAt: now
        )
    }
}

final class LinkQualityScorerTests: XCTestCase {
    func testSatelliteSignalEstimateUsesOnlyRFGeometryComponents() throws {
        let components = [
            ServingScoreComponent(name: "Elevation", normalizedValue: 1.0, weight: 1),
            ServingScoreComponent(name: "Range / path loss", normalizedValue: 0.5, weight: 1),
            ServingScoreComponent(name: "Off-nadir steering", normalizedValue: 0.0, weight: 1),
            ServingScoreComponent(name: "Estimated scan loss", normalizedValue: 0.5, weight: 1),
            ServingScoreComponent(name: "Continuity", normalizedValue: 1.0, weight: 100)
        ]

        let score = try XCTUnwrap(SatelliteSignalQualityEstimator.score(from: components))
        XCTAssertEqual(score, 50, accuracy: 1e-12)
    }

    func testSatelliteSignalEstimateIsCappedByOrientationAdjustedUplink() throws {
        let record = try SampleDataLoader.catalog().records[0]
        let diagnostics = ServingCandidateDiagnostics(
            satellite: record,
            suitability: 1,
            elevationDegrees: 45,
            slantRangeKilometers: 800,
            rangeRateKilometersPerSecond: 0,
            offNadirDegrees: 25,
            predictedUplinkDopplerHz: 0,
            predictedDownlinkDopplerHz: 0,
            predictedDownlinkDopplerRateHzPerSecond: 0,
            freeSpacePathLossDB: 156,
            estimatedScanLossDB: 1,
            remainingDwellSeconds: 300,
            motionState: .nearCulmination,
            tleAgeSeconds: 0,
            scoreComponents: [
                ServingScoreComponent(name: "Elevation", normalizedValue: 1, weight: 1),
                ServingScoreComponent(name: "Range / path loss", normalizedValue: 1, weight: 1),
                ServingScoreComponent(name: "Off-nadir steering", normalizedValue: 1, weight: 1),
                ServingScoreComponent(name: "Estimated scan loss", normalizedValue: 1, weight: 1)
            ]
        )
        let score = try XCTUnwrap(SatelliteSignalQualityEstimator.score(
            from: diagnostics,
            adjustedUplinkMarginDB: -3
        ))
        XCTAssertEqual(score, 0, accuracy: 1e-12)
    }

    func testLinkSampleWithoutSatelliteFieldsStillRoundTrips() throws {
        let sample = linkSample(at: Date(timeIntervalSince1970: 1_000), success: true, latency: 500, bytes: 400)
        let decoded = try JSONDecoder().decode(
            LinkQualitySample.self,
            from: JSONEncoder().encode(sample)
        )
        XCTAssertNil(decoded.estimatedSatelliteSignalScore)
        XCTAssertNil(decoded.satelliteName)
    }

    func testLowLatencyGoodLinkScoresAboveHighLatencyMinimalLink() {
        let good = LinkQualityScorer.sampleScore(
            succeeded: true,
            timeToFirstByteMilliseconds: 250,
            totalDurationMilliseconds: 400,
            systemQuality: .good
        )
        let poor = LinkQualityScorer.sampleScore(
            succeeded: true,
            timeToFirstByteMilliseconds: 8_000,
            totalDurationMilliseconds: 10_000,
            systemQuality: .minimal
        )
        XCTAssertGreaterThan(good, poor)
        XCTAssertGreaterThan(good, 85)
    }

    func testFailedProbeScoresZero() {
        XCTAssertEqual(
            LinkQualityScorer.sampleScore(
                succeeded: false,
                timeToFirstByteMilliseconds: nil,
                totalDurationMilliseconds: 20_000,
                systemQuality: .good
            ),
            0
        )
    }

    func testSummaryIncludesReliabilityJitterAndTraffic() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let samples = [
            linkSample(at: start, success: true, latency: 1_000, bytes: 500),
            linkSample(at: start.addingTimeInterval(60), success: true, latency: 1_400, bytes: 600),
            linkSample(at: start.addingTimeInterval(120), success: false, latency: nil, bytes: 100)
        ]
        let summary = try XCTUnwrap(LinkQualityScorer.summarize(samples))
        XCTAssertEqual(summary.successRate, 2.0 / 3.0, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.medianTimeToFirstByteMilliseconds), 1_200, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(summary.jitterMilliseconds), 400, accuracy: 1e-12)
        XCTAssertEqual(summary.cumulativeProbeBytes, 1_200)
    }

    func testSummaryHeadlineReflectsLatestAvailabilitySnapshot() throws {
        let start = Date(timeIntervalSince1970: 2_000)
        let available = linkSample(at: start, success: true, latency: 300, bytes: 400)
        let missed = linkSample(at: start.addingTimeInterval(30), success: false, latency: nil, bytes: 0)

        let unavailableSummary = try XCTUnwrap(LinkQualityScorer.summarize([available, missed]))
        XCTAssertEqual(unavailableSummary.score, 0)
        XCTAssertEqual(unavailableSummary.grade.rawValue, InternetLinkGrade.unavailable.rawValue)

        let restoredSummary = try XCTUnwrap(LinkQualityScorer.summarize([missed, available]))
        XCTAssertEqual(restoredSummary.score, available.qualityScore, accuracy: 1e-12)
        XCTAssertNotEqual(restoredSummary.grade.rawValue, InternetLinkGrade.unavailable.rawValue)
    }

    private func linkSample(
        at date: Date,
        success: Bool,
        latency: Double?,
        bytes: Int64
    ) -> LinkQualitySample {
        let total = latency.map { $0 + 100 } ?? 20_000
        return LinkQualitySample(
            measuredAt: date,
            pathMode: .ultraConstrained,
            systemLinkQuality: .moderate,
            diagnosticOverride: false,
            succeeded: success,
            statusCode: success ? 200 : nil,
            timeToFirstByteMilliseconds: latency,
            totalDurationMilliseconds: total,
            dnsMilliseconds: 20,
            connectMilliseconds: 100,
            tlsMilliseconds: 80,
            protocolName: "h2",
            reusedConnection: false,
            requestBytes: bytes / 2,
            responseBytes: bytes - bytes / 2,
            qualityScore: LinkQualityScorer.sampleScore(
                succeeded: success,
                timeToFirstByteMilliseconds: latency,
                totalDurationMilliseconds: total,
                systemQuality: .moderate
            ),
            errorDescription: success ? nil : "Timed out"
        )
    }
}
