import ActivityKit
import SwiftUI
import D2CTrackerCore
import WidgetKit

@main
struct SatelliteWidgets: WidgetBundle {
    var body: some Widget {
        SatelliteLiveActivityWidget()
    }
}

struct SatelliteLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SatelliteActivityAttributes.self) { context in
            SatelliteLockScreenView(state: context.state)
                .activityBackgroundTint(Color(red: 0.015, green: 0.035, blue: 0.075))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    DirectionArrow(
                        degrees: context.state.directionDegrees,
                        size: 48,
                        isRelative: context.state.hasRelativeDirection
                    )
                    .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(context.state.guidanceAmount)
                            .font(.title3.weight(.heavy).monospacedDigit())
                            .foregroundStyle(.white)
                        Text(context.state.guidanceDirection)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.mint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .padding(.trailing, 3)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ExpandedSatelliteDetails(state: context.state)
                }
            } compactLeading: {
                DirectionArrow(
                    degrees: context.state.directionDegrees,
                    size: 22,
                    isRelative: context.state.hasRelativeDirection
                )
            } compactTrailing: {
                Text(context.state.turnText)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.cyan)
            } minimal: {
                DirectionArrow(
                    degrees: context.state.directionDegrees,
                    size: 20,
                    isRelative: context.state.hasRelativeDirection
                )
            }
            .keylineTint(.cyan)
        }
    }
}

private struct SatelliteLockScreenView: View {
    let state: SatelliteActivityAttributes.ContentState

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.015, green: 0.045, blue: 0.095),
                    Color(red: 0.01, green: 0.025, blue: 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 10) {
                HStack(spacing: 7) {
                    Image(systemName: "satellite.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.cyan)
                    Text(state.satelliteName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    LiveBadge(updatedAt: state.updatedAt)
                }

                HStack(spacing: 13) {
                    DirectionArrow(
                        degrees: state.directionDegrees,
                        size: 60,
                        isRelative: state.hasRelativeDirection
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(state.guidanceKicker)
                            .font(.system(size: 8, weight: .black))
                            .foregroundStyle(.secondary)
                        Text(state.guidanceText)
                            .font(.title3.weight(.heavy).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(state.hasRelativeDirection ? "Aim the top edge of your phone" : "Bearing is measured from true north")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)
                }

                HStack(spacing: 7) {
                    SatelliteMetric(label: "PHONE", value: state.phoneHeadingValue, tint: .mint)
                    SatelliteMetric(label: "SATELLITE", value: state.satelliteBearingValue, tint: .cyan)
                    SatelliteMetric(label: "ELEVATION", value: state.elevationValue, tint: .orange)
                    if state.linkQualityScore != nil {
                        SatelliteMetric(label: state.linkQualityLabel, value: state.linkQualityValue, tint: state.linkQualityTint)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }
}

private struct ExpandedSatelliteDetails: View {
    let state: SatelliteActivityAttributes.ContentState

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: "satellite.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 0) {
                    Text(state.satelliteName)
                        .font(.caption.weight(.bold))
                        .lineLimit(1)
                    Text(state.guidanceKicker)
                        .font(.system(size: 8, weight: .black))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                Spacer(minLength: 6)
                Text(state.updatedAt, style: .relative)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                SatelliteMetric(label: "PHONE", value: state.phoneHeadingValue, tint: .mint)
                SatelliteMetric(label: "SAT", value: state.satelliteBearingValue, tint: .cyan)
                SatelliteMetric(label: "ELEV", value: state.elevationValue, tint: .orange)
                if state.linkQualityScore != nil {
                    SatelliteMetric(label: state.linkQualityLabel, value: state.linkQualityValue, tint: state.linkQualityTint)
                }
            }
        }
        .padding(.horizontal, 3)
        .padding(.top, 6)
    }
}

private struct LiveBadge: View {
    let updatedAt: Date

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(.mint)
                .frame(width: 6, height: 6)
            Text("LIVE")
                .font(.system(size: 8, weight: .black))
                .foregroundStyle(.mint)
            Text(updatedAt, style: .relative)
                .font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(.white.opacity(0.06), in: Capsule())
    }
}

private struct SatelliteMetric: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(spacing: 1) {
            Text(label)
                .font(.system(size: 7, weight: .black))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 5)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.white.opacity(0.07), lineWidth: 0.5)
        }
    }
}

