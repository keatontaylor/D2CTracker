import Foundation

public enum OrbitalDataError: Error, LocalizedError, Equatable {
    case malformed(String)
    case incomplete(expectedAtLeast: Int, actual: Int)
    case invalidResponse
    case httpStatus(statusCode: Int, retryAfter: String?)
    case notModified
    case refreshDisallowed(ConnectivityMode)
    case pathBecameIneligible(ConnectivityMode)
    case requestThrottled(nextAllowedAt: Date)

    public var errorDescription: String? {
        switch self {
        case .malformed(let reason): "Malformed orbital data: \(reason)"
        case .incomplete(let expected, let actual): "Catalog was incomplete (expected at least \(expected), received \(actual))."
        case .invalidResponse: "The orbital data server returned an invalid response."
        case .httpStatus(let statusCode, let retryAfter):
            if let retryAfter {
                "CelesTrak returned HTTP \(statusCode) (retry after \(retryAfter))."
            } else {
                "CelesTrak returned HTTP \(statusCode)."
            }
        case .notModified: "The orbital catalog has not changed."
        case .refreshDisallowed(let mode): "Refresh is disabled on \(mode.rawValue) connectivity."
        case .pathBecameIneligible(let mode): "The network became \(mode.rawValue) before the refresh could be committed."
        case .requestThrottled: "CelesTrak requests are limited to once every two hours."
        }
    }
}

private struct FlexibleDouble: Decodable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Double(string) {
            value = number
        } else {
            throw DecodingError.typeMismatch(Double.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected a number or numeric string"))
        }
    }
}

private struct FlexibleInt: Decodable {
    let value: Int

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Int.self) {
            value = number
        } else if let string = try? container.decode(String.self), let number = Int(string) {
            value = number
        } else {
            throw DecodingError.typeMismatch(Int.self, .init(codingPath: decoder.codingPath, debugDescription: "Expected an integer or numeric string"))
        }
    }
}

private struct GPRecord: Decodable {
    let name: String
    let noradID: FlexibleInt
    let objectID: String?
    let epoch: Date
    let eccentricity: FlexibleDouble
    let inclination: FlexibleDouble
    let rightAscension: FlexibleDouble
    let argumentOfPericenter: FlexibleDouble
    let meanAnomaly: FlexibleDouble
    let meanMotion: FlexibleDouble
    let bstar: FlexibleDouble?
    let ephemerisType: FlexibleInt?
    let classification: String?
    let elementSet: FlexibleInt?
    let revolution: FlexibleInt?

    enum CodingKeys: String, CodingKey {
        case name = "OBJECT_NAME"
        case noradID = "NORAD_CAT_ID"
        case objectID = "OBJECT_ID"
        case epoch = "EPOCH"
        case eccentricity = "ECCENTRICITY"
        case inclination = "INCLINATION"
        case rightAscension = "RA_OF_ASC_NODE"
        case argumentOfPericenter = "ARG_OF_PERICENTER"
        case meanAnomaly = "MEAN_ANOMALY"
        case meanMotion = "MEAN_MOTION"
        case bstar = "BSTAR"
        case ephemerisType = "EPHEMERIS_TYPE"
        case classification = "CLASSIFICATION_TYPE"
        case elementSet = "ELEMENT_SET_NO"
        case revolution = "REV_AT_EPOCH"
    }
}

