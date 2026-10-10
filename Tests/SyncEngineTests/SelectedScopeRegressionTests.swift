import Foundation
import XCTest
@testable import SyncAdapters
@testable import SyncContracts
@testable import SyncDomain
@testable import SyncEngine
@testable import SyncStore

final class SelectedScopeRegressionTests: XCTestCase {
    func testPartialSelectedPullDoesNotInferUnselectedListDeletion() async throws {
        let account = SyncAccount(provider: .eventKit, accountID: "device")
        let epoch = Date(timeIntervalSince1970: 1_700_000_000)
        let homeID = SyncID.deterministic(namespace: "eventKit:device:list:home")
        let home = CanonicalList(id: homeID, name: "Home", createdAt: epoch, updatedAt: epoch)
        let base = SelectedScopeTestAdapter(
            account: account,
            changes: RemoteChanges(
                changes: [
                    .list(RemoteList(remoteID: "work", name: "Work", updatedAt: epoch)),
                    .list(RemoteList(remoteID: "home", name: "Home", updatedAt: epoch))
                ],
                nextCursor: "remote-2",
                serverNow: epoch,
                isFullSnapshot: true
            )
        )
        let scoped = SelectedListsSyncAdapter(
            base: base,
            scope: SelectedListScope(selectedRemoteListIDs: ["work"])
        )
        let stateStore = InMemorySyncStateStore(state: SyncState(
            lists: [home],
            listMappings: [ListMapping(account: account, canonicalListID: homeID, remoteListID: "home", lastSeenAt: epoch)],
            listReplicas: [ListReplica(
                account: account,
                canonicalListID: homeID,
                remoteListID: "home",
                lastSyncedList: home,
                lastSyncedAt: epoch,
                remoteRevision: "home-1"
            )],
            cursors: [SyncCursor(account: account, value: "remote-1", updatedAt: epoch)]
        ))
        let engine = SyncEngine(account: account, adapter: scoped, stateStore: stateStore, now: { epoch })

        let report = try await engine.sync()
        let state = try await stateStore.load()

        XCTAssertTrue(report.committed)
        XCTAssertNotNil(state.list(id: homeID), "The unselected list must remain present.")
        XCTAssertNil(state.list(id: homeID)?.deletedAt, "Partial selected-list pulls must not infer deletion.")
        XCTAssertEqual(state.cursor(for: account)?.value, "remote-1", "The global cursor must not advance past deferred changes.")
        XCTAssertEqual(report.deletedCount, 0)
    }
}

private actor SelectedScopeTestAdapter: ExternalSyncAdapter {
    nonisolated let account: SyncAccount
    nonisolated let capabilities: Set<AdapterCapability> = []
    private let changes: RemoteChanges

    init(account: SyncAccount, changes: RemoteChanges) {
        self.account = account
        self.changes = changes
    }

    func pullChanges(since cursor: String?) async throws -> RemoteChanges { changes }

    func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        PushResult(accepted: mutations.count, nextCursor: cursor, serverNow: Date())
    }
}
