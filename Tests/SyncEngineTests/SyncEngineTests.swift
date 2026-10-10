import Foundation
import XCTest

private let testEpoch = Date(timeIntervalSince1970: 1_700_000_000)
@testable import SyncContracts
@testable import SyncDomain
@testable import SyncEngine
@testable import SyncStore

final class SyncEngineTests: XCTestCase {

    func testInitialPullPersistsCanonicalStateAndCursorWithoutEchoPush() async throws {
        let account = SyncAccount(provider: .eventKit, accountID: "device")
        let listID = SyncID.deterministic(namespace: "eventKit:device:list:work")
        let taskID = SyncID.deterministic(namespace: "eventKit:device:task:t1")
        let adapter = ScriptedAdapter(account: account, pulls: [RemoteChanges(
            changes: [
                .list(RemoteList(remoteID: "work", name: "Work", updatedAt: testEpoch, revision: "l1")),
                .task(RemoteTask(remoteID: "t1", title: "Ship", remoteListID: "work", updatedAt: testEpoch, revision: "t1"))
            ],
            nextCursor: "cursor-1",
            serverNow: testEpoch
        )])
        let store = InMemorySyncStateStore()
        let engine = SyncEngine(adapter: adapter, stateStore: store, now: { testEpoch })

        let report = try await engine.sync()
        let state = try await store.load()

        XCTAssertEqual(report.pulledCount, 2)
        XCTAssertEqual(report.pushedCount, 0)
        XCTAssertEqual(state.cursor(for: account)?.value, "cursor-1")
        XCTAssertEqual(state.list(id: listID)?.name, "Work")
        XCTAssertEqual(state.task(id: taskID)?.title, "Ship")
        let pushes = await adapter.recordedPushes()
        XCTAssertTrue(pushes.isEmpty)
    }

    func testIndependentLocalAndRemoteEditsMergeAndPushDeterministically() async throws {
        let account = SyncAccount(provider: .genericREST, accountID: "account")
        let taskID = SyncID.deterministic(namespace: "genericREST:account:task:t1")
        let initial = RemoteTask(remoteID: "t1", title: "Base", notes: "Base notes", updatedAt: testEpoch, revision: "r1")
        let remoteEdit = RemoteTask(remoteID: "t1", title: "Base", notes: "Remote notes", updatedAt: testEpoch.addingTimeInterval(1), revision: "r2")
        let adapter = ScriptedAdapter(account: account, pulls: [
            RemoteChanges(changes: [.task(initial)], nextCursor: "r1", serverNow: testEpoch),
            RemoteChanges(changes: [.task(remoteEdit)], nextCursor: "r2", serverNow: testEpoch.addingTimeInterval(1))
        ], pushResults: [PushResult(accepted: 1, mappings: [RemoteIDMapping(canonicalTaskID: taskID, remoteID: "t1", revision: "r2")], nextCursor: "r2", serverNow: testEpoch.addingTimeInterval(1))])
        let store = InMemorySyncStateStore()
        let engine = SyncEngine(adapter: adapter, stateStore: store, now: { testEpoch.addingTimeInterval(2) })

        _ = try await engine.sync()
        let initialState = try await store.load()
        var local = try XCTUnwrap(initialState.task(id: taskID))
        local.title = "Local title"
        local.updatedAt = testEpoch.addingTimeInterval(1)
        try await engine.applyLocalChange(.upsertTask(local))

        let report = try await engine.sync()
        let state = try await store.load()
        let merged = try XCTUnwrap(state.task(id: taskID))

        XCTAssertEqual(report.conflictCount, 0)
        XCTAssertEqual(merged.title, "Local title")
        XCTAssertEqual(merged.notes, "Remote notes")
        let pushedBatches = await adapter.recordedPushes()
        XCTAssertEqual(pushedBatches.count, 1)
        guard case .upsertTask(_, let pushed) = try XCTUnwrap(pushedBatches.last?.first) else {
            return XCTFail("Expected merged task upsert")
        }
        XCTAssertEqual(pushed.title, "Local title")
        XCTAssertEqual(pushed.notes, "Remote notes")
    }

