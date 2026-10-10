import Foundation
import XCTest
@testable import SyncAdapters
import SyncContracts
import SyncDomain

final class ScopedSyncAdapterTests: XCTestCase {
    func testPullHidesUnselectedDataWithoutClaimingAbsenceMeansDeletion() async throws {
        let account = SyncAccount(provider: .googleTasks, accountID: "account")
        let base = ScopedFakeAdapter(account: account, changes: RemoteChanges(
            changes: [
                .list(RemoteList(remoteID: "work", name: "Work")),
                .list(RemoteList(remoteID: "home", name: "Home")),
                .task(RemoteTask(remoteID: "t1", title: "Work task", remoteListID: "work")),
                .task(RemoteTask(remoteID: "t2", title: "Home task", remoteListID: "home"))
            ],
            nextCursor: "cursor-1",
            serverNow: Date(),
            isFullSnapshot: true
        ))
        let scope = SelectedListScope(selectedRemoteListIDs: ["work"])
        let adapter = SelectedListsSyncAdapter(base: base, scope: scope)

        let result = try await adapter.pullChanges(since: nil)

        XCTAssertFalse(result.isFullSnapshot)
        XCTAssertEqual(result.changes.count, 2)
        XCTAssertFalse(result.changes.contains { change in
            switch change {
            case .list(let list): return list.remoteID == "home"
            case .task(let task): return task.remoteID == "t2"
            }
        })
    }

    func testPushRejectsOutOfScopeMutationsSoEngineRetainsThemForLater() async throws {
        let account = SyncAccount(provider: .googleTasks, accountID: "account")
        let base = ScopedFakeAdapter(account: account, changes: RemoteChanges(changes: [], nextCursor: nil, serverNow: Date()))
        let adapter = SelectedListsSyncAdapter(base: base, scope: SelectedListScope(selectedRemoteListIDs: ["work"]))
        let selectedID = SyncID()
        let unselectedID = SyncID()
        let mutations: [RemoteMutation] = [
            .upsertTask(canonicalTaskID: selectedID, task: RemoteTask(remoteID: "t1", title: "Selected", remoteListID: "work")),
            .upsertTask(canonicalTaskID: unselectedID, task: RemoteTask(remoteID: "t2", title: "Not selected", remoteListID: "home"))
        ]

        let result = try await adapter.push(mutations, cursor: nil)
        let pushed = await base.pushedMutations()

        XCTAssertEqual(pushed, [mutations[0]])
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(result.rejected.map(\.mutation), [mutations[1]])
        XCTAssertTrue(result.rejected[0].reason.contains("not selected"))
    }
}

private actor ScopedFakeAdapter: ExternalSyncAdapter {
    nonisolated let account: SyncAccount
    nonisolated let capabilities: Set<AdapterCapability> = []
    private let changes: RemoteChanges
    private(set) var pushes: [[RemoteMutation]] = []

    init(account: SyncAccount, changes: RemoteChanges) {
        self.account = account
        self.changes = changes
    }

    func pullChanges(since cursor: String?) async throws -> RemoteChanges { changes }

    func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        pushes.append(mutations)
        return PushResult(accepted: mutations.count, nextCursor: cursor, serverNow: Date())
    }

    func pushedMutations() -> [RemoteMutation] { pushes.flatMap { $0 } }
}
