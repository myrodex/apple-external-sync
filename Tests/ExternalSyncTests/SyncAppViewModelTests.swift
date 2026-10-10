import XCTest
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
