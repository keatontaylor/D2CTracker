import SwiftUI

@main
struct D2CTrackerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.connectivity)
                .environmentObject(model.location)
                .environmentObject(model.linkQuality)
                .environmentObject(model.terrain)
                .task { await model.start() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { Task { await model.sceneBecameActive() } }
                    if phase == .background {
                        model.sceneEnteredBackground()
                        BackgroundRefreshScheduler.schedule()
                    }
                }
        }
        .backgroundTask(.appRefresh(BackgroundRefreshScheduler.identifier)) {
            await model.backgroundRefresh()
        }
    }
}