    func testConcurrentSameFieldEditQueuesConflictAndDoesNotPushLocalValue() async throws {
        let account = SyncAccount(provider: .genericREST, accountID: "account")
        let taskID = SyncID.deterministic(namespace: "genericREST:account:task:t1")
        let adapter = ScriptedAdapter(account: account, pulls: [
            RemoteChanges(changes: [.task(RemoteTask(remoteID: "t1", title: "Base", updatedAt: testEpoch, revision: "r1"))], nextCursor: "r1", serverNow: testEpoch),
            RemoteChanges(changes: [.task(RemoteTask(remoteID: "t1", title: "Remote", updatedAt: testEpoch.addingTimeInterval(1), revision: "r2"))], nextCursor: "r2", serverNow: testEpoch.addingTimeInterval(1))
        ])
        let store = InMemorySyncStateStore()
        let engine = SyncEngine(adapter: adapter, stateStore: store, now: { testEpoch.addingTimeInterval(2) })

        _ = try await engine.sync()
        let initialState = try await store.load()
        var local = try XCTUnwrap(initialState.task(id: taskID))
        local.title = "Local"
        try await engine.applyLocalChange(.upsertTask(local))
        let report = try await engine.sync()

        let state = try await store.load()
        XCTAssertEqual(report.conflictCount, 1)
        XCTAssertEqual(state.conflicts.filter { $0.resolution == .pending }.count, 1)
        XCTAssertEqual(state.task(id: taskID)?.title, "Local")
        let pushes = await adapter.recordedPushes()
        XCTAssertTrue(pushes.isEmpty)
    }

    func testRejectedPushDoesNotAdvanceCursorAndIsRetried() async throws {
        let account = SyncAccount(provider: .genericREST, accountID: "account")
        let taskID = SyncID.deterministic(namespace: "genericREST:account:task:t1")
        let task = RemoteTask(remoteID: "t1", title: "Local", updatedAt: testEpoch, revision: "r1")
        let adapter = ScriptedAdapter(account: account, pulls: [
            RemoteChanges(changes: [], nextCursor: "r1", serverNow: testEpoch)
        ], pushResults: [
            PushResult(accepted: 0, rejected: [RejectedMutation(mutation: .upsertTask(canonicalTaskID: taskID, task: task), reason: "rate limited", retryable: true)], nextCursor: "r1", serverNow: testEpoch)
        ])
        let store = InMemorySyncStateStore(state: SyncState(
            tasks: [CanonicalTask(id: taskID, title: "Local", createdAt: testEpoch, updatedAt: testEpoch)],
            taskReplicas: [TaskReplica(externalID: ExternalTaskID(account: account, remoteTaskID: "t1"), canonicalTaskID: taskID, lastSyncedTask: CanonicalTask(id: taskID, title: "Base", createdAt: testEpoch, updatedAt: testEpoch), lastSyncedAt: testEpoch, remoteRevision: "r0")],
            cursors: [SyncCursor(account: account, value: "old", updatedAt: testEpoch)]
        ))
        let engine = SyncEngine(adapter: adapter, stateStore: store, now: { testEpoch })

        let report = try await engine.sync()
        XCTAssertEqual(report.rejectedCount, 1)
        let persisted = try await store.load()
        XCTAssertEqual(persisted.cursor(for: account)?.value, "old")
    }
}

private actor ScriptedAdapter: ExternalSyncAdapter {
    nonisolated let account: SyncAccount
    nonisolated let capabilities: Set<AdapterCapability> = []
    private var pulls: [RemoteChanges]
    private var pushResults: [PushResult]
    private(set) var pushes: [[RemoteMutation]] = []

    init(account: SyncAccount, pulls: [RemoteChanges], pushResults: [PushResult] = []) {
        self.account = account
        self.pulls = pulls
        self.pushResults = pushResults
    }

    func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        guard !pulls.isEmpty else { return RemoteChanges(changes: [], nextCursor: cursor, serverNow: Date()) }
        return pulls.removeFirst()
    }

    func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        pushes.append(mutations)
        if !pushResults.isEmpty { return pushResults.removeFirst() }
        return PushResult(accepted: mutations.count, nextCursor: cursor, serverNow: Date())
    }

    func recordedPushes() -> [[RemoteMutation]] { pushes }
}
