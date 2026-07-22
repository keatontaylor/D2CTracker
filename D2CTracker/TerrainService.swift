import Foundation
import D2CTrackerCore
import zlib

struct USStateRegion: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let name: String

    static let colorado = USStateRegion(id: "08", name: "Colorado")

    static let all: [USStateRegion] = [
        ("01", "Alabama"), ("02", "Alaska"), ("04", "Arizona"), ("05", "Arkansas"),
        ("06", "California"), ("08", "Colorado"), ("09", "Connecticut"), ("10", "Delaware"),
        ("11", "District of Columbia"), ("12", "Florida"), ("13", "Georgia"), ("15", "Hawaii"),
        ("16", "Idaho"), ("17", "Illinois"), ("18", "Indiana"), ("19", "Iowa"),
        ("20", "Kansas"), ("21", "Kentucky"), ("22", "Louisiana"), ("23", "Maine"),
        ("24", "Maryland"), ("25", "Massachusetts"), ("26", "Michigan"), ("27", "Minnesota"),
        ("28", "Mississippi"), ("29", "Missouri"), ("30", "Montana"), ("31", "Nebraska"),
        ("32", "Nevada"), ("33", "New Hampshire"), ("34", "New Jersey"), ("35", "New Mexico"),
        ("36", "New York"), ("37", "North Carolina"), ("38", "North Dakota"), ("39", "Ohio"),
        ("40", "Oklahoma"), ("41", "Oregon"), ("42", "Pennsylvania"), ("44", "Rhode Island"),
        ("45", "South Carolina"), ("46", "South Dakota"), ("47", "Tennessee"), ("48", "Texas"),
        ("49", "Utah"), ("50", "Vermont"), ("51", "Virginia"), ("53", "Washington"),
        ("54", "West Virginia"), ("55", "Wisconsin"), ("56", "Wyoming")
    ].map { USStateRegion(id: $0.0, name: $0.1) }
}

struct TerrainPackMetadata: Codable, Sendable {
    static let currentFormatVersion = 2

    let formatVersion: Int
    let state: USStateRegion
    let boundary: TerrainRegionBoundary
    let tiles: [TerrainTileKey]
    let downloadedAt: Date
    let actualBytes: Int64

    init(
        state: USStateRegion,
        boundary: TerrainRegionBoundary,
        tiles: [TerrainTileKey],
        downloadedAt: Date,
        actualBytes: Int64
    ) {
        formatVersion = Self.currentFormatVersion
        self.state = state
        self.boundary = boundary
        self.tiles = tiles
        self.downloadedAt = downloadedAt
        self.actualBytes = actualBytes
    }
}

@MainActor
final class TerrainService: ObservableObject {
    enum Activity: Equatable {
        case idle
        case loadingBoundary
        case planning
        case downloading
        case buildingHorizon

        var label: String {
            switch self {
            case .idle: "Ready"
            case .loadingBoundary: "Loading state boundary…"
            case .planning: "Calculating tile coverage…"
            case .downloading: "Downloading terrain…"
            case .buildingHorizon: "Building local horizon…"
            }
        }
    }

    @Published var isEnabled: Bool {
        didSet { UserDefaults.standard.set(isEnabled, forKey: "terrainLineOfSightEnabled") }
    }
    @Published var selectedStateID: String {
        didSet {
            UserDefaults.standard.set(selectedStateID, forKey: "terrainSelectedStateFIPS")
            if oldValue != selectedStateID {
                preparationRevision &+= 1
                preparedBoundary = nil
                preparedPlan = nil
                preparedStateID = nil
                plannedTileCount = 0
                estimatedBytes = 0
                cachedTileCount = 0
                cachedTileBytes = 0
                remainingEstimatedBytes = 0
                availableStorageBytes = nil
                errorMessage = nil
                if activity == .loadingBoundary || activity == .planning {
                    activity = .idle
                }
            }
        }
    }
    @Published private(set) var activity: Activity = .idle
    @Published private(set) var plannedTileCount = 0
    @Published private(set) var estimatedBytes: Int64 = 0
    @Published private(set) var progress = 0.0
    @Published private(set) var completedTileCount = 0
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var cachedTileCount = 0
    @Published private(set) var cachedTileBytes: Int64 = 0
    @Published private(set) var remainingEstimatedBytes: Int64 = 0
    @Published private(set) var availableStorageBytes: Int64?
    @Published private(set) var pack: TerrainPackMetadata?
    @Published private(set) var horizonProfile: TerrainHorizonProfile?
    @Published private(set) var observerInsideInstalledPack = false
    @Published private(set) var statusMessage: String?
    @Published private(set) var errorMessage: String?

