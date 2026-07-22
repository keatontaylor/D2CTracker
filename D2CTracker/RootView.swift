import SwiftUI
import D2CTrackerCore

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selectedTab: AppTab

    init() {
        var initial: AppTab = .tracking
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let flag = arguments.firstIndex(of: "--initial-tab"), arguments.indices.contains(flag + 1) {
            initial = AppTab(rawValue: arguments[flag + 1]) ?? .tracking
        }
        #endif
        _selectedTab = State(initialValue: initial)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack { TrackingView() }
                .tabItem { Label("Tracking", systemImage: "antenna.radiowaves.left.and.right") }
                .tag(AppTab.tracking)

            NavigationStack { SkyScreen() }
                .tabItem { Label("Sky", systemImage: "scope") }
                .tag(AppTab.sky)

            NavigationStack { GlobeScreen() }
                .tabItem { Label("Globe", systemImage: "globe.americas.fill") }
                .tag(AppTab.globe)

            NavigationStack { MoreView() }
                .tabItem { Label("More", systemImage: "slider.horizontal.3") }
                .tag(AppTab.more)
        }
        .tint(.cyan)
    }
}

private enum AppTab: String, Hashable {
    case tracking, sky, globe, more
}

struct AppBackdrop: View {
    var body: some View {
        LinearGradient(
            colors: [Color(red: 0.025, green: 0.055, blue: 0.10), Color(red: 0.02, green: 0.02, blue: 0.045)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct GlassCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 1)
            }
    }
}

enum InputStatusLevel: Sendable, Equatable {
    case current
    case attention
    case stale
    case unavailable

    var color: Color {
        switch self {
        case .current: .mint
        case .attention: .yellow
        case .stale: .orange
        case .unavailable: .secondary
        }
    }
}

struct InputStatus: Identifiable, Sendable {
    let id: String
    let label: String
    let systemImage: String
    let level: InputStatusLevel
    let detail: String
}

struct InputStatusBadges: View {
    let statuses: [InputStatus]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(statuses) { status in
                    Label(status.label, systemImage: status.systemImage)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(status.level.color)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(status.level.color.opacity(0.11), in: Capsule())
                        .overlay {
                            Capsule().stroke(status.level.color.opacity(0.22), lineWidth: 1)
                        }
                        .accessibilityLabel("\(status.label). \(status.detail)")
                }
            }
        }
    }
}

extension ConnectivityMode {
    var displayName: String {
        switch self {
        case .wifi: "Wi-Fi"
        case .wiredEthernet: "Ethernet"
        case .terrestrialCellular: "Terrestrial cellular"
        case .constrained: "Constrained"
        case .ultraConstrained: "Ultra-constrained"
        case .offline: "Offline"
        case .unknown: "Checking network"
        }
    }

    var symbol: String {
        switch self {
        case .wifi: "wifi"
        case .wiredEthernet: "network"
        case .terrestrialCellular: "cellularbars"
        case .constrained, .ultraConstrained: "tortoise.fill"
        case .offline: "wifi.slash"
        case .unknown: "questionmark.circle"
        }
    }
}
