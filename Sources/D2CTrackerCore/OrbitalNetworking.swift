import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CatalogHTTPResponse: Sendable {
    public let data: Data
    public let etag: String?
    public let lastModified: String?

    public init(data: Data, etag: String?, lastModified: String?) {
        self.data = data
        self.etag = etag
        self.lastModified = lastModified
    }
}

public actor OrbitalAPIClient {
    /// CelesTrak tags Starlink Direct-to-Cell object names with a distinct DTC token.
    /// Querying that token avoids the much larger full-Starlink response and makes the
    /// upstream object name the catalog membership source of truth.
    public static let directToCellGPURL = URL(string: "https://celestrak.org/NORAD/elements/gp.php?NAME=%5BDTC%5D&FORMAT=JSON")!
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.allowsConstrainedNetworkAccess = true
            configuration.allowsExpensiveNetworkAccess = true
            configuration.waitsForConnectivity = true
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 60
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            #if !os(Linux)
            if #available(iOS 26.1, macOS 26.1, tvOS 26.1, watchOS 26.1, *) {
                configuration.allowsUltraConstrainedNetworkAccess = true
            }
            #endif
            self.session = URLSession(configuration: configuration)
        }
    }

    public func fetch(
        from url: URL = directToCellGPURL,
        etag: String? = nil,
        lastModified: String? = nil
    ) async throws -> CatalogHTTPResponse {
        guard url.scheme?.lowercased() == "https" else {
            throw OrbitalDataError.malformed("Only HTTPS orbital sources are allowed")
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsConstrainedNetworkAccess = true
        request.allowsExpensiveNetworkAccess = true
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("D2CTracker/1.0 (iOS; CelesTrak GP client)", forHTTPHeaderField: "User-Agent")
        #if !os(Linux)
        if #available(iOS 26.1, macOS 26.1, tvOS 26.1, watchOS 26.1, *) {
            request.allowsUltraConstrainedNetworkAccess = true
        }
        #endif
        if let etag { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let lastModified { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OrbitalDataError.invalidResponse }
        if http.statusCode == 304 { throw OrbitalDataError.notModified }
        guard (200..<300).contains(http.statusCode) else {
            throw OrbitalDataError.httpStatus(
                statusCode: http.statusCode,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After")
            )
        }
        guard !data.isEmpty else { throw OrbitalDataError.invalidResponse }
        return CatalogHTTPResponse(
            data: data,
            etag: http.value(forHTTPHeaderField: "ETag"),
            lastModified: http.value(forHTTPHeaderField: "Last-Modified")
        )
    }
}

public struct RefreshPolicy: Sendable {
    public var staleAfter: TimeInterval
    public var minimumRequestInterval: TimeInterval

    public init(
        staleAfter: TimeInterval = 6 * 3_600,
        minimumRequestInterval: TimeInterval = 2 * 3_600
    ) {
        self.staleAfter = staleAfter
        self.minimumRequestInterval = minimumRequestInterval
    }

    public func shouldRefresh(
        lastSuccessfulFetch: Date?,
        now: Date,
        mode: ConnectivityMode,
        manual: Bool = false,
        isFallbackCatalog: Bool = false,
        lastRequestAttempt: Date? = nil
    ) -> Bool {
        guard mode.permitsCatalogRefresh else { return false }
        guard isRequestAllowed(lastRequestAttempt: lastRequestAttempt, now: now) else { return false }
        guard !manual else { return true }
        if isFallbackCatalog { return true }
        guard let lastSuccessfulFetch else { return true }
        return now.timeIntervalSince(lastSuccessfulFetch) >= staleAfter
    }

    public func validate(mode: ConnectivityMode) throws {
        guard mode.permitsCatalogRefresh else { throw OrbitalDataError.refreshDisallowed(mode) }
    }

    public func validateRequest(
        mode: ConnectivityMode,
        lastRequestAttempt: Date?,
        now: Date
    ) throws {
        try validate(mode: mode)
        if let nextAllowedAt = nextRequestAllowedAt(lastRequestAttempt: lastRequestAttempt),
           now < nextAllowedAt {
            throw OrbitalDataError.requestThrottled(nextAllowedAt: nextAllowedAt)
        }
    }

    public func isRequestAllowed(lastRequestAttempt: Date?, now: Date) -> Bool {
        guard let nextAllowedAt = nextRequestAllowedAt(lastRequestAttempt: lastRequestAttempt) else {
            return true
        }
        return now >= nextAllowedAt
    }

    public func nextRequestAllowedAt(lastRequestAttempt: Date?) -> Date? {
        lastRequestAttempt?.addingTimeInterval(minimumRequestInterval)
    }
}

public actor CatalogRefreshCoordinator {
    private let client: OrbitalAPIClient
    private let store: CatalogStore
    private let policy: RefreshPolicy

    public init(client: OrbitalAPIClient, store: CatalogStore, policy: RefreshPolicy = .init()) {
        self.client = client
        self.store = store
        self.policy = policy
    }

    public func refresh(
        current: CatalogSnapshot?,
        manifest: DirectToCellManifest,
        initialMode: ConnectivityMode,
        currentMode: @Sendable () async -> ConnectivityMode
    ) async throws -> CatalogSnapshot {
        try policy.validate(mode: initialMode)
        let sourceURL = OrbitalAPIClient.directToCellGPURL
        let canReuseValidators = current?.sourceURL == sourceURL
        let response = try await client.fetch(
            from: sourceURL,
            etag: canReuseValidators ? current?.etag : nil,
            lastModified: canReuseValidators ? current?.lastModified : nil
        )
        let completionMode = await currentMode()
        guard completionMode.permitsCatalogRefresh else { throw OrbitalDataError.pathBecameIneligible(completionMode) }

        let fetchedAt = Date()
        let elements = try GPJSONParser.parse(response.data, fetchedAt: fetchedAt).filter {
            $0.name.uppercased().hasPrefix("STARLINK-") && DirectToCellClassifier.hasDTCTag($0.name)
        }
        let minimum = max(1, (current?.records.count ?? 1) / 2)
        guard elements.count >= minimum else { throw OrbitalDataError.incomplete(expectedAtLeast: minimum, actual: elements.count) }
        let snapshot = CatalogSnapshot(
            records: ManifestMerger.merge(elements: elements, manifest: manifest),
            fetchedAt: fetchedAt,
            manifestGeneratedAt: manifest.generatedAt,
            etag: response.etag,
            lastModified: response.lastModified,
            sourceURL: sourceURL
        )
        try await store.replaceAtomically(with: snapshot, minimumRecordCount: minimum)
        return snapshot
    }
}