    private var preparedBoundary: TerrainRegionBoundary?
    private var preparedPlan: TerrainTilePlan?
    private var preparedStateID: String?
    private var preparationRevision = 0
    private var downloadTask: Task<Void, Never>?
    private var horizonTask: Task<Void, Never>?
    private let fileManager = FileManager.default

    init() {
        let defaults = UserDefaults.standard
        isEnabled = defaults.object(forKey: "terrainLineOfSightEnabled") as? Bool ?? true
        selectedStateID = defaults.string(forKey: "terrainSelectedStateFIPS") ?? USStateRegion.colorado.id
        loadSavedState()
    }

    var selectedState: USStateRegion {
        USStateRegion.all.first { $0.id == selectedStateID } ?? .colorado
    }

    var isBusy: Bool { activity != .idle }

    var hasPackForSelectedState: Bool { pack?.state.id == selectedStateID }

    var hasResumableDownload: Bool {
        cachedTileCount > 0 && cachedTileCount < plannedTileCount
    }

    var requiredStorageBytes: Int64 {
        guard remainingEstimatedBytes > 0 else { return 0 }
        return remainingEstimatedBytes + Self.storageSafetyReserveBytes
    }

    var hasSufficientStorage: Bool {
        guard requiredStorageBytes > 0 else { return true }
        guard let availableStorageBytes else { return false }
        return availableStorageBytes >= requiredStorageBytes
    }

    var coverageInputStatus: InputStatus {
        if !isEnabled {
            return InputStatus(
                id: "terrain",
                label: "Terrain off",
                systemImage: "mountain.2",
                level: .unavailable,
                detail: "Terrain line-of-sight modeling is disabled."
            )
        }
        if horizonProfile != nil {
            return InputStatus(
                id: "terrain",
                label: "Terrain ready",
                systemImage: "mountain.2.fill",
                level: .current,
                detail: "A local terrain horizon is active for the observer location."
            )
        }
        if activity == .buildingHorizon {
            return InputStatus(
                id: "terrain",
                label: "Terrain building",
                systemImage: "mountain.2",
                level: .attention,
                detail: "The local terrain horizon is being calculated."
            )
        }
        if let pack {
            return InputStatus(
                id: "terrain",
                label: observerInsideInstalledPack ? "Terrain pending" : "Terrain outside coverage",
                systemImage: observerInsideInstalledPack ? "hourglass" : "map",
                level: .attention,
                detail: observerInsideInstalledPack
                    ? "The installed \(pack.state.name) pack covers this location, but no horizon is active yet."
                    : "The observer is outside the installed \(pack.state.name) terrain pack."
            )
        }
        if hasResumableDownload {
            let percent = Int((Double(cachedTileCount) / Double(max(1, plannedTileCount)) * 100).rounded())
            return InputStatus(
                id: "terrain",
                label: "Terrain partial \(percent)%",
                systemImage: "arrow.down.circle",
                level: .attention,
                detail: "A partial terrain download is cached and can be resumed."
            )
        }
        return InputStatus(
            id: "terrain",
            label: "Terrain unavailable",
            systemImage: "mountain.2",
            level: .unavailable,
            detail: "No terrain pack is installed for this location."
        )
    }

    var progressLabel: String {
        guard activity == .downloading else { return activity.label }
        return "\(completedTileCount.formatted()) of \(plannedTileCount.formatted()) tiles"
    }

    func prepareSelectedState() async {
        if preparedStateID == selectedStateID, preparedPlan != nil { return }
        guard activity != .downloading, activity != .buildingHorizon else { return }
        let requestedState = selectedState
        let requestedRevision = preparationRevision
        errorMessage = nil
        statusMessage = nil
        activity = .loadingBoundary
        do {
            let boundary = try await Self.fetchBoundary(for: requestedState)
            guard requestedRevision == preparationRevision,
                  requestedState.id == selectedStateID else { return }
            activity = .planning
            let plan = await Task.detached(priority: .userInitiated) {
                TerrainTilePlanner.statePlan(for: boundary)
            }.value
            guard requestedRevision == preparationRevision,
                  requestedState.id == selectedStateID else { return }
            preparedBoundary = boundary
            preparedPlan = plan
            preparedStateID = requestedState.id
            plannedTileCount = plan.tiles.count
            estimatedBytes = plan.estimatedBytes
            updateStoragePreflight(for: plan)
            activity = .idle
        } catch {
            guard requestedRevision == preparationRevision,
                  requestedState.id == selectedStateID else { return }
            activity = .idle
            errorMessage = "Couldn’t prepare \(requestedState.name): \(error.localizedDescription)"
        }
    }

