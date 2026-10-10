import Foundation
import XCTest
@testable import ExternalSync
@testable import SyncAdapters
@testable import SyncDomain
@testable import SyncStore

#if canImport(EventKit)
@MainActor
final class DurableAuditTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testProductionCoordinatorRestoresFailedRunAfterRelaunch() async throws {
        let suiteName = "DurableAuditTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).sqlite")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let account = SyncAccount(provider: .eventKit, accountID: "device-audit")
        defaults.set(SyncProviderChoice.appleReminders.rawValue, forKey: "provider")
        defaults.set(account.accountID, forKey: "eventkit-account-id")
        let store = try SQLiteLocalStore(url: databaseURL)
        var failed = SyncRun(account: account, startedAt: epoch)
        failed.finishedAt = epoch.addingTimeInterval(2)
        failed.status = .failed
        failed.errorMessage = "Provider transport failed: offline"
        try await store.upsertSyncRun(failed)

        let failureDate = epoch.addingTimeInterval(3)
        let clock = failureDate
        let coordinator = try ProductionSyncCoordinator(
            databaseURL: databaseURL,
            defaults: defaults,
            pendingAuthorizationStore: InMemoryOAuthPendingAuthorizationStore(),
            now: { clock }
        )
        let snapshot = try await coordinator.loadSnapshot()

        XCTAssertEqual(snapshot.lastSync?.id, failed.id)
        XCTAssertEqual(snapshot.lastSync?.status, AppSyncRunStatus.failed)
        XCTAssertEqual(snapshot.lastSync?.errorMessage, failed.errorMessage)
        XCTAssertEqual(snapshot.lastError?.message, failed.errorMessage)
        XCTAssertEqual(snapshot.lastError?.occurredAt, failed.finishedAt)
    }

    func testInterruptedRunningAuditIsReconciledToVisibleFailure() async throws {
        let suiteName = "DurableAuditTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("audit-\(UUID().uuidString).sqlite")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let account = SyncAccount(provider: .eventKit, accountID: "interrupted-device")
        defaults.set(SyncProviderChoice.appleReminders.rawValue, forKey: "provider")
        defaults.set(account.accountID, forKey: "eventkit-account-id")
        let store = try SQLiteLocalStore(url: databaseURL)
        let running = SyncRun(account: account, startedAt: epoch)
        try await store.upsertSyncRun(running)

        let failureDate = epoch.addingTimeInterval(3)
        let clock = failureDate
        let coordinator = try ProductionSyncCoordinator(
            databaseURL: databaseURL,
            defaults: defaults,
            pendingAuthorizationStore: InMemoryOAuthPendingAuthorizationStore(),
            now: { clock }
        )
        let snapshot = try await coordinator.loadSnapshot()
        let persisted = try await store.syncRuns(account: account, limit: 1)

        XCTAssertEqual(snapshot.lastSync?.status, AppSyncRunStatus.failed)
        XCTAssertEqual(snapshot.lastError?.message, "The previous sync stopped before it completed.")
        XCTAssertEqual(persisted.first?.status, .failed)
        XCTAssertEqual(persisted.first?.finishedAt, epoch.addingTimeInterval(3))
    }
}
#endif
