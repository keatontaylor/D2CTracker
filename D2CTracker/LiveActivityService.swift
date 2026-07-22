import ActivityKit
import Combine
import Foundation
import D2CTrackerCore

@MainActor
final class SatelliteLiveActivityService: ObservableObject {
    @Published private(set) var isActive: Bool
    @Published private(set) var errorMessage: String?

    var activitiesEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    init() {
        isActive = !Activity<SatelliteActivityAttributes>.activities.isEmpty
    }

    func start(
        with observation: SatelliteObservation?,
        phoneHeadingDegrees: Double?,
        linkQuality: LinkQualitySummary?
    ) async -> Bool {
        guard activitiesEnabled else {
            errorMessage = "Live Activities are disabled for D2C Tracker in Settings."
            return false
        }

        let state = contentState(
            for: observation,
            phoneHeadingDegrees: phoneHeadingDegrees,
            linkQuality: linkQuality
        )
        if let existing = Activity<SatelliteActivityAttributes>.activities.first {
            await existing.update(content(for: state))
            isActive = true
            errorMessage = nil
            return true
        }

        do {
            _ = try Activity.request(
                attributes: SatelliteActivityAttributes(startedAt: .now),
                content: content(for: state),
                pushType: nil
            )
            isActive = true
            errorMessage = nil
            return true
        } catch {
            isActive = false
            errorMessage = error.localizedDescription
            return false
        }
    }

    func update(
        with observation: SatelliteObservation?,
        phoneHeadingDegrees: Double?,
        linkQuality: LinkQualitySummary?
    ) async {
        let activities = Activity<SatelliteActivityAttributes>.activities
        guard !activities.isEmpty else {
            isActive = false
            return
        }
        let updatedContent = content(for: contentState(
            for: observation,
            phoneHeadingDegrees: phoneHeadingDegrees,
            linkQuality: linkQuality
        ))
        for activity in activities {
            await activity.update(updatedContent)
        }
        isActive = true
    }

    func stop() async {
        let finalState = SatelliteActivityAttributes.ContentState(
            satelliteName: "Tracking ended",
            azimuthDegrees: 0,
            elevationDegrees: 0,
            compassPoint: "—",
            phoneHeadingDegrees: nil,
            relativeBearingDegrees: nil,
            linkQualityScore: nil,
            linkQualityGrade: nil,
            linkLatencyMilliseconds: nil,
            linkSuccessRatePercent: nil,
            linkPathLabel: nil,
            hasCandidate: false,
            updatedAt: .now
        )
        for activity in Activity<SatelliteActivityAttributes>.activities {
            await activity.end(content(for: finalState), dismissalPolicy: .immediate)
        }
        isActive = false
        errorMessage = nil
    }

    private func content(for state: SatelliteActivityAttributes.ContentState) -> ActivityContent<SatelliteActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: Date(timeIntervalSinceNow: 30),
            relevanceScore: state.hasCandidate ? 80 : 20
        )
    }

    private func contentState(
        for observation: SatelliteObservation?,
        phoneHeadingDegrees: Double?,
        linkQuality: LinkQualitySummary?
    ) -> SatelliteActivityAttributes.ContentState {
        let normalizedHeading = phoneHeadingDegrees.map(CoordinateTransforms.normalizedDegrees)
        guard let observation else {
            return SatelliteActivityAttributes.ContentState(
                satelliteName: "No DTC satellite above mask",
                azimuthDegrees: 0,
                elevationDegrees: 0,
                compassPoint: "—",
                phoneHeadingDegrees: normalizedHeading,
                relativeBearingDegrees: nil,
                linkQualityScore: linkQuality.map { Int($0.score.rounded()) },
                linkQualityGrade: linkQuality?.grade.rawValue.uppercased(),
                linkLatencyMilliseconds: linkQuality?.medianTimeToFirstByteMilliseconds.map { Int($0.rounded()) },
                linkSuccessRatePercent: linkQuality.map { Int(($0.successRate * 100).rounded()) },
                linkPathLabel: linkPathLabel(linkQuality),
                hasCandidate: false,
                updatedAt: .now
            )
        }
        return SatelliteActivityAttributes.ContentState(
            satelliteName: observation.satellite.elements.name,
            azimuthDegrees: CoordinateTransforms.normalizedDegrees(observation.azimuthDegrees),
            elevationDegrees: observation.elevationDegrees,
            compassPoint: compassPoint(observation.azimuthDegrees),
            phoneHeadingDegrees: normalizedHeading,
            relativeBearingDegrees: normalizedHeading.map {
                signedRelativeBearing(from: $0, to: observation.azimuthDegrees)
            },
            linkQualityScore: linkQuality.map { Int($0.score.rounded()) },
            linkQualityGrade: linkQuality?.grade.rawValue.uppercased(),
            linkLatencyMilliseconds: linkQuality?.medianTimeToFirstByteMilliseconds.map { Int($0.rounded()) },
            linkSuccessRatePercent: linkQuality.map { Int(($0.successRate * 100).rounded()) },
            linkPathLabel: linkPathLabel(linkQuality),
            hasCandidate: true,
            updatedAt: observation.observedAt
        )
    }

    private func compassPoint(_ degrees: Double) -> String {
        let labels = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let normalized = CoordinateTransforms.normalizedDegrees(degrees)
        return labels[Int((normalized / 45).rounded()) % labels.count]
    }

    private func signedRelativeBearing(from phoneHeading: Double, to satelliteAzimuth: Double) -> Double {
        let clockwise = CoordinateTransforms.normalizedDegrees(satelliteAzimuth - phoneHeading)
        return clockwise > 180 ? clockwise - 360 : clockwise
    }

    private func linkPathLabel(_ summary: LinkQualitySummary?) -> String? {
        guard let summary else { return nil }
        if summary.diagnosticOverride { return "DIAGNOSTIC" }
        if summary.pathMode == .ultraConstrained { return "SATELLITE" }
        return summary.pathMode.rawValue.uppercased()
    }
}