    func downloadSelectedState() {
        guard downloadTask == nil else { return }
        downloadTask = Task { [weak self] in
            guard let self else { return }
            let requestedState = self.selectedState
            if self.preparedStateID != requestedState.id || self.preparedPlan == nil {
                await self.prepareSelectedState()
            }
            guard self.selectedStateID == requestedState.id,
                  self.preparedStateID == requestedState.id,
                  let boundary = self.preparedBoundary,
                  let plan = self.preparedPlan else {
                self.downloadTask = nil
                return
            }
            self.updateStoragePreflight(for: plan)
            guard self.hasSufficientStorage else {
                self.errorMessage = self.storageFailureMessage
                self.downloadTask = nil
                return
            }
            await self.performDownload(boundary: boundary, plan: plan, state: requestedState)
            self.downloadTask = nil
        }
    }

    func refreshStoragePreflight() {
        guard let preparedPlan else {
            availableStorageBytes = currentAvailableStorageBytes()
            return
        }
        updateStoragePreflight(for: preparedPlan)
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        activity = .idle
        statusMessage = "Download paused. Completed tiles remain cached and will be reused."
    }

    func removeDownloadedTerrain() {
        downloadTask?.cancel()
        horizonTask?.cancel()
        try? fileManager.removeItem(at: rootDirectory)
        pack = nil
        horizonProfile = nil
        downloadedBytes = 0
        cachedTileCount = 0
        cachedTileBytes = 0
        remainingEstimatedBytes = estimatedBytes
        availableStorageBytes = currentAvailableStorageBytes()
        progress = 0
        completedTileCount = 0
        observerInsideInstalledPack = false
        activity = .idle
        statusMessage = "Downloaded terrain removed."
        errorMessage = nil
    }

    func updateObserver(_ observer: ObserverLocation) {
        let coordinate = TerrainCoordinate(
            latitude: observer.latitude,
            longitude: observer.longitude
        )
        observerInsideInstalledPack = pack?.boundary.contains(coordinate) ?? false
        guard isEnabled, let pack, observerInsideInstalledPack else {
            horizonProfile = nil
            return
        }
        if let profile = horizonProfile {
            let distance = Self.haversineKilometers(
                profile.observer,
                TerrainCoordinate(latitude: observer.latitude, longitude: observer.longitude)
            )
            if distance < 0.75 { return }
        }
        guard horizonTask == nil else { return }
        activity = .buildingHorizon
        let tileDirectory = self.tileDirectory
        horizonTask = Task { [weak self] in
            guard let self else { return }
            do {
                let profile = try await Task.detached(priority: .utility) {
                    try TerrainHorizonBuilder(
                        pack: pack,
                        tileDirectory: tileDirectory
                    ).build(for: observer)
                }.value
                guard !Task.isCancelled else { return }
                self.horizonProfile = profile
                try? self.persist(profile: profile)
                self.statusMessage = "Terrain horizon active at the current location."
            } catch {
                if !Task.isCancelled {
                    self.errorMessage = "Couldn’t build terrain horizon: \(error.localizedDescription)"
                }
            }
            self.activity = .idle
            self.horizonTask = nil
        }
    }

    func terrainElevationDegrees(at azimuth: Double) -> Double {
        guard isEnabled else { return 0 }
        return horizonProfile?.minimumElevationDegrees(atAzimuth: azimuth) ?? 0
    }

    func rfHorizonDegrees(at azimuth: Double) -> Double {
        guard isEnabled else { return 0 }
        return horizonProfile?.rfHorizonDegrees(atAzimuth: azimuth) ?? 0
    }

    func clearanceQuality(for observation: SatelliteObservation) -> Double {
        guard isEnabled, let horizonProfile else { return 1 }
        return horizonProfile.clearanceQuality(
            satelliteElevationDegrees: observation.elevationDegrees,
            atAzimuth: observation.azimuthDegrees
        )
    }

