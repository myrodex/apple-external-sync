import XCTest
import SyncDomain
@testable import ExternalSync

@MainActor
final class SyncAppViewModelTests: XCTestCase {
    func testOnboardingConnectsThenRequiresExplicitListSelection() async {
        let coordinator = PreviewSyncCoordinator()
        let model = SyncAppViewModel(coordinator: coordinator, loginItemManager: UnsupportedLoginItemManager())

        await model.loadSnapshot()
        XCTAssertEqual(model.phase, .onboarding)

        model.requestPermissions()
        await waitUntilIdle(model)
        XCTAssertEqual(model.phase, .connectionSetup)

        model.connect(provider: .appleReminders)
        await waitUntilIdle(model)
        XCTAssertEqual(model.phase, .listSelection)
        XCTAssertTrue(model.snapshot.selectedListIDs.isEmpty)

        model.setListSelected(true, listID: "work")
        await waitUntilIdle(model)
        XCTAssertEqual(model.snapshot.selectedListIDs, ["work"])
        XCTAssertEqual(model.phase, .ready)
    }

    func testSyncRequiresSelectionAndSurfacesError() async {
        let coordinator = PreviewSyncCoordinator()
        let model = SyncAppViewModel(coordinator: coordinator, loginItemManager: UnsupportedLoginItemManager())

        await model.loadSnapshot()
        model.requestPermissions()
        await waitUntilIdle(model)
        model.connect(provider: .appleReminders)
        await waitUntilIdle(model)
        model.syncNow()
        await waitUntilIdle(model)

        XCTAssertEqual(model.phase, .listSelection)
        XCTAssertEqual(model.operationError?.phase, .listSelection)
    }

    func testOptionalNotificationPermissionDoesNotBlockSyncSetup() async {
        let snapshot = SyncAppSnapshot(
            connection: SyncConnectionState(),
            permissions: [
                SyncPermission(kind: .reminders, status: .granted, explanation: "Required for lists."),
                SyncPermission(kind: .notifications, status: .denied, explanation: "Optional sync alerts.")
            ]
        )
        let model = SyncAppViewModel(
            coordinator: PreviewSyncCoordinator(snapshot: snapshot),
            loginItemManager: UnsupportedLoginItemManager(),
            initialSnapshot: snapshot
        )

        XCTAssertEqual(model.phase, .connectionSetup)
        XCTAssertEqual(model.snapshot.pendingPermissionCount, 0)
    }

    func testSelectedListsCanBeSyncedAndLastRunIsShown() async {
        let snapshot = SyncAppSnapshot(
            connection: SyncConnectionState(provider: .appleReminders, status: .connected),
            permissions: [SyncPermission(kind: .reminders, status: .granted, explanation: "Required.")],
            availableLists: [SyncListOption(id: "opaque-provider-id", name: "Work")],
            selectedListIDs: ["opaque-provider-id"]
        )
        let model = SyncAppViewModel(
            coordinator: PreviewSyncCoordinator(snapshot: snapshot),
            loginItemManager: UnsupportedLoginItemManager(),
            initialSnapshot: snapshot
        )

        model.syncNow()
        await waitUntilIdle(model)

        XCTAssertEqual(model.phase, .ready)
        XCTAssertEqual(model.snapshot.lastSync?.status, .succeeded)
        XCTAssertEqual(model.snapshot.lastSync?.scannedCount, 1)
    }

    func testOAuthAuthorizationCallbackUpdatesConnectionState() async {
        let coordinator = OAuthFlowCoordinator()
        let model = SyncAppViewModel(coordinator: coordinator, loginItemManager: UnsupportedLoginItemManager())

        model.beginOAuthAuthorization(provider: .googleTasks)
        await waitUntilIdle(model)
        XCTAssertEqual(model.authorizationRequest?.provider, .googleTasks)

        model.completeOAuthAuthorization(callbackURL: URL(string: "myrodex://oauth/callback?code=verified")!)
        await waitUntilIdle(model)

        XCTAssertNil(model.authorizationRequest)
        XCTAssertEqual(model.snapshot.connection.status, .connected)
        XCTAssertEqual(model.snapshot.connection.accountName, "OAuth account")
        XCTAssertEqual(model.phase, .listSelection)
    }

