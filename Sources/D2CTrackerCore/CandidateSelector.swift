import Foundation

public struct D2CServingModelConfiguration: Codable, Sendable {
    public var version: String
    public var scanLossExponent: Double
    public var maximumUsefulOffNadirDegrees: Double
    public var preferredRangeKilometers: Double
    public var rangeDecayKilometers: Double
    public var preferredDwellSeconds: TimeInterval
    public var minimumReplacementDwellSeconds: TimeInterval
    public var handoffMargin: Double
    public var urgentHandoffMargin: Double
    public var handoffConfirmationDuration: TimeInterval
    public var urgentHandoffConfirmationDuration: TimeInterval
    public var handoffCooldownDuration: TimeInterval
    public var poorElevationDegrees: Double
    public var poorOffNadirDegrees: Double
    public var poorRemainingDwellSeconds: TimeInterval
    public var handoffLeadTimeSeconds: TimeInterval
    public var probabilityTemperature: Double
    public var trackerPersistenceProbabilityBoost: Double
    public var staleTLEAgeSeconds: TimeInterval
    public var veryStaleTLEAgeSeconds: TimeInterval
    public var poorLocationAccuracyKilometers: Double

    public var elevationWeight: Double
    public var rangeWeight: Double
    public var steeringWeight: Double
    public var scanLossWeight: Double
    public var uplinkMarginWeight: Double
    public var dwellWeight: Double
    public var motionWeight: Double
    public var operationalWeight: Double
    public var tleFreshnessWeight: Double
    public var locationAccuracyWeight: Double
    public var classificationWeight: Double
    public var continuityWeight: Double

    public init(
        version: String = "spacex-d2c-v2-uplink",
        scanLossExponent: Double = 1.6,
        maximumUsefulOffNadirDegrees: Double = 62,
        preferredRangeKilometers: Double = 525,
        rangeDecayKilometers: Double = 1_050,
        preferredDwellSeconds: TimeInterval = 360,
        minimumReplacementDwellSeconds: TimeInterval = 90,
        handoffMargin: Double = 0.055,
        urgentHandoffMargin: Double = 0.02,
        handoffConfirmationDuration: TimeInterval = 20,
        urgentHandoffConfirmationDuration: TimeInterval = 5,
        handoffCooldownDuration: TimeInterval = 30,
        poorElevationDegrees: Double = 14,
        poorOffNadirDegrees: Double = 57,
        poorRemainingDwellSeconds: TimeInterval = 45,
        handoffLeadTimeSeconds: TimeInterval = 30,
        probabilityTemperature: Double = 0.11,
        trackerPersistenceProbabilityBoost: Double = 0.035,
        staleTLEAgeSeconds: TimeInterval = 36 * 3_600,
        veryStaleTLEAgeSeconds: TimeInterval = 72 * 3_600,
        poorLocationAccuracyKilometers: Double = 5,
        elevationWeight: Double = 0.03,
        rangeWeight: Double = 0.06,
        steeringWeight: Double = 0.07,
        scanLossWeight: Double = 0.04,
        uplinkMarginWeight: Double = 0.35,
        dwellWeight: Double = 0.15,
        motionWeight: Double = 0.07,
        operationalWeight: Double = 0.05,
        tleFreshnessWeight: Double = 0.07,
        locationAccuracyWeight: Double = 0.03,
        classificationWeight: Double = 0.03,
        continuityWeight: Double = 0.05
    ) {
        self.version = version
        self.scanLossExponent = scanLossExponent
        self.maximumUsefulOffNadirDegrees = maximumUsefulOffNadirDegrees
        self.preferredRangeKilometers = preferredRangeKilometers
        self.rangeDecayKilometers = rangeDecayKilometers
        self.preferredDwellSeconds = preferredDwellSeconds
        self.minimumReplacementDwellSeconds = minimumReplacementDwellSeconds
        self.handoffMargin = handoffMargin
        self.urgentHandoffMargin = urgentHandoffMargin
        self.handoffConfirmationDuration = handoffConfirmationDuration
        self.urgentHandoffConfirmationDuration = urgentHandoffConfirmationDuration
        self.handoffCooldownDuration = handoffCooldownDuration
        self.poorElevationDegrees = poorElevationDegrees
        self.poorOffNadirDegrees = poorOffNadirDegrees
        self.poorRemainingDwellSeconds = poorRemainingDwellSeconds
        self.handoffLeadTimeSeconds = handoffLeadTimeSeconds
        self.probabilityTemperature = probabilityTemperature
        self.trackerPersistenceProbabilityBoost = trackerPersistenceProbabilityBoost
        self.staleTLEAgeSeconds = staleTLEAgeSeconds
        self.veryStaleTLEAgeSeconds = veryStaleTLEAgeSeconds
        self.poorLocationAccuracyKilometers = poorLocationAccuracyKilometers
        self.elevationWeight = elevationWeight
        self.rangeWeight = rangeWeight
        self.steeringWeight = steeringWeight
        self.scanLossWeight = scanLossWeight
        self.uplinkMarginWeight = uplinkMarginWeight
        self.dwellWeight = dwellWeight
        self.motionWeight = motionWeight
        self.operationalWeight = operationalWeight
        self.tleFreshnessWeight = tleFreshnessWeight
        self.locationAccuracyWeight = locationAccuracyWeight
        self.classificationWeight = classificationWeight
        self.continuityWeight = continuityWeight
    }

