import BackgroundTasks
import CoreLocation
import CoreMotion
import Foundation
import Network
import D2CTrackerCore

actor ConnectivityState {
    private var value: ConnectivityMode = .unknown
    func set(_ mode: ConnectivityMode) { value = mode }
    func get() -> ConnectivityMode { value }
}

@MainActor
final class ConnectivityMonitor: ObservableObject {
    @Published private(set) var mode: ConnectivityMode = .unknown
    @Published private(set) var systemLinkQuality: SystemLinkQuality = .unknown
    let state = ConnectivityState()
    var onEligibleTransition: (() -> Void)?
    var onPathUpdate: ((ConnectivityMode, SystemLinkQuality) -> Void)?

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.keatontaylor.D2CTracker.connectivity")
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        monitor.pathUpdateHandler = { [weak self] path in
            let next = Self.classify(path)
            let quality = Self.classifyLinkQuality(path)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let wasEligible = self.mode.permitsCatalogRefresh
                self.mode = next
                self.systemLinkQuality = quality
                await self.state.set(next)
                if !wasEligible && next.permitsCatalogRefresh { self.onEligibleTransition?() }
                self.onPathUpdate?(next, quality)
            }
        }
        monitor.start(queue: queue)
    }

    func stop() {
        monitor.cancel()
        started = false
    }

    private nonisolated static func classify(_ path: NWPath) -> ConnectivityMode {
        guard path.status == .satisfied else { return .offline }
        if #available(iOS 26.0, *) {
            if path.isUltraConstrained { return .ultraConstrained }
        }
        if path.isConstrained { return .constrained }
        if path.usesInterfaceType(.wifi) { return .wifi }
        if path.usesInterfaceType(.wiredEthernet) { return .wiredEthernet }
        if path.usesInterfaceType(.cellular) { return .terrestrialCellular }
        return .unknown
    }

    private nonisolated static func classifyLinkQuality(_ path: NWPath) -> SystemLinkQuality {
        guard #available(iOS 26.0, *) else { return .unknown }
        switch path.linkQuality {
        case .good: return .good
        case .moderate: return .moderate
        case .minimal: return .minimal
        case .unknown: return .unknown
        @unknown default: return .unknown
        }
    }
}

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    @Published private(set) var location: ObserverLocation?
    @Published private(set) var headingDegrees: Double?
    @Published private(set) var phonePointingElevationDegrees: Double?
    @Published private(set) var horizonViewHeadingDegrees: Double?
    @Published private(set) var horizonViewElevationDegrees: Double?
    @Published private(set) var authorization: CLAuthorizationStatus
    @Published private(set) var isReducedAccuracy = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var backgroundTrackingEnabled: Bool

    var onHeadingUpdate: (() -> Void)?
    var onOrientationUpdate: (() -> Void)?

    private let manager: CLLocationManager
    private let motionManager = CMMotionManager()
    private var magneticToTrueNorthCorrectionDegrees = 0.0

    override init() {
        manager = CLLocationManager()
        authorization = manager.authorizationStatus
        backgroundTrackingEnabled = UserDefaults.standard.bool(forKey: "backgroundSatelliteTracking")
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        manager.distanceFilter = 1_000
        manager.headingFilter = 1
    }

    func startIfAuthorized() {
        startDeviceOrientationUpdates()
        if authorization == .authorizedWhenInUse || authorization == .authorizedAlways {
            configureBackgroundTracking(backgroundTrackingEnabled)
            manager.startUpdatingLocation()
            if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        }
    }

    private func startDeviceOrientationUpdates() {
        guard motionManager.isDeviceMotionAvailable, !motionManager.isDeviceMotionActive else { return }
        let availableFrames = CMMotionManager.availableAttitudeReferenceFrames()
        let referenceFrame: CMAttitudeReferenceFrame
        let suppliesAbsoluteNorth: Bool
        let usesMagneticNorth: Bool
        if availableFrames.contains(.xTrueNorthZVertical) {
            referenceFrame = .xTrueNorthZVertical
            suppliesAbsoluteNorth = true
            usesMagneticNorth = false
        } else if availableFrames.contains(.xMagneticNorthZVertical) {
            referenceFrame = .xMagneticNorthZVertical
            suppliesAbsoluteNorth = true
            usesMagneticNorth = true
        } else {
            referenceFrame = .xArbitraryCorrectedZVertical
            suppliesAbsoluteNorth = false
            usesMagneticNorth = false
        }
        motionManager.deviceMotionUpdateInterval = 0.1
        motionManager.startDeviceMotionUpdates(using: referenceFrame, to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let gravity = motion.gravity
            // Core Motion's device Y axis points through the top edge of an iPhone.
            // Its projection onto world-up is -gravity.y, yielding the top-edge elevation.
            let pointingElevation = asin(min(1, max(-1, -gravity.y))) * 180 / .pi
            // The virtual-horizon sightline points through the back of the phone, like a
            // camera view. An upright screen therefore looks along the 0-degree horizon.
            let horizonViewElevation = asin(min(1, max(-1, gravity.z))) * 180 / .pi
            let rotation = motion.attitude.rotationMatrix
            // Core Motion's attitude matrix maps the north-referenced frame into
            // device coordinates. Apply its inverse (transpose) to the device's
            // back-facing screen normal (-Z): north = -m31, west = -m32.
            let northComponent = -rotation.m31
            let eastComponent = rotation.m32
            let horizontalMagnitude = hypot(northComponent, eastComponent)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let pointingChanged = self.phonePointingElevationDegrees
                    .map { abs($0 - pointingElevation) >= 0.5 } ?? true
                let horizonChanged = self.horizonViewElevationDegrees
                    .map { abs($0 - horizonViewElevation) >= 0.35 } ?? true
                if pointingChanged { self.phonePointingElevationDegrees = pointingElevation }
                if horizonChanged { self.horizonViewElevationDegrees = horizonViewElevation }
                // As the sightline approaches vertical, azimuth has no stable physical
                // meaning. Retain the last useful value instead of allowing a 180° snap.
                if suppliesAbsoluteNorth, horizontalMagnitude >= 0.10 {
                    let rawHeading = atan2(eastComponent, northComponent) * 180 / .pi
                    let correctedHeading = rawHeading + (usesMagneticNorth
                        ? self.magneticToTrueNorthCorrectionDegrees
                        : 0)
                    let normalizedHeading = CoordinateTransforms.normalizedDegrees(correctedHeading)
                    let headingChanged = self.horizonViewHeadingDegrees.map {
                        abs(Self.shortestHeadingDelta(from: $0, to: normalizedHeading)) >= 0.25
                    } ?? true
                    if headingChanged { self.horizonViewHeadingDegrees = normalizedHeading }
                }
                if pointingChanged { self.onOrientationUpdate?() }
            }
        }
    }

    func requestLocationAccess() {
        manager.requestWhenInUseAuthorization()
    }

    @discardableResult
    func enableBackgroundTracking() -> Bool {
        guard authorization == .authorizedWhenInUse || authorization == .authorizedAlways else {
            errorMessage = authorization == .notDetermined
                ? "Allow location access, then tap Start again."
                : "Location access is required for background satellite tracking."
            if authorization == .notDetermined { requestLocationAccess() }
            return false
        }
        backgroundTrackingEnabled = true
        UserDefaults.standard.set(true, forKey: "backgroundSatelliteTracking")
        configureBackgroundTracking(true)
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        errorMessage = nil
        return true
    }

    func disableBackgroundTracking() {
        backgroundTrackingEnabled = false
        UserDefaults.standard.set(false, forKey: "backgroundSatelliteTracking")
        configureBackgroundTracking(false)
        manager.stopUpdatingLocation()
        startIfAuthorized()
    }

    private func configureBackgroundTracking(_ enabled: Bool) {
        manager.allowsBackgroundLocationUpdates = enabled
        manager.pausesLocationUpdatesAutomatically = !enabled
        manager.showsBackgroundLocationIndicator = enabled
        manager.activityType = enabled ? .otherNavigation : .other
        manager.desiredAccuracy = enabled ? kCLLocationAccuracyHundredMeters : kCLLocationAccuracyKilometer
        manager.distanceFilter = enabled ? 25 : 1_000
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        isReducedAccuracy = manager.accuracyAuthorization == .reducedAccuracy
        startIfAuthorized()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let latest = locations.last else { return }
        location = ObserverLocation(
            latitude: latest.coordinate.latitude,
            longitude: latest.coordinate.longitude,
            altitudeKilometers: max(0, latest.altitude) / 1_000,
            horizontalAccuracyKilometers: latest.horizontalAccuracy >= 0
                ? latest.horizontalAccuracy / 1_000
                : nil
        )
        errorMessage = nil
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let value = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        headingDegrees = value >= 0 ? value : nil
        if newHeading.trueHeading >= 0, newHeading.magneticHeading >= 0 {
            magneticToTrueNorthCorrectionDegrees = Self.shortestHeadingDelta(
                from: newHeading.magneticHeading,
                to: newHeading.trueHeading
            )
        }
        onHeadingUpdate?()
    }

    private nonisolated static func shortestHeadingDelta(from origin: Double, to target: Double) -> Double {
        var delta = (target - origin).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 }
        if delta < -180 { delta += 360 }
        return delta
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        errorMessage = error.localizedDescription
    }
}

enum BackgroundRefreshScheduler {
    static let identifier = "com.keatontaylor.D2CTracker.catalog-refresh"

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 6 * 3_600)
        do { try BGTaskScheduler.shared.submit(request) }
        catch { /* Background refresh may be disabled or unavailable in Simulator. */ }
    }
}
