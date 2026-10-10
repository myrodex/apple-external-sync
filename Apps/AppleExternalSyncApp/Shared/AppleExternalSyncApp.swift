import SwiftUI
import ExternalSync
import SyncAppSupport
#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks
#endif

@main
struct AppleExternalSyncApp: App {
    @StateObject private var model: SyncAppViewModel
    private let lifecycleHandler: (any SyncAppLifecycleHandling)?

    init() {
        let coordinator: any SyncAppCoordinator
        var lifecycleHandler: (any SyncAppLifecycleHandling)?
        do {
            let live = try ProductionSyncCoordinator()
            coordinator = live
            lifecycleHandler = live
#if canImport(BackgroundTasks) && os(iOS)
            let scheduler = IOSBackgroundSyncScheduler(
                identifier: "com.myrodex.appleexternalsync.refresh",
                operation: { [weak live] in
                    _ = await live?.runBackgroundSync()
                }
            )
            try? scheduler.register()
            try? scheduler.schedule(after: 15 * 60)
#endif
        } catch {
            let unavailable = UnavailableSyncCoordinator(error: error)
            coordinator = unavailable
            lifecycleHandler = nil
        }
        self.lifecycleHandler = lifecycleHandler
        _model = StateObject(wrappedValue: SyncAppViewModel(coordinator: coordinator))
    }

    var body: some Scene {
        WindowGroup {
            LifecycleRootView(model: model, lifecycleHandler: lifecycleHandler)
                .frame(minWidth: 420, minHeight: 560)
        }
#if os(macOS)
        Settings {
            SyncSettingsView(model: model)
        }
#endif
    }
}

private struct LifecycleRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject var model: SyncAppViewModel
    let lifecycleHandler: (any SyncAppLifecycleHandling)?

    var body: some View {
        SyncAppRootView(model: model)
            .onChange(of: scenePhase) { phase in
                guard let lifecycleHandler else { return }
                switch phase {
                case .active:
                    Task { await lifecycleHandler.applicationWillEnterForeground() }
                case .background:
                    lifecycleHandler.applicationDidEnterBackground()
                case .inactive:
                    break
                @unknown default:
                    break
                }
            }
    }
}

private actor UnavailableSyncCoordinator: SyncAppCoordinator {
    private let error: SyncErrorState
    private let failure: StartupFailure

    init(error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        self.failure = StartupFailure(message: message)
        self.error = SyncErrorState(
            phase: .persistence,
            message: message,
            recoveryAction: "Quit and relaunch the app. If the error persists, check the app's Application Support folder permissions."
        )
    }

    func loadSnapshot() async throws -> SyncAppSnapshot {
        SyncAppSnapshot(
            permissions: [SyncPermission(kind: .reminders, explanation: "Reminders access is required to use sync.")],
            lastError: error
        )
    }

    func requestPermissions() async throws -> SyncAppSnapshot { throw failure }
    func connect(provider: SyncProviderChoice) async throws -> SyncAppSnapshot { throw failure }
    func beginOAuthAuthorization(provider: SyncProviderChoice) async throws -> SyncOAuthAuthorization { throw failure }
    func completeOAuthAuthorization(callbackURL: URL) async throws -> SyncAppSnapshot { throw failure }
    func disconnect() async throws -> SyncAppSnapshot { throw failure }
    func updateListSelection(_ selectedListIDs: Set<String>) async throws -> SyncAppSnapshot { throw failure }
    func syncNow() async throws -> SyncAppSnapshot { throw failure }
    func resolveConflict(id: String, resolution: SyncConflictResolution) async throws -> SyncAppSnapshot { throw failure }
}

private struct StartupFailure: Error, LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}