    public static let v1 = D2CServingModelConfiguration()
}

public struct ServingCandidateTracker: Sendable {
    public var configuration: D2CServingModelConfiguration
    public var elevationMask: Double

    private var incumbentSatelliteID: Int?
    private var challengerSatelliteID: Int?
    private var challengerBecameSuperiorAt: Date?
    private var lastHandoffAt: Date?

    public init(
        configuration: D2CServingModelConfiguration = .v1,
        elevationMask: Double = 10,
        initialIncumbentID: Int? = nil
    ) {
        self.configuration = configuration
        self.elevationMask = elevationMask
        incumbentSatelliteID = initialIncumbentID
    }

    public mutating func reset() {
        incumbentSatelliteID = nil
        challengerSatelliteID = nil
        challengerBecameSuperiorAt = nil
        lastHandoffAt = nil
    }

    public mutating func update(
        from observations: [SatelliteObservation],
        catalogFetchedAt: Date,
        networkMode: ConnectivityMode,
        candidateClearanceQuality: [Int: Double] = [:],
        candidateAdjustedUplinkMarginDB: [Int: Double] = [:],
        now: Date
    ) -> ServingSatelliteEstimate {
        let candidates = observations.filter {
            $0.satellite.directToCell && $0.elevationDegrees >= elevationMask
        }
        guard !candidates.isEmpty else {
            let prior = incumbentSatelliteID
            reset()
            return ServingSatelliteEstimate(
                satellite: nil,
                confidence: .insufficientEvidence,
                score: 0,
                reasons: [
                    "No classified Direct-to-Cell satellite is above the \(Int(elevationMask))° elevation mask."
                ],
                handoff: HandoffStatus(
                    phase: .insufficientEvidence,
                    incumbentSatelliteID: prior,
                    challengerSatelliteID: nil,
                    reason: "The previous candidate is no longer geometrically plausible."
                ),
                modelVersion: configuration.version,
                estimatedAt: now
            )
        }

        var diagnostics = candidates.map {
            makeDiagnostics(
                for: $0,
                terrainClearanceQuality: candidateClearanceQuality[$0.id],
                adjustedUplinkMarginDB: candidateAdjustedUplinkMarginDB[$0.id],
                now: now
            )
        }
            .sorted { $0.suitability > $1.suitability }
        let leader = diagnostics[0]
        let decision = decideSelection(leader: leader, candidates: diagnostics, now: now)
        let selectedID = decision.selectedID

        diagnostics = normalizedProbabilities(for: diagnostics, selectedID: selectedID)
        let selected = diagnostics.first { $0.id == selectedID } ?? diagnostics[0]
        let alternatives = diagnostics
            .filter { $0.id != selected.id }
            .sorted { $0.probability > $1.probability }
            .prefix(3)
        let catalogFreshness = CatalogFreshness.classify(
            age: max(0, now.timeIntervalSince(catalogFetchedAt))
        )
        let confidence = confidence(
            selected: selected,
            alternatives: Array(alternatives),
            catalogFreshness: catalogFreshness
        )
        let reasons = explanations(
            selected: selected,
            alternatives: Array(alternatives),
            decision: decision,
            networkMode: networkMode
        )
        let handoffAt = estimatedHandoffAt(selected: selected, decision: decision, now: now)

        return ServingSatelliteEstimate(
            satellite: selected.satellite,
            confidence: confidence,
            score: selected.probability,
            reasons: reasons,
            selectedDiagnostics: selected,
            alternatives: Array(alternatives),
            handoff: HandoffStatus(
                phase: decision.phase,
                incumbentSatelliteID: selected.id,
                challengerSatelliteID: decision.challengerID,
                reason: decision.reason
            ),
            estimatedHandoffAt: handoffAt,
            modelVersion: configuration.version,
            estimatedAt: now
        )
    }