    private func performDownload(
        boundary: TerrainRegionBoundary,
        plan: TerrainTilePlan,
        state: USStateRegion
    ) async {
        activity = .downloading
        errorMessage = nil
        statusMessage = "Keep D2C Tracker open while the state pack downloads."
        plannedTileCount = plan.tiles.count
        estimatedBytes = plan.estimatedBytes
        completedTileCount = 0
        downloadedBytes = 0
        progress = 0
        do {
            try ensureDirectories()
            let existing = plan.tiles.filter { fileManager.fileExists(atPath: tileURL(for: $0).path) }
            completedTileCount = existing.count
            downloadedBytes = existing.reduce(into: Int64(0)) { total, tile in
                total += fileSize(at: tileURL(for: tile))
            }
            cachedTileCount = completedTileCount
            cachedTileBytes = downloadedBytes
            progress = plan.tiles.isEmpty ? 1 : Double(completedTileCount) / Double(plan.tiles.count)
            let missing = plan.tiles.filter { !fileManager.fileExists(atPath: tileURL(for: $0).path) }
            try await download(tiles: missing, totalCount: plan.tiles.count)
            try Task.checkCancellation()

            let bytes = plan.tiles.reduce(into: Int64(0)) { total, tile in
                total += fileSize(at: tileURL(for: tile))
            }
            let metadata = TerrainPackMetadata(
                state: state,
                boundary: boundary,
                tiles: plan.tiles,
                downloadedAt: .now,
                actualBytes: bytes
            )
            try persist(pack: metadata)
            pack = metadata
            downloadedBytes = bytes
            cachedTileBytes = bytes
            cachedTileCount = plan.tiles.count
            remainingEstimatedBytes = 0
            availableStorageBytes = currentAvailableStorageBytes()
            progress = 1
            statusMessage = "\(state.name) terrain is available offline."
            activity = .idle
        } catch is CancellationError {
            activity = .idle
            updateStoragePreflight(for: plan)
            statusMessage = "Download paused. Completed tiles remain cached and will be reused."
        } catch {
            activity = .idle
            updateStoragePreflight(for: plan)
            errorMessage = "Terrain download failed: \(error.localizedDescription)"
        }
    }