public enum GPJSONParser {
    public static func parse(_ data: Data, fetchedAt: Date = Date(), source: DataSource = .celesTrakJSON) throws -> [OrbitalElements] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            if let date = ISO8601DateFormatter.parseFlexible(string) {
                return date
            }
            throw DecodingError.dataCorruptedError(in: try decoder.singleValueContainer(), debugDescription: "Invalid ISO-8601 epoch")
        }
        let decoded: [GPRecord]
        do {
            decoded = try decoder.decode([GPRecord].self, from: data)
        } catch {
            throw OrbitalDataError.malformed(Self.decodingFailureDescription(error))
        }
        let records = decoded.compactMap { value -> OrbitalElements? in
            guard value.noradID.value > 0,
                  !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  (0..<1).contains(value.eccentricity.value),
                  (0...180).contains(value.inclination.value),
                  value.meanMotion.value > 0 else { return nil }
            return OrbitalElements(
                noradID: value.noradID.value,
                name: value.name,
                internationalDesignator: value.objectID ?? "",
                epoch: value.epoch,
                eccentricity: value.eccentricity.value,
                inclinationDegrees: value.inclination.value,
                rightAscensionDegrees: value.rightAscension.value,
                argumentOfPerigeeDegrees: value.argumentOfPericenter.value,
                meanAnomalyDegrees: value.meanAnomaly.value,
                meanMotionRevolutionsPerDay: value.meanMotion.value,
                bstar: value.bstar?.value ?? 0,
                ephemerisType: value.ephemerisType?.value ?? 0,
                classificationType: value.classification ?? "U",
                elementSetNumber: value.elementSet?.value ?? 0,
                revolutionAtEpoch: value.revolution?.value ?? 0,
                source: source,
                fetchedAt: fetchedAt
            )
        }
        guard !records.isEmpty else { throw OrbitalDataError.incomplete(expectedAtLeast: 1, actual: 0) }
        return records
    }

    private static func decodingFailureDescription(_ error: Error) -> String {
        let path: ([CodingKey]) -> String = { keys in
            keys.map { $0.intValue.map(String.init) ?? $0.stringValue }.joined(separator: ".")
        }
        switch error {
        case DecodingError.dataCorrupted(let context):
            return "\(context.debugDescription) at \(path(context.codingPath))"
        case DecodingError.keyNotFound(let key, let context):
            return "Missing \(key.stringValue) at \(path(context.codingPath))"
        case DecodingError.typeMismatch(let type, let context):
            return "Expected \(type) at \(path(context.codingPath)): \(context.debugDescription)"
        case DecodingError.valueNotFound(let type, let context):
            return "Missing \(type) value at \(path(context.codingPath))"
        default:
            return error.localizedDescription
        }
    }
}

public enum TLEParser {
    public static func parse(_ text: String, fetchedAt: Date = Date(), source: DataSource = .celesTrakTLE) throws -> [OrbitalElements] {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var output: [OrbitalElements] = []
        var index = 0
        while index < lines.count {
            let name: String
            let line1: String
            let line2: String
            if lines[index].hasPrefix("1 "), index + 1 < lines.count {
                name = "NORAD \(slice(lines[index], 2, 7).trimmingCharacters(in: .whitespaces))"
                line1 = lines[index]
                line2 = lines[index + 1]
                index += 2
            } else if index + 2 < lines.count {
                name = lines[index].replacingOccurrences(of: "0 ", with: "")
                line1 = lines[index + 1]
                line2 = lines[index + 2]
                index += 3
            } else { break }

            guard line1.hasPrefix("1 "), line2.hasPrefix("2 "), line1.count >= 69, line2.count >= 69,
                  hasValidChecksum(line1), hasValidChecksum(line2),
                  let norad = Int(slice(line1, 2, 7).trimmingCharacters(in: .whitespaces)),
                  let epoch = parseEpoch(slice(line1, 18, 32)),
                  let inclination = Double(slice(line2, 8, 16).trimmingCharacters(in: .whitespaces)),
                  let raan = Double(slice(line2, 17, 25).trimmingCharacters(in: .whitespaces)),
                  let eccentricity = Double("0." + slice(line2, 26, 33).trimmingCharacters(in: .whitespaces)),
                  let argument = Double(slice(line2, 34, 42).trimmingCharacters(in: .whitespaces)),
                  let anomaly = Double(slice(line2, 43, 51).trimmingCharacters(in: .whitespaces)),
                  let motion = Double(slice(line2, 52, 63).trimmingCharacters(in: .whitespaces)) else { continue }

            output.append(OrbitalElements(
                noradID: norad,
                name: name,
                internationalDesignator: slice(line1, 9, 17).trimmingCharacters(in: .whitespaces),
                epoch: epoch,
                eccentricity: eccentricity,
                inclinationDegrees: inclination,
                rightAscensionDegrees: raan,
                argumentOfPerigeeDegrees: argument,
                meanAnomalyDegrees: anomaly,
                meanMotionRevolutionsPerDay: motion,
                bstar: parseTLEExponent(slice(line1, 53, 61)),
                tleLine1: line1,
                tleLine2: line2,
                source: source,
                fetchedAt: fetchedAt
            ))
        }
        guard !output.isEmpty else { throw OrbitalDataError.incomplete(expectedAtLeast: 1, actual: 0) }
        return output
    }