    private mutating func decideSelection(
        leader: ServingCandidateDiagnostics,
        candidates: [ServingCandidateDiagnostics],
        now: Date
    ) -> Decision {
        guard let incumbentSatelliteID else {
            self.incumbentSatelliteID = leader.id
            return Decision(
                selectedID: leader.id,
                challengerID: nil,
                phase: .stable,
                reason: "Established the initial inferred serving candidate."
            )
        }
        guard let incumbent = candidates.first(where: { $0.id == incumbentSatelliteID }) else {
            self.incumbentSatelliteID = leader.id
            challengerSatelliteID = nil
            challengerBecameSuperiorAt = nil
            lastHandoffAt = now
            return Decision(
                selectedID: leader.id,
                challengerID: nil,
                phase: .incumbentLost,
                reason: "Switched promptly because the incumbent fell below the usable geometry mask."
            )
        }
        guard leader.id != incumbent.id else {
            challengerSatelliteID = nil
            challengerBecameSuperiorAt = nil
            return Decision(
                selectedID: incumbent.id,
                challengerID: nil,
                phase: .stable,
                reason: "The incumbent remains the strongest combined-geometry candidate."
            )
        }

        let incumbentIsPoor = isPoorGeometry(incumbent)
        let margin = incumbentIsPoor ? configuration.urgentHandoffMargin : configuration.handoffMargin
        let confirmation = incumbentIsPoor
            ? configuration.urgentHandoffConfirmationDuration
            : configuration.handoffConfirmationDuration
        let advantage = leader.suitability - incumbent.suitability
        let inCooldown = lastHandoffAt.map {
            now.timeIntervalSince($0) < configuration.handoffCooldownDuration
        } ?? false

        guard leader.remainingDwellSeconds >= configuration.minimumReplacementDwellSeconds || incumbentIsPoor else {
            challengerSatelliteID = leader.id
            challengerBecameSuperiorAt = nil
            return Decision(
                selectedID: incumbent.id,
                challengerID: leader.id,
                phase: .deferred,
                reason: "Deferred handoff because the challenger does not have enough estimated dwell time."
            )
        }
        guard advantage >= margin else {
            challengerSatelliteID = leader.id
            challengerBecameSuperiorAt = nil
            return Decision(
                selectedID: incumbent.id,
                challengerID: leader.id,
                phase: .deferred,
                reason: String(
                    format: "Deferred handoff because the challenger advantage (%.3f) is below the %.3f margin.",
                    advantage,
                    margin
                )
            )
        }
        if inCooldown && !incumbentIsPoor && advantage < margin * 2 {
            return Decision(
                selectedID: incumbent.id,
                challengerID: leader.id,
                phase: .deferred,
                reason: "Deferred a reverse handoff during the anti-ping-pong cooldown."
            )
        }

        if challengerSatelliteID != leader.id || challengerBecameSuperiorAt == nil {
            challengerSatelliteID = leader.id
            challengerBecameSuperiorAt = now
        }
        let superiorFor = now.timeIntervalSince(challengerBecameSuperiorAt ?? now)
        guard superiorFor >= confirmation else {
            return Decision(
                selectedID: incumbent.id,
                challengerID: leader.id,
                phase: .evaluatingChallenger,
                reason: String(
                    format: "Challenger has remained materially better for %.0f of %.0f required seconds.",
                    superiorFor,
                    confirmation
                )
            )
        }

        self.incumbentSatelliteID = leader.id
        challengerSatelliteID = nil
        challengerBecameSuperiorAt = nil
        lastHandoffAt = now
        return Decision(
            selectedID: leader.id,
            challengerID: incumbent.id,
            phase: .handedOff,
            reason: incumbentIsPoor
                ? "Handed off after the incumbent approached poor steering or end-of-dwell geometry."
                : "Handed off after the replacement remained materially better for the confirmation interval."
        )
    }

