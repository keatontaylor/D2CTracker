import Foundation
import SwiftUI
import D2CTrackerCore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var catalog: CatalogSnapshot?
    @Published private(set) var observations: [SatelliteObservation] = []
    @Published private(set) var estimate = ServingSatelliteEstimate(
        satellite: nil,
        confidence: .insufficientEvidence,
        score: 0,
        reasons: ["Waiting for orbital data."],
        estimatedAt: .now
    )
    @Published private(set) var groundTrack: [GroundTrackPoint] = []
    @Published private(set) var coastlines: [[ObserverLocation]] = []
    @Published private(set) var countryBoundaries: [[ObserverLocation]] = []
    @Published private(set) var stateBoundaries: [[ObserverLocation]] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshMessage: String?
    @Published private(set) var lastUpdatedAt: Date?
    @Published private(set) var lastCatalogRequestAttempt: Date?
    @Published private(set) var sceneActivationToken = 0
    @Published var selectedSatelliteID: Int?
    let elevationMask: Double = 0
    @Published var usesManualLocation: Bool {
        didSet { UserDefaults.standard.set(usesManualLocation, forKey: "usesManualLocation") }
    }
    @Published var manualLatitude: Double {
        didSet { UserDefaults.standard.set(manualLatitude, forKey: "manualLatitude") }
    }
    @Published var manualLongitude: Double {
        didSet { UserDefaults.standard.set(manualLongitude, forKey: "manualLongitude") }
    }

    let connectivity = ConnectivityMonitor()
    let location = LocationService()
    let liveActivity = SatelliteLiveActivityService()
    let linkQuality = LinkQualityService()
    let terrain = TerrainService()

    private let store = CatalogStore()
    private let propagation = PropagationService()
    private let client = OrbitalAPIClient()
    private var refreshCoordinator: CatalogRefreshCoordinator!
    private var ticker: Task<Void, Never>?
    private let policy = RefreshPolicy()
    private var lastSuccessfulCatalogCheck: Date?
    private let defaults: UserDefaults
    private var lastLiveActivityHeadingUpdate = Date.distantPast
    private var servingTracker = ServingCandidateTracker()

    init() {
        let defaults = UserDefaults.standard
        self.defaults = defaults
        defaults.removeObject(forKey: "elevationMask")
        lastCatalogRequestAttempt = defaults.object(forKey: Self.lastCatalogRequestAttemptKey) as? Date
        lastSuccessfulCatalogCheck = defaults.object(forKey: Self.lastSuccessfulCatalogCheckKey) as? Date
        usesManualLocation = defaults.object(forKey: "usesManualLocation") as? Bool ?? false
        manualLatitude = defaults.object(forKey: "manualLatitude") as? Double ?? 40.7608
        manualLongitude = defaults.object(forKey: "manualLongitude") as? Double ?? -111.8910
        refreshCoordinator = CatalogRefreshCoordinator(client: client, store: store, policy: policy)
        connectivity.onEligibleTransition = { [weak self] in
            Task { await self?.refreshIfNeeded() }
        }
        connectivity.onPathUpdate = { [weak self] mode, quality in
            self?.linkQuality.updatePath(mode: mode, systemQuality: quality)
        }
        location.onHeadingUpdate = { [weak self] in
            self?.updateLinkEstimateForPhoneOrientation()
            self?.updateLiveActivityForHeading()
        }
        location.onOrientationUpdate = { [weak self] in
            self?.updateLinkEstimateForPhoneOrientation()
        }
        linkQuality.onSummaryUpdate = { [weak self] _ in
            self?.updateLiveActivityForLinkQuality()
        }
    }

    deinit { ticker?.cancel() }

    var observerLocation: ObserverLocation {
        if !usesManualLocation, let current = location.location { return current }
        return ObserverLocation(latitude: manualLatitude, longitude: manualLongitude)
    }

    var visibleObservations: [SatelliteObservation] {
        observations.filter(isObservationVisible)
    }

    func effectiveElevationMask(atAzimuth azimuth: Double) -> Double {
        max(elevationMask, terrain.rfHorizonDegrees(at: azimuth))
    }

    func isObservationVisible(_ observation: SatelliteObservation) -> Bool {
        observation.elevationDegrees >= effectiveElevationMask(atAzimuth: observation.azimuthDegrees)
    }

    func isObservationServiceCapable(_ observation: SatelliteObservation) -> Bool {
        guard isObservationVisible(observation) else { return false }
        return D2CUplinkBudget.assessment(
            for: observation,
            phoneHeadingDegrees: location.headingDegrees,
            phonePointingElevationDegrees: location.phonePointingElevationDegrees
        ).adjustedMarginDB >= D2CUplinkBudget.dependableMarginDB
    }

    var selectedObservation: SatelliteObservation? {
        let id = selectedSatelliteID ?? estimate.satellite?.id
        return observations.first { $0.id == id }
    }

    var freshness: CatalogFreshness? {
        catalog.map { CatalogFreshness.classify(age: max(0, Date().timeIntervalSince($0.fetchedAt))) }
    }

    var representativeTLEAgeSeconds: TimeInterval? {
        guard let catalog else { return nil }
        let ages = catalog.records
            .filter(\.directToCell)
            .map { max(0, Date().timeIntervalSince($0.elements.epoch)) }
            .sorted()
        guard !ages.isEmpty else { return nil }
        return ages[ages.count / 2]
    }

    var tleInputStatus: InputStatus {
        guard let age = representativeTLEAgeSeconds else {
            return InputStatus(
                id: "tle",
                label: "TLE unavailable",
                systemImage: "clock.badge.questionmark",
                level: .unavailable,
                detail: "No Direct-to-Cell orbital epochs are loaded."
            )
        }
        let freshness = TLEEpochFreshness.classify(age: age)
        let level: InputStatusLevel = switch freshness {
        case .current: .current
        case .aging: .attention
        case .stale: .stale
        }
        let label = switch freshness {
        case .current: "TLE epoch · \(Self.compactAge(age))"
        case .aging: "TLE epoch aging · \(Self.compactAge(age))"
        case .stale: "TLE epoch stale · \(Self.compactAge(age))"
        }
        let catalogAge = catalog.map { max(0, Date().timeIntervalSince($0.fetchedAt)) }
        let catalogDetail = catalogAge.map {
            "Catalog refreshed \(Self.compactAge($0)) ago; "
        } ?? ""
        return InputStatus(
            id: "tle",
            label: label,
            systemImage: level == .current ? "clock.badge.checkmark" : "clock.badge.exclamationmark",
            level: level,
            detail: "\(catalogDetail)representative Direct-to-Cell element epoch is \(Self.compactAge(age)) old."
        )
    }

    var servingInputStatus: InputStatus {
        guard usesManualLocation || location.location != nil else {
            return InputStatus(
                id: "serving",
                label: "Serving needs GPS",
                systemImage: "location.slash",
                level: .unavailable,
                detail: "A location is required to calculate the serving estimate."
            )
        }
        guard estimate.satellite != nil else {
            return InputStatus(
                id: "serving",
                label: "No serving candidate",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                level: .unavailable,
                detail: "No service-capable candidate is currently available."
            )
        }
        let age = max(0, Date().timeIntervalSince(estimate.estimatedAt))
        let tleLevel = tleInputStatus.level
        let level: InputStatusLevel
        if tleLevel == .stale {
            level = .stale
        } else if age < 15 {
            level = .current
        } else if age < 60 {
            level = .attention
        } else {
            level = .stale
        }
        return InputStatus(
            id: "serving",
            label: level == .current ? "Serving live" : "Serving \(Self.compactAge(age)) old",
            systemImage: level == .current ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash",
            level: level,
            detail: level == .stale && tleLevel == .stale
                ? "The estimate is current, but its orbital elements are stale."
                : "Serving estimate calculated \(Self.compactAge(age)) ago."
        )
    }

    var inputStatuses: [InputStatus] {
        [tleInputStatus, terrain.coverageInputStatus, servingInputStatus]
    }

    var usesBundledSample: Bool {
        catalog?.records.first?.elements.source == .bundledSample
    }

    private static func compactAge(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded()))
        if value < 60 { return "\(value)s" }
        if value < 3_600 { return "\(value / 60)m" }
        if value < 86_400 { return "\(value / 3_600)h" }
        return String(format: "%.1fd", Double(value) / 86_400)
    }

    var nextCatalogRequestAllowedAt: Date? {
        policy.nextRequestAllowedAt(lastRequestAttempt: effectiveLastCatalogRequestAttempt)
    }

    var canRefreshCatalog: Bool {
        !isRefreshing
            && connectivity.mode.permitsCatalogRefresh
            && policy.isRequestAllowed(lastRequestAttempt: effectiveLastCatalogRequestAttempt, now: .now)
    }

    func start() async {
        connectivity.start()
        if !usesManualLocation, location.authorization == .notDetermined {
            location.requestLocationAccess()
        }
        location.startIfAuthorized()
        linkQuality.start(
            pathMode: connectivity.mode,
            systemQuality: connectivity.systemLinkQuality,
            backgroundTrackingActive: location.backgroundTrackingEnabled
        )
        do {
            if let detailedBoundaries = try? SampleDataLoader.detailedLandBoundaries() {
                coastlines = detailedBoundaries
            } else {
                coastlines = try SampleDataLoader.coastlines()
            }
            countryBoundaries = (try? SampleDataLoader.countryBoundaries()) ?? []
            stateBoundaries = (try? SampleDataLoader.stateProvinceBoundaries()) ?? []
            catalog = try await store.load() ?? SampleDataLoader.catalog()
            await updateNow()
            await refreshIfNeeded()
        } catch {
            refreshMessage = error.localizedDescription
        }
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                guard !Task.isCancelled else { break }
                await self?.updateNow()
            }
        }
        BackgroundRefreshScheduler.schedule()
    }

    func updateNow() async {
        guard let catalog else { return }
        let now = Date()
        let observer = observerLocation
        terrain.updateObserver(observer)
        let directToCell = catalog.records.filter(\.directToCell)
        let values = await propagation.observations(
            for: directToCell,
            observer: observer,
            at: now,
            elevationMask: 0
        )
        observations = values
        servingTracker.elevationMask = elevationMask
        let terrainVisibleValues = values.filter(isObservationVisible)
        let terrainClearanceQuality = Dictionary(uniqueKeysWithValues: terrainVisibleValues.map {
            ($0.id, terrain.clearanceQuality(for: $0))
        })
        let adjustedUplinkMargins = Dictionary(uniqueKeysWithValues: terrainVisibleValues.map {
            let assessment = D2CUplinkBudget.assessment(
                for: $0,
                phoneHeadingDegrees: location.headingDegrees,
                phonePointingElevationDegrees: location.phonePointingElevationDegrees
            )
            return ($0.id, assessment.adjustedMarginDB)
        })
        estimate = servingTracker.update(
            from: terrainVisibleValues,
            catalogFetchedAt: catalog.fetchedAt,
            networkMode: connectivity.mode,
            candidateClearanceQuality: terrainClearanceQuality,
            candidateAdjustedUplinkMarginDB: adjustedUplinkMargins,
            now: now
        )
        if let selected = selectedObservation?.satellite {
            groundTrack = await propagation.groundTrack(for: selected, centeredAt: now)
        } else {
            groundTrack = []
        }
        let servingObservation = values.first { $0.id == estimate.satellite?.id }
        linkQuality.updateSatelliteEstimate(
            estimate.selectedDiagnostics,
            observation: servingObservation,
            phoneHeadingDegrees: location.headingDegrees,
            phonePointingElevationDegrees: location.phonePointingElevationDegrees
        )
        await liveActivity.update(
            with: servingObservation,
            phoneHeadingDegrees: location.headingDegrees,
            linkQuality: linkQuality.isEnabled ? linkQuality.summary : nil
        )
        if location.backgroundTrackingEnabled && !liveActivity.isActive {
            location.disableBackgroundTracking()
            linkQuality.setBackgroundTrackingActive(false)
        }
        lastUpdatedAt = now
    }

    func select(_ id: Int?) {
        selectedSatelliteID = id == estimate.satellite?.id ? nil : id
        Task { await updateNow() }
    }

    func refresh(manual: Bool = true) async {
        guard !isRefreshing else { return }
        let mode = connectivity.mode
        do {
            let requestTime = Date()
            try policy.validateRequest(
                mode: mode,
                lastRequestAttempt: effectiveLastCatalogRequestAttempt,
                now: requestTime
            )
            isRefreshing = true
            defer { isRefreshing = false }
            let manifest = try SampleDataLoader.manifest()
            recordCatalogRequestAttempt(requestTime)
            catalog = try await refreshCoordinator.refresh(
                current: catalog,
                manifest: manifest,
                initialMode: mode,
                currentMode: { [state = connectivity.state] in await state.get() }
            )
            recordSuccessfulCatalogCheck(.now)
            refreshMessage = "Catalog updated successfully."
            await updateNow()
        } catch OrbitalDataError.notModified {
            recordSuccessfulCatalogCheck(.now)
            refreshMessage = "Catalog is already current."
        } catch OrbitalDataError.requestThrottled {
            refreshMessage = "CelesTrak limits catalog requests to once every two hours."
        } catch {
            refreshMessage = error.localizedDescription + " Cached data remains active."
        }
    }

    func refreshIfNeeded() async {
        let now = Date()
        guard policy.shouldRefresh(
            lastSuccessfulFetch: effectiveLastSuccessfulCatalogCheck,
            now: now,
            mode: connectivity.mode,
            isFallbackCatalog: usesBundledSample,
            lastRequestAttempt: effectiveLastCatalogRequestAttempt
        ) else { return }
        await refresh(manual: false)
    }

    func sceneBecameActive() async {
        sceneActivationToken &+= 1
        linkQuality.setForeground(true)
        await updateNow()
        await refreshIfNeeded()
    }

    func sceneEnteredBackground() {
        linkQuality.setForeground(false)
        linkQuality.setBackgroundTrackingActive(location.backgroundTrackingEnabled)
    }

    func startBackgroundSatelliteTracking() async {
        guard location.enableBackgroundTracking() else { return }
        let servingObservation = observations.first { $0.id == estimate.satellite?.id }
        if !(await liveActivity.start(
            with: servingObservation,
            phoneHeadingDegrees: location.headingDegrees,
            linkQuality: linkQuality.isEnabled ? linkQuality.summary : nil
        )) {
            location.disableBackgroundTracking()
        } else {
            linkQuality.setBackgroundTrackingActive(true)
        }
    }

    func stopBackgroundSatelliteTracking() async {
        await liveActivity.stop()
        location.disableBackgroundTracking()
        linkQuality.setBackgroundTrackingActive(false)
    }

    func backgroundRefresh() async {
        await refreshIfNeeded()
        BackgroundRefreshScheduler.schedule()
    }

    private func updateLiveActivityForHeading() {
        guard location.backgroundTrackingEnabled, liveActivity.isActive else { return }
        let now = Date()
        guard now.timeIntervalSince(lastLiveActivityHeadingUpdate) >= 0.75 else { return }
        lastLiveActivityHeadingUpdate = now
        let servingObservation = observations.first { $0.id == estimate.satellite?.id }
        Task { [weak self] in
            guard let self else { return }
            await self.liveActivity.update(
                with: servingObservation,
                phoneHeadingDegrees: self.location.headingDegrees,
                linkQuality: self.linkQuality.isEnabled ? self.linkQuality.summary : nil
            )
        }
    }

    private var effectiveLastCatalogRequestAttempt: Date? {
        if let lastCatalogRequestAttempt { return lastCatalogRequestAttempt }
        return usesBundledSample ? nil : catalog?.fetchedAt
    }

    private var effectiveLastSuccessfulCatalogCheck: Date? {
        let catalogDate = usesBundledSample ? nil : catalog?.fetchedAt
        return [lastSuccessfulCatalogCheck, catalogDate].compactMap { $0 }.max()
    }

    private func recordCatalogRequestAttempt(_ date: Date) {
        lastCatalogRequestAttempt = date
        defaults.set(date, forKey: Self.lastCatalogRequestAttemptKey)
    }

    private func recordSuccessfulCatalogCheck(_ date: Date) {
        lastSuccessfulCatalogCheck = date
        defaults.set(date, forKey: Self.lastSuccessfulCatalogCheckKey)
    }

    private static let lastCatalogRequestAttemptKey = "celesTrakLastCatalogRequestAttempt"
    private static let lastSuccessfulCatalogCheckKey = "celesTrakLastSuccessfulCatalogCheck"

    private func updateLinkEstimateForPhoneOrientation() {
        let servingObservation = observations.first { $0.id == estimate.satellite?.id }
        linkQuality.updateSatelliteEstimate(
            estimate.selectedDiagnostics,
            observation: servingObservation,
            phoneHeadingDegrees: location.headingDegrees,
            phonePointingElevationDegrees: location.phonePointingElevationDegrees
        )
    }

    private func updateLiveActivityForLinkQuality() {
        guard liveActivity.isActive else { return }
        let servingObservation = observations.first { $0.id == estimate.satellite?.id }
        Task { [weak self] in
            guard let self else { return }
            await self.liveActivity.update(
                with: servingObservation,
                phoneHeadingDegrees: self.location.headingDegrees,
                linkQuality: self.linkQuality.isEnabled ? self.linkQuality.summary : nil
            )
        }
    }
}