    private static func slice(_ value: String, _ lower: Int, _ upper: Int) -> String {
        guard value.count >= upper else { return "" }
        let start = value.index(value.startIndex, offsetBy: lower)
        let end = value.index(value.startIndex, offsetBy: upper)
        return String(value[start..<end])
    }

    private static func parseEpoch(_ value: String) -> Date? {
        guard value.count >= 5, let shortYear = Int(value.prefix(2)), let day = Double(value.dropFirst(2)) else { return nil }
        let year = shortYear < 57 ? 2000 + shortYear : 1900 + shortYear
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = 1
        components.day = 1
        guard let start = components.date else { return nil }
        return start.addingTimeInterval((day - 1) * 86_400)
    }

    private static func parseTLEExponent(_ value: String) -> Double {
        let compact = value.replacingOccurrences(of: " ", with: "")
        guard compact.count >= 3 else { return 0 }
        let signIndex = compact.index(compact.endIndex, offsetBy: -2)
        let exponentSign = compact[signIndex] == "-" ? -1.0 : 1.0
        let mantissaText = compact[..<signIndex].replacingOccurrences(of: "+", with: "")
        guard let mantissa = Double(mantissaText), let exponent = Double(String(compact.last!)) else { return 0 }
        return mantissa * 1e-5 * pow(10, exponentSign * exponent)
    }

    private static func hasValidChecksum(_ line: String) -> Bool {
        guard line.count >= 69, let expected = line.prefix(69).last?.wholeNumberValue else { return false }
        let calculated = line.prefix(68).reduce(into: 0) { sum, character in
            if let digit = character.wholeNumberValue { sum += digit }
            else if character == "-" { sum += 1 }
        }
        return calculated % 10 == expected
    }
}

public enum ManifestMerger {
    public static func merge(elements: [OrbitalElements], manifest: DirectToCellManifest) -> [SatelliteRecord] {
        let entries = Dictionary(uniqueKeysWithValues: manifest.satellites.map { ($0.noradID, $0) })
        return elements.map { DirectToCellClassifier.classify(elements: $0, manifestEntry: entries[$0.noradID]) }
    }
}

extension ISO8601DateFormatter {
    static func parseFlexible(_ value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized: String
        if hasExplicitTimeZone(trimmed) {
            normalized = trimmed
        } else {
            // CelesTrak GP JSON documents EPOCH as UTC but currently omits the Z suffix.
            normalized = trimmed + "Z"
        }
        return fractionalFormatter().date(from: normalized) ?? standardFormatter().date(from: normalized)
    }

    static func formatFractional(_ date: Date) -> String {
        fractionalFormatter().string(from: date)
    }

    private static func standardFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }

    private static func fractionalFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    private static func hasExplicitTimeZone(_ value: String) -> Bool {
        if value.hasSuffix("Z") || value.hasSuffix("z") { return true }
        guard let separator = value.firstIndex(of: "T") else { return false }
        let time = value[value.index(after: separator)...]
        return time.contains("+") || time.contains("-")
    }
}