    private func makeDiagnostics(
        for observation: SatelliteObservation,
        terrainClearanceQuality: Double?,
        adjustedUplinkMarginDB: Double?,
        now: Date
    ) -> ServingCandidateDiagnostics {
        let remaining = max(0, observation.pass?.set.timeIntervalSince(now) ?? 60)
        let motion: SatelliteMotionState
        if observation.elevationRateDegreesPerSecond > 0.003 { motion = .rising }
        else if observation.elevationRateDegreesPerSecond < -0.003 { motion = .setting }
        else { motion = .nearCulmination }

        let tleAge = max(0, now.timeIntervalSince(observation.satellite.elements.epoch))
        let scanLoss = D2CLinkGeometry.estimatedScanLossDB(
            offNadirDegrees: observation.offNadirDegrees,
            exponent: configuration.scanLossExponent
        )
        let elevation = normalizedElevation(observation.elevationDegrees)
        let range = exp(
            -max(0, observation.slantRangeKilometers - configuration.preferredRangeKilometers)
                / max(1, configuration.rangeDecayKilometers)
        )
        let steering = 1 - pow(
            clamped(observation.offNadirDegrees / configuration.maximumUsefulOffNadirDegrees),
            2
        )
        let scan = exp(-scanLoss / 5)
        let uplinkMargin = adjustedUplinkMarginDB.map {
            D2CUplinkBudget.qualityScore(forAdjustedMarginDB: $0) / 100
        } ?? (elevation + range + steering + scan) / 4
        let dwell = 1 - exp(-remaining / max(1, configuration.preferredDwellSeconds))
        let motionValue: Double = switch motion {
        case .rising: 1
        case .nearCulmination: 0.72
        case .setting: 0.42
        }
        let operational: Double = switch observation.satellite.operationalStatus {
        case .operational: 1
        case .testing: 0.65
        case .unknown: 0.4
        case .inactive: 0
        }
        let tleFreshness = exp(-tleAge / max(1, configuration.staleTLEAgeSeconds))
        let locationAccuracy: Double
        if let accuracy = observation.observerHorizontalAccuracyKilometers {
            locationAccuracy = exp(-accuracy / max(0.001, configuration.poorLocationAccuracyKilometers))
        } else {
            locationAccuracy = 0.8
        }
        let classification = clamped(observation.satellite.classificationConfidence)
        let continuity = observation.id == incumbentSatelliteID ? 1.0 : 0.0

        let components = [
            ServingScoreComponent(name: "Elevation", normalizedValue: elevation, weight: configuration.elevationWeight),
            ServingScoreComponent(name: "Range / path loss", normalizedValue: range, weight: configuration.rangeWeight),
            ServingScoreComponent(name: "Off-nadir steering", normalizedValue: steering, weight: configuration.steeringWeight),
            ServingScoreComponent(name: "Estimated scan loss", normalizedValue: scan, weight: configuration.scanLossWeight),
            ServingScoreComponent(name: "Orientation-adjusted uplink", normalizedValue: uplinkMargin, weight: configuration.uplinkMarginWeight),
            ServingScoreComponent(name: "Remaining dwell", normalizedValue: dwell, weight: configuration.dwellWeight),
            ServingScoreComponent(name: "Rising / setting", normalizedValue: motionValue, weight: configuration.motionWeight),
            ServingScoreComponent(name: "Operational status", normalizedValue: operational, weight: configuration.operationalWeight),
            ServingScoreComponent(name: "TLE freshness", normalizedValue: tleFreshness, weight: configuration.tleFreshnessWeight),
            ServingScoreComponent(name: "Location accuracy", normalizedValue: locationAccuracy, weight: configuration.locationAccuracyWeight),
            ServingScoreComponent(name: "DTC classification", normalizedValue: classification, weight: configuration.classificationWeight),
            ServingScoreComponent(name: "Continuity", normalizedValue: continuity, weight: configuration.continuityWeight)
        ]
        let baseSuitability = components.reduce(0) { $0 + $1.contribution }
        let clearanceQuality = terrainClearanceQuality.map(clamped)
        let clearanceMultiplier = clearanceQuality.map { 0.65 + 0.35 * $0 } ?? 1
        return ServingCandidateDiagnostics(
            satellite: observation.satellite,
            suitability: baseSuitability * clearanceMultiplier,
            elevationDegrees: observation.elevationDegrees,
            slantRangeKilometers: observation.slantRangeKilometers,
            rangeRateKilometersPerSecond: observation.rangeRateKilometersPerSecond,
            offNadirDegrees: observation.offNadirDegrees,
            predictedUplinkDopplerHz: observation.predictedUplinkDopplerHz,
            predictedDownlinkDopplerHz: observation.predictedDownlinkDopplerHz,
            predictedDownlinkDopplerRateHzPerSecond: observation.predictedDownlinkDopplerRateHzPerSecond,
            freeSpacePathLossDB: observation.freeSpacePathLossDB,
            estimatedScanLossDB: scanLoss,
            estimatedUplinkMarginDB: adjustedUplinkMarginDB,
            remainingDwellSeconds: remaining,
            motionState: motion,
            tleAgeSeconds: tleAge,
            terrainClearanceQuality: clearanceQuality,
            scoreComponents: components
        )
    }

