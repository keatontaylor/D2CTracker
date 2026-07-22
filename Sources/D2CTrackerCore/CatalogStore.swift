import Foundation

public actor CatalogStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(directory: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let directory {
            self.directory = directory
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.directory = base.appendingPathComponent("D2CTracker", isDirectory: true)
        }
    }

    public func load() throws -> CatalogSnapshot? {
        let url = directory.appendingPathComponent("catalog.json")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try Self.decoder.decode(CatalogSnapshot.self, from: data)
    }

    public func replaceAtomically(with snapshot: CatalogSnapshot, minimumRecordCount: Int = 1) throws {
        guard snapshot.records.count >= minimumRecordCount else {
            throw OrbitalDataError.incomplete(expectedAtLeast: minimumRecordCount, actual: snapshot.records.count)
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoded = try Self.encoder.encode(snapshot)
        try encoded.write(to: directory.appendingPathComponent("catalog.json"), options: [.atomic, .completeFileProtectionUnlessOpen])
    }

    public func removeForTesting() throws {
        let url = directory.appendingPathComponent("catalog.json")
        if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

public enum SampleDataLoader {
    public static func catalog() throws -> CatalogSnapshot {
        let data = try resourceData(named: "sample-catalog", extension: "json")
        let manifest = try manifest()
        let elements = try GPJSONParser.parse(data, fetchedAt: manifest.generatedAt, source: .bundledSample)
        return CatalogSnapshot(
            records: ManifestMerger.merge(elements: elements, manifest: manifest),
            fetchedAt: manifest.generatedAt,
            manifestGeneratedAt: manifest.generatedAt
        )
    }

    public static func manifest() throws -> DirectToCellManifest {
        let data = try resourceData(named: "direct-to-cell-manifest", extension: "json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(DirectToCellManifest.self, from: data)
    }

    public static func coastlines() throws -> [[ObserverLocation]] {
        let data = try resourceData(named: "coastlines", extension: "json")
        return try JSONDecoder().decode([[ObserverLocation]].self, from: data)
    }

    public static func detailedLandBoundaries() throws -> [[ObserverLocation]] {
        try geoJSONLines(named: "ne_50m_land")
    }

    public static func stateProvinceBoundaries() throws -> [[ObserverLocation]] {
        try geoJSONLines(named: "ne_50m_admin_1_states_provinces_lines")
    }

    public static func countryBoundaries() throws -> [[ObserverLocation]] {
        try geoJSONLines(named: "ne_50m_admin_0_boundary_lines_land")
    }

    private static func geoJSONLines(named name: String) throws -> [[ObserverLocation]] {
        let data = try resourceData(named: name, extension: "geojson")
        guard
            let collection = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let features = collection["features"] as? [[String: Any]]
        else {
            throw OrbitalDataError.malformed("Invalid bundled GeoJSON resource \(name).geojson")
        }

        var output: [[ObserverLocation]] = []
        for feature in features {
            guard
                let geometry = feature["geometry"] as? [String: Any],
                let type = geometry["type"] as? String,
                let coordinates = geometry["coordinates"]
            else { continue }

            switch type {
            case "LineString":
                appendLine(coordinates, to: &output)
            case "MultiLineString", "Polygon":
                guard let lines = coordinates as? [Any] else { continue }
                for line in lines { appendLine(line, to: &output) }
            case "MultiPolygon":
                guard let polygons = coordinates as? [Any] else { continue }
                for polygon in polygons {
                    guard let rings = polygon as? [Any] else { continue }
                    for ring in rings { appendLine(ring, to: &output) }
                }
            default:
                continue
            }
        }
        return output
    }

    private static func appendLine(_ value: Any, to output: inout [[ObserverLocation]]) {
        guard let rawPoints = value as? [Any] else { return }
        let points = rawPoints.compactMap { value -> ObserverLocation? in
            guard
                let coordinate = value as? [Any],
                coordinate.count >= 2,
                let longitude = coordinate[0] as? Double,
                let latitude = coordinate[1] as? Double
            else { return nil }
            return ObserverLocation(latitude: latitude, longitude: longitude)
        }
        if points.count >= 2 { output.append(points) }
    }

    private static func resourceData(named name: String, extension ext: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: ext) else {
            throw OrbitalDataError.malformed("Missing bundled resource \(name).\(ext)")
        }
        return try Data(contentsOf: url)
    }
}