    private func download(tiles: [TerrainTileKey], totalCount: Int) async throws {
        guard !tiles.isEmpty else { return }
        let session = Self.makeDownloadSession()
        var iterator = tiles.makeIterator()
        try await withThrowingTaskGroup(of: (TerrainTileKey, Data).self) { group in
            for _ in 0..<min(3, tiles.count) {
                if let tile = iterator.next() {
                    group.addTask { (tile, try await Self.fetchTile(tile, session: session)) }
                }
            }
            while let (tile, data) = try await group.next() {
                try Task.checkCancellation()
                let destination = tileURL(for: tile)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: destination, options: .atomic)
                completedTileCount += 1
                downloadedBytes += Int64(data.count)
                cachedTileCount = completedTileCount
                cachedTileBytes = downloadedBytes
                progress = Double(completedTileCount) / Double(max(1, totalCount))
                if let next = iterator.next() {
                    group.addTask { (next, try await Self.fetchTile(next, session: session)) }
                }
            }
        }
        session.invalidateAndCancel()
    }

    private nonisolated static func fetchBoundary(for state: USStateRegion) async throws -> TerrainRegionBoundary {
        var components = URLComponents(string: "https://tigerweb.geo.census.gov/arcgis/rest/services/TIGERweb/State_County/MapServer/28/query")!
        components.queryItems = [
            URLQueryItem(name: "where", value: "STATE='\(state.id)'"),
            URLQueryItem(name: "outFields", value: "STATE,NAME"),
            URLQueryItem(name: "returnGeometry", value: "true"),
            URLQueryItem(name: "outSR", value: "4326"),
            URLQueryItem(name: "f", value: "geojson")
        ]
        guard let url = components.url else { throw TerrainServiceError.invalidBoundary }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TerrainServiceError.boundaryServer
        }
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any],
              let features = root["features"] as? [[String: Any]],
              let geometry = features.first?["geometry"] as? [String: Any],
              let type = geometry["type"] as? String,
              let coordinates = geometry["coordinates"] else {
            throw TerrainServiceError.invalidBoundary
        }
        let polygons: [TerrainPolygon]
        if type == "Polygon", let polygon = decodePolygon(coordinates) {
            polygons = [polygon]
        } else if type == "MultiPolygon", let values = coordinates as? [Any] {
            polygons = values.compactMap(decodePolygon)
        } else {
            throw TerrainServiceError.invalidBoundary
        }
        guard !polygons.isEmpty else { throw TerrainServiceError.invalidBoundary }
        return TerrainRegionBoundary(polygons: polygons)
    }

    private nonisolated static func decodePolygon(_ value: Any) -> TerrainPolygon? {
        guard let rings = value as? [Any] else { return nil }
        let decoded: [[TerrainCoordinate]] = rings.compactMap { ring in
            guard let points = ring as? [[Double]] else { return nil }
            return points.compactMap { point in
                guard point.count >= 2 else { return nil }
                return TerrainCoordinate(latitude: point[1], longitude: point[0])
            }
        }
        return decoded.isEmpty ? nil : TerrainPolygon(rings: decoded)
    }

    private nonisolated static func makeDownloadSession() -> URLSession {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.allowsConstrainedNetworkAccess = false
        if #available(iOS 26.1, *) {
            configuration.allowsUltraConstrainedNetworkAccess = false
        }
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration)
    }

    private nonisolated static func fetchTile(_ tile: TerrainTileKey, session: URLSession) async throws -> Data {
        let url = URL(
            string: "https://s3.amazonaws.com/elevation-tiles-prod/skadi/\(tile.latitudeName)/\(tile.fileName)"
        )!
        var lastError: Error?
        for _ in 0..<2 {
            do {
                let (data, response) = try await session.data(from: url)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
                      data.count > 18, data.starts(with: [0x1f, 0x8b]) else {
                    throw TerrainServiceError.invalidTile
                }
                return data
            } catch {
                lastError = error
            }
        }
        throw lastError ?? TerrainServiceError.invalidTile
    }

    private var rootDirectory: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Terrain", isDirectory: true)
    }

    private var tileDirectory: URL { rootDirectory.appendingPathComponent("tiles", isDirectory: true) }
    private var manifestURL: URL { rootDirectory.appendingPathComponent("pack.json") }
    private var profileURL: URL { rootDirectory.appendingPathComponent("horizon.json") }

    private func tileURL(for tile: TerrainTileKey) -> URL {
        tileDirectory.appendingPathComponent(tile.relativePath)
    }

    private func ensureDirectories() throws {
        try fileManager.createDirectory(at: tileDirectory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var directory = rootDirectory
        try? directory.setResourceValues(values)
    }

    private func persist(pack: TerrainPackMetadata) throws {
        try ensureDirectories()
        let data = try Self.encoder.encode(pack)
        try data.write(to: manifestURL, options: .atomic)
    }

    private func persist(profile: TerrainHorizonProfile) throws {
        try ensureDirectories()
        try Self.encoder.encode(profile).write(to: profileURL, options: .atomic)
    }

    private func loadSavedState() {
        if fileManager.fileExists(atPath: manifestURL.path) {
            guard let data = try? Data(contentsOf: manifestURL),
                  let value = try? Self.decoder.decode(TerrainPackMetadata.self, from: data),
                  value.formatVersion == TerrainPackMetadata.currentFormatVersion else {
                try? fileManager.removeItem(at: rootDirectory)
                statusMessage = "The previous terrain format was removed. Download a smaller Skadi state pack."
                return
            }
            pack = value
            downloadedBytes = value.actualBytes
        } else if fileManager.fileExists(atPath: tileDirectory.path),
                  !fileManager.fileExists(atPath: tileDirectory.appendingPathComponent("skadi").path) {
            // Remove an interrupted legacy Terrarium download while preserving a
            // resumable Skadi download, whose cells live under tiles/skadi.
            try? fileManager.removeItem(at: rootDirectory)
        }
        if let data = try? Data(contentsOf: profileURL),
           let value = try? Self.decoder.decode(TerrainHorizonProfile.self, from: data),
           value.regionIdentifier == pack?.state.id {
            horizonProfile = value
        }
    }

    private func fileSize(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    private func updateStoragePreflight(for plan: TerrainTilePlan) {
        let existing = plan.tiles.filter { fileManager.fileExists(atPath: tileURL(for: $0).path) }
        cachedTileCount = existing.count
        cachedTileBytes = existing.reduce(into: Int64(0)) { total, tile in
            total += fileSize(at: tileURL(for: tile))
        }
        completedTileCount = cachedTileCount
        downloadedBytes = cachedTileBytes
        progress = plan.tiles.isEmpty ? 1 : Double(cachedTileCount) / Double(plan.tiles.count)
        let missingCount = max(0, plan.tiles.count - cachedTileCount)
        remainingEstimatedBytes = plan.tiles.isEmpty ? 0 : Int64(ceil(
            Double(plan.estimatedBytes) * Double(missingCount) / Double(plan.tiles.count)
        ))
        availableStorageBytes = currentAvailableStorageBytes()
    }

    private func currentAvailableStorageBytes() -> Int64? {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return try? base.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
    }

    private var storageFailureMessage: String {
        guard let availableStorageBytes else {
            return "Couldn’t verify available storage. Try again after freeing space."
        }
        let required = ByteCountFormatter.string(fromByteCount: requiredStorageBytes, countStyle: .file)
        let available = ByteCountFormatter.string(fromByteCount: availableStorageBytes, countStyle: .file)
        return "Not enough free space to resume this terrain pack. \(required) is required including the safety reserve; \(available) is available."
    }

    private static let storageSafetyReserveBytes: Int64 = 256 * 1_024 * 1_024

    private nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private nonisolated static func haversineKilometers(_ first: TerrainCoordinate, _ second: TerrainCoordinate) -> Double {
        let latitudeDelta = (second.latitude - first.latitude) * .pi / 180
        let longitudeDelta = (second.longitude - first.longitude) * .pi / 180
        let firstLatitude = first.latitude * .pi / 180
        let secondLatitude = second.latitude * .pi / 180
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(firstLatitude) * cos(secondLatitude)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return 6_371.0088 * 2 * atan2(sqrt(a), sqrt(1 - a))
    }
}

private enum TerrainServiceError: LocalizedError {
    case invalidBoundary
    case boundaryServer
    case invalidTile
    case missingElevation

    var errorDescription: String? {
        switch self {
        case .invalidBoundary: "The state boundary data was not in the expected format."
        case .boundaryServer: "The Census boundary service did not respond successfully."
        case .invalidTile: "A terrain tile was missing or malformed."
        case .missingElevation: "No downloaded elevation tile covers this location."
        }
    }
}

private struct TerrainHorizonBuilder: Sendable {
    let pack: TerrainPackMetadata
    let tileDirectory: URL

    func build(for observer: ObserverLocation) throws -> TerrainHorizonProfile {
        let sampler = TerrainElevationSampler(pack: pack, tileDirectory: tileDirectory)
        let origin = TerrainCoordinate(latitude: observer.latitude, longitude: observer.longitude)
        let terrainAtObserver = try sampler.elevationMeters(at: origin)
        let observerElevation = max(terrainAtObserver + 1.5, observer.altitudeKilometers * 1_000)
        let distances = Self.sampleDistances
        var horizon: [Double] = []
        var obstructionDistances: [Double] = []
        horizon.reserveCapacity(360)
        obstructionDistances.reserveCapacity(360)
        for azimuth in 0..<360 {
            try Task.checkCancellation()
            var maximum = 0.0
            var maximumDistance = 0.0
            for distance in distances {
                let coordinate = TerrainLineOfSight.destination(
                    from: origin,
                    azimuthDegrees: Double(azimuth),
                    distanceKilometers: distance
                )
                guard let elevation = try? sampler.elevationMeters(at: coordinate) else { continue }
                let apparentElevation = TerrainLineOfSight.apparentElevationDegrees(
                    observerElevationMeters: observerElevation,
                    targetElevationMeters: elevation,
                    distanceKilometers: distance
                )
                if apparentElevation > maximum {
                    maximum = apparentElevation
                    maximumDistance = distance
                }
            }
            horizon.append(min(45, maximum))
            obstructionDistances.append(maximumDistance)
        }
        return TerrainHorizonProfile(
            observer: origin,
            observerElevationMeters: observerElevation,
            azimuthStepDegrees: 1,
            elevationDegrees: horizon,
            obstructionDistanceKilometers: obstructionDistances,
            maximumRangeKilometers: TerrainTilePlanner.serviceRangeKilometers,
            generatedAt: .now,
            regionIdentifier: pack.state.id
        )
    }

    private static let sampleDistances: [Double] = {
        var values: [Double] = []
        values += stride(from: 0.1, through: 10.0, by: 0.25)
        values += stride(from: 10.5, through: 40.0, by: 0.5)
        values += stride(from: 41.0, through: TerrainTilePlanner.serviceRangeKilometers, by: 1.0)
        if values.last != TerrainTilePlanner.serviceRangeKilometers {
            values.append(TerrainTilePlanner.serviceRangeKilometers)
        }
        return values
    }()
}

private final class TerrainElevationSampler: @unchecked Sendable {
    private let availableTiles: Set<TerrainTileKey>
    private let tileDirectory: URL
    private let cache = NSCache<NSString, TerrainRaster>()

    init(pack: TerrainPackMetadata, tileDirectory: URL) {
        availableTiles = Set(pack.tiles)
        self.tileDirectory = tileDirectory
        cache.countLimit = 6
        cache.totalCostLimit = 160 * 1_024 * 1_024
    }

    func elevationMeters(at coordinate: TerrainCoordinate) throws -> Double {
        let key = TerrainTilePlanner.tileKey(containing: coordinate)
        guard availableTiles.contains(key) else { throw TerrainServiceError.missingElevation }
        return try raster(for: key).elevationMeters(at: coordinate, tile: key)
    }

    private func raster(for key: TerrainTileKey) throws -> TerrainRaster {
        let cacheKey = key.id as NSString
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let url = tileDirectory.appendingPathComponent(key.relativePath)
        let raster = try TerrainRaster(compressedURL: url)
        cache.setObject(raster, forKey: cacheKey, cost: raster.byteCount)
        return raster
    }
}

private final class TerrainRaster {
    private let bytes: [UInt8]
    private let dimension: Int

    var byteCount: Int { bytes.count }

    init(compressedURL: URL) throws {
        let storage = try Self.gunzip(compressedURL)
        guard storage.count.isMultiple(of: 2) else { throw TerrainServiceError.invalidTile }
        let sampleCount = storage.count / 2
        let rasterDimension = Int(Double(sampleCount).squareRoot().rounded())
        guard rasterDimension >= 2, rasterDimension * rasterDimension == sampleCount else {
            throw TerrainServiceError.invalidTile
        }
        bytes = storage
        dimension = rasterDimension
    }

    func elevationMeters(at coordinate: TerrainCoordinate, tile: TerrainTileKey) throws -> Double {
        let maximumIndex = Double(dimension - 1)
        let longitudeFraction = max(0, min(1, coordinate.longitude - Double(tile.longitude)))
        let latitudeFraction = max(0, min(1, Double(tile.latitude + 1) - coordinate.latitude))
        let x = longitudeFraction * maximumIndex
        let y = latitudeFraction * maximumIndex
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(dimension - 1, x0 + 1)
        let y1 = min(dimension - 1, y0 + 1)
        let xFraction = x - Double(x0)
        let yFraction = y - Double(y0)
        let samples = [
            (sample(x: x0, y: y0), (1 - xFraction) * (1 - yFraction)),
            (sample(x: x1, y: y0), xFraction * (1 - yFraction)),
            (sample(x: x0, y: y1), (1 - xFraction) * yFraction),
            (sample(x: x1, y: y1), xFraction * yFraction)
        ]
        let valid = samples.compactMap { elevation, weight in elevation.map { ($0, weight) } }
        let weight = valid.reduce(0) { $0 + $1.1 }
        guard weight > 0 else { throw TerrainServiceError.missingElevation }
        return valid.reduce(0) { $0 + $1.0 * $1.1 } / weight
    }

    private func sample(x: Int, y: Int) -> Double? {
        let index = (y * dimension + x) * 2
        let value = Int16(bitPattern: UInt16(bytes[index]) << 8 | UInt16(bytes[index + 1]))
        return value == Int16.min ? nil : Double(value)
    }

    private static func gunzip(_ url: URL) throws -> [UInt8] {
        guard let file = url.path.withCString({ gzopen($0, "rb") }) else {
            throw TerrainServiceError.invalidTile
        }
        defer { gzclose(file) }
        var result: [UInt8] = []
        result.reserveCapacity(3_601 * 3_601 * 2)
        var buffer = [UInt8](repeating: 0, count: 256 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes { pointer in
                gzread(file, pointer.baseAddress, UInt32(pointer.count))
            }
            guard count >= 0 else { throw TerrainServiceError.invalidTile }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(Int(count)))
            guard result.count <= 100 * 1_024 * 1_024 else {
                throw TerrainServiceError.invalidTile
            }
        }
        return result
    }
}