    private func normalizedProbabilities(
        for candidates: [ServingCandidateDiagnostics],
        selectedID: Int
    ) -> [ServingCandidateDiagnostics] {
        let adjusted = candidates.map {
            $0.suitability + ($0.id == selectedID ? configuration.trackerPersistenceProbabilityBoost : 0)
        }
        let maximum = adjusted.max() ?? 0
        let temperature = max(0.01, configuration.probabilityTemperature)
        let exponentials = adjusted.map { exp(($0 - maximum) / temperature) }
        let total = max(exponentials.reduce(0, +), 1e-12)
        return zip(candidates, exponentials).map { candidate, exponential in
            var value = candidate
            value.probability = exponential / total
            return value
        }
    }

    private func confidence(
        selected: ServingCandidateDiagnostics,
        alternatives: [ServingCandidateDiagnostics],
        catalogFreshness: CatalogFreshness
    ) -> EstimateConfidence {
        if selected.tleAgeSeconds >= configuration.veryStaleTLEAgeSeconds
            || catalogFreshness == .veryStale
            || selected.satellite.classificationConfidence < 0.5 {
            return .low
        }
        if let accuracy = selected.scoreComponents.first(where: { $0.name == "Location accuracy" })?.normalizedValue,
           accuracy < 0.35 {
            return .low
        }
        let alternativeProbability = alternatives.first?.probability ?? 0
        let gap = selected.probability - alternativeProbability
        if let alternative = alternatives.first,
           abs(selected.suitability - alternative.suitability) < 0.025 {
            return .low
        }
        if selected.probability >= 0.65, gap >= 0.18,
           selected.tleAgeSeconds < configuration.staleTLEAgeSeconds,
           catalogFreshness == .fresh || catalogFreshness == .aging {
            return .high
        }
        if selected.probability >= 0.45, gap >= 0.08 { return .medium }
        return .low
    }