private struct DirectionArrow: View {
    let degrees: Double
    let size: CGFloat
    let isRelative: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.02, green: 0.09, blue: 0.15))
            Circle()
                .stroke(
                    AngularGradient(
                        colors: [.cyan.opacity(0.35), .mint.opacity(0.9), .cyan.opacity(0.35)],
                        center: .center
                    ),
                    lineWidth: size >= 38 ? 1.5 : 1
                )
            if size >= 38 {
                Text(isRelative ? "PHONE" : "N")
                    .font(.system(size: size * 0.105, weight: .black))
                    .foregroundStyle(.white.opacity(0.55))
                    .offset(y: -size * 0.31)
            }
            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: max(2.5, size * 0.07), height: max(2.5, size * 0.07))
            Image(systemName: "location.north.fill")
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(.mint)
                .rotationEffect(.degrees(degrees))
                .animation(nil, value: degrees)
        }
        .frame(width: size, height: size)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityLabel(
            isRelative
                ? "Satellite direction \(Int(degrees.rounded())) degrees clockwise from the phone heading"
                : "Direction \(Int(degrees.rounded())) degrees clockwise from north"
        )
    }
}

private extension SatelliteActivityAttributes.ContentState {
    var hasRelativeDirection: Bool {
        hasCandidate && phoneHeadingDegrees != nil && relativeBearingDegrees != nil
    }

    var directionDegrees: Double {
        relativeBearingDegrees ?? azimuthDegrees
    }

    var signedTurnDegrees: Double? {
        guard hasRelativeDirection, let relativeBearingDegrees else { return nil }
        return relativeBearingDegrees
    }

    var turnText: String {
        guard hasCandidate else { return "—" }
        guard let signedTurnDegrees else {
            return "\(Int(azimuthDegrees.rounded()))°"
        }
        let amount = Int(abs(signedTurnDegrees).rounded())
        if amount <= 3 { return "AHEAD" }
        return "\(amount)° \(signedTurnDegrees > 0 ? "R" : "L")"
    }

    var guidanceText: String {
        guard hasCandidate else { return "No satellite above mask" }
        guard let signedTurnDegrees else {
            return "Point \(Int(azimuthDegrees.rounded()))° \(compassPoint)"
        }
        let amount = Int(abs(signedTurnDegrees).rounded())
        if amount <= 3 { return "Satellite straight ahead" }
        return "Turn \(amount)° \(signedTurnDegrees > 0 ? "right" : "left")"
    }

    var guidanceKicker: String {
        hasRelativeDirection ? "RELATIVE TO PHONE" : "TRUE-NORTH BEARING"
    }

    var guidanceAmount: String {
        guard hasCandidate else { return "—" }
        guard let signedTurnDegrees else { return "\(Int(azimuthDegrees.rounded()))°" }
        let amount = Int(abs(signedTurnDegrees).rounded())
        return amount <= 3 ? "ON TARGET" : "\(amount)°"
    }

    var guidanceDirection: String {
        guard hasCandidate else { return "NO CANDIDATE" }
        guard let signedTurnDegrees else { return compassPoint }
        let amount = Int(abs(signedTurnDegrees).rounded())
        if amount <= 3 { return "STRAIGHT AHEAD" }
        return signedTurnDegrees > 0 ? "TURN RIGHT" : "TURN LEFT"
    }

    var phoneHeadingText: String {
        guard let phoneHeadingDegrees else { return "Phone heading unavailable" }
        return "Phone \(Int(phoneHeadingDegrees.rounded()))°"
    }

    var satelliteBearingText: String {
        guard hasCandidate else { return "No candidate" }
        return "Sat \(Int(azimuthDegrees.rounded()))° \(compassPoint)"
    }

    var phoneHeadingValue: String {
        guard let phoneHeadingDegrees else { return "—" }
        return "\(Int(phoneHeadingDegrees.rounded()))°"
    }

    var satelliteBearingValue: String {
        guard hasCandidate else { return "—" }
        return "\(Int(azimuthDegrees.rounded()))° \(compassPoint)"
    }

    var elevationValue: String {
        guard hasCandidate else { return "—" }
        return "\(Int(elevationDegrees.rounded()))°"
    }

    var linkQualityValue: String {
        guard let linkQualityScore else { return "—" }
        return "\(linkQualityScore)"
    }

    var linkQualityLabel: String {
        guard let linkQualityGrade else { return "LINK" }
        return "LINK · \(linkQualityGrade)"
    }

    var linkQualityTint: Color {
        guard let linkQualityScore else { return .secondary }
        switch linkQualityScore {
        case 85...: return .mint
        case 70...: return .green
        case 50...: return .yellow
        case 25...: return .orange
        default: return .red
        }
    }
}
