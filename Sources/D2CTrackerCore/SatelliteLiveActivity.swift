#if os(iOS)
import ActivityKit
import Foundation

public struct SatelliteActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        public let satelliteName: String
        public let azimuthDegrees: Double
        public let elevationDegrees: Double
        public let compassPoint: String
        public let phoneHeadingDegrees: Double?
        public let relativeBearingDegrees: Double?
        public let linkQualityScore: Int?
        public let linkQualityGrade: String?
        public let linkLatencyMilliseconds: Int?
        public let linkSuccessRatePercent: Int?
        public let linkPathLabel: String?
        public let hasCandidate: Bool
        public let updatedAt: Date

        public init(
            satelliteName: String,
            azimuthDegrees: Double,
            elevationDegrees: Double,
            compassPoint: String,
            phoneHeadingDegrees: Double? = nil,
            relativeBearingDegrees: Double? = nil,
            linkQualityScore: Int? = nil,
            linkQualityGrade: String? = nil,
            linkLatencyMilliseconds: Int? = nil,
            linkSuccessRatePercent: Int? = nil,
            linkPathLabel: String? = nil,
            hasCandidate: Bool,
            updatedAt: Date
        ) {
            self.satelliteName = satelliteName
            self.azimuthDegrees = azimuthDegrees
            self.elevationDegrees = elevationDegrees
            self.compassPoint = compassPoint
            self.phoneHeadingDegrees = phoneHeadingDegrees
            self.relativeBearingDegrees = relativeBearingDegrees
            self.linkQualityScore = linkQualityScore
            self.linkQualityGrade = linkQualityGrade
            self.linkLatencyMilliseconds = linkLatencyMilliseconds
            self.linkSuccessRatePercent = linkSuccessRatePercent
            self.linkPathLabel = linkPathLabel
            self.hasCandidate = hasCandidate
            self.updatedAt = updatedAt
        }
    }

    public let startedAt: Date

    public init(startedAt: Date) {
        self.startedAt = startedAt
    }
}
#endif