    func testLoginItemApprovalExposesSettingsAction() {
        let manager = ApprovalLoginItemManager()
        let model = SyncAppViewModel(coordinator: PreviewSyncCoordinator(), loginItemManager: manager)

        XCTAssertTrue(model.automaticSyncSupported)
        XCTAssertTrue(model.automaticSyncRequiresApproval)
        XCTAssertFalse(model.automaticSyncEnabled)

        model.openAutomaticSyncSettings()

        XCTAssertTrue(manager.openedSettings)
    }

    func testLoginItemFailureDoesNotChangeReportedState() {
        let manager = FailingLoginItemManager()
        let model = SyncAppViewModel(coordinator: PreviewSyncCoordinator(), loginItemManager: manager)

        model.setAutomaticSyncEnabled(true)

        XCTAssertFalse(model.automaticSyncEnabled)
        XCTAssertNotNil(model.loginItemError)
    }

    private func waitUntilIdle(_ model: SyncAppViewModel) async {
        for _ in 0..<100 {
            if !model.isUpdating { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Timed out waiting for app operation")
    }
}

@MainActor
private final class FailingLoginItemManager: LoginItemManaging {
    let isSupported = true
    private(set) var isEnabled = false

    func setEnabled(_ enabled: Bool) throws {
        throw NSError(domain: "tests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unable to register login item"])
    }
}

@MainActor
private final class ApprovalLoginItemManager: LoginItemManaging {
    let isSupported = true
    let requiresApproval = true
    private(set) var isEnabled = false
    private(set) var openedSettings = false

    func setEnabled(_ enabled: Bool) throws {
        throw NSError(domain: "tests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Approval is required"])
    }

    func openSystemSettings() {
        openedSettings = true
    }
}

private actor OAuthFlowCoordinator: SyncAppCoordinator {
    private var snapshot: SyncAppSnapshot

    init() {
        snapshot = SyncAppSnapshot(
            connection: SyncConnectionState(provider: .googleTasks, status: .authenticationRequired),
            permissions: [SyncPermission(kind: .reminders, status: .granted, explanation: "Required.")],
            availableLists: []
        )
    }

    func loadSnapshot() async throws -> SyncAppSnapshot { snapshot }

    func requestPermissions() async throws -> SyncAppSnapshot { snapshot }

    func connect(provider: SyncProviderChoice) async throws -> SyncAppSnapshot {
        snapshot.connection = SyncConnectionState(provider: provider, status: .connected, accountName: provider.title)
        return snapshot
    }

    func beginOAuthAuthorization(provider: SyncProviderChoice) async throws -> SyncOAuthAuthorization {
        SyncOAuthAuthorization(provider: provider, url: URL(string: "https://example.test/authorize")!)
    }

    func completeOAuthAuthorization(callbackURL: URL) async throws -> SyncAppSnapshot {
        XCTAssertEqual(callbackURL.scheme, "myrodex")
        snapshot.connection = SyncConnectionState(
            provider: .googleTasks,
            status: .connected,
            accountName: "OAuth account"
        )
        snapshot.availableLists = [SyncListOption(id: "remote-work", name: "Work")]
        return snapshot
    }

    func disconnect() async throws -> SyncAppSnapshot {
        snapshot.connection = SyncConnectionState()
        return snapshot
    }

    func updateListSelection(_ selectedListIDs: Set<String>) async throws -> SyncAppSnapshot {
        snapshot.selectedListIDs = selectedListIDs
        return snapshot
    }

    func applyLocalChange(_ change: LocalChange) async throws -> SyncAppSnapshot { snapshot }

    func syncNow() async throws -> SyncAppSnapshot { snapshot }

    func resolveConflict(id: String, resolution: SyncConflictResolution) async throws -> SyncAppSnapshot { snapshot }
}