    private func explanations(
        selected: ServingCandidateDiagnostics,
        alternatives: [ServingCandidateDiagnostics],
        decision: Decision,
        networkMode: ConnectivityMode
    ) -> [String] {
        var values = [
            String(
                format: "%@ is the leading inferred candidate with %.0f%% relative probability from combined range, beam-steering, dwell, and continuity geometry.",
                selected.satellite.elements.name,
                selected.probability * 100
            ),
            String(
                format: "It is %@ at %.0f° elevation, %.0f km slant range, %.1f° off nadir, with about %@ of useful dwell remaining.",
                selected.motionState.rawValue,
                selected.elevationDegrees,
                selected.slantRangeKilometers,
                selected.offNadirDegrees,
                formattedDuration(selected.remainingDwellSeconds)
            ),
            decision.reason
        ]
        if let alternative = alternatives.first {
            let comparison: String
            if alternative.elevationDegrees > selected.elevationDegrees {
                comparison = String(
                    format: "%@ is higher at %.0f° but its combined suitability is lower due to range, steering, dwell, motion, or continuity.",
                    alternative.satellite.elements.name,
                    alternative.elevationDegrees
                )
            } else {
                comparison = String(
                    format: "%@ is the top alternative at %.0f%% relative probability.",
                    alternative.satellite.elements.name,
                    alternative.probability * 100
                )
            }
            values.append(comparison)
        }
        if let terrainClearanceQuality = selected.terrainClearanceQuality,
           terrainClearanceQuality < 0.95 {
            values.append(String(
                format: "Its %.0f%% terrain-clearance quality reduces suitability while the path remains close to the RF horizon.",
                terrainClearanceQuality * 100
            ))
        }
        if let uplinkMargin = selected.estimatedUplinkMarginDB {
            if uplinkMargin < 0 {
                values.append(String(
                    format: "The estimated phone return link is below nominal closure at %+.1f dB after handset attitude loss.",
                    uplinkMargin
                ))
            } else if uplinkMargin < D2CUplinkBudget.dependableMarginDB {
                values.append(String(
                    format: "The estimated phone return link is possible but below the dependable-data reserve at %+.1f dB.",
                    uplinkMargin
                ))
            } else {
                values.append(String(
                    format: "The orientation-adjusted phone return link retains %+.1f dB estimated margin.",
                    uplinkMargin
                ))
            }
        }
        values.append("Payload capacity, active beam allocation, frequency reuse, and interference are not exposed by iOS, so this remains an estimate.")
        if networkMode == .ultraConstrained || networkMode == .constrained {
            values.append("The current path is carrier constrained, but iOS does not reveal modem-level serving-cell measurements.")
        }
        return values
    }

    private func estimatedHandoffAt(
        selected: ServingCandidateDiagnostics,
        decision: Decision,
        now: Date
    ) -> Date? {
        if decision.phase == .evaluatingChallenger, let challengerBecameSuperiorAt {
            let duration = isPoorGeometry(selected)
                ? configuration.urgentHandoffConfirmationDuration
                : configuration.handoffConfirmationDuration
            return challengerBecameSuperiorAt.addingTimeInterval(duration)
        }
        guard selected.remainingDwellSeconds.isFinite, selected.remainingDwellSeconds > 0 else { return nil }
        return now.addingTimeInterval(max(0, selected.remainingDwellSeconds - configuration.handoffLeadTimeSeconds))
    }

    private func isPoorGeometry(_ candidate: ServingCandidateDiagnostics) -> Bool {
        candidate.elevationDegrees <= max(elevationMask, configuration.poorElevationDegrees)
            || candidate.offNadirDegrees >= configuration.poorOffNadirDegrees
            || candidate.remainingDwellSeconds <= configuration.poorRemainingDwellSeconds
            || candidate.estimatedUplinkMarginDB.map { $0 < 0 } == true
    }

    private func normalizedElevation(_ degrees: Double) -> Double {
        let floor = sin(elevationMask * .pi / 180)
        let value = sin(max(elevationMask, degrees) * .pi / 180)
        return clamped((value - floor) / max(0.001, 1 - floor))
    }

    private func clamped(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }

    private func formattedDuration(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return String(format: "%.0f seconds", seconds) }
        return String(format: "%.1f minutes", seconds / 60)
    }

    private struct Decision: Sendable {
        let selectedID: Int
        let challengerID: Int?
        let phase: HandoffPhase
        let reason: String
    }
}

/// Compatibility facade for callers that need a one-shot estimate. The app uses
/// `ServingCandidateTracker` so handoff confirmation persists across updates.
public struct ServingCandidateSelector: Sendable {
    public var switchMargin: Double
    public var elevationMask: Double

    public init(switchMargin: Double = 0.08, elevationMask: Double = 10) {
        self.switchMargin = switchMargin
        self.elevationMask = elevationMask
    }

    public func select(
        from observations: [SatelliteObservation],
        catalogFetchedAt: Date,
        networkMode: ConnectivityMode,
        previousSatelliteID: Int?,
        now: Date
    ) -> ServingSatelliteEstimate {
        var configuration = D2CServingModelConfiguration.v1
        configuration.handoffMargin = switchMargin
        configuration.handoffConfirmationDuration = 0
        configuration.urgentHandoffConfirmationDuration = 0
        var tracker = ServingCandidateTracker(
            configuration: configuration,
            elevationMask: elevationMask,
            initialIncumbentID: previousSatelliteID
        )
        return tracker.update(
            from: observations,
            catalogFetchedAt: catalogFetchedAt,
            networkMode: networkMode,
            now: now
        )
    }
}
