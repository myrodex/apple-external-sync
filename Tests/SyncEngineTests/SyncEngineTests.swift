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
        let runs = try await store.syncRuns(account: account, limit: 1)
        XCTAssertEqual(runs.count, 1)
        XCTAssertEqual(runs.first?.status, .succeeded)
        XCTAssertEqual(runs.first?.accountID, account.accountID)
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

    func testAccountScopedProjectionAndMutationsDoNotLeakForeignAccountData() async throws {
        let accountA = SyncAccount(provider: .genericREST, accountID: "account-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "account-b")
        let foreignID = SyncID.deterministic(namespace: "account-b:task:foreign")
        let foreignTask = CanonicalTask(id: foreignID, title: "B-only", createdAt: testEpoch, updatedAt: testEpoch)
        let state = SyncState(
            tasks: [foreignTask],
            taskReplicas: [TaskReplica(
                externalID: ExternalTaskID(account: accountB, remoteTaskID: "b-task"),
                canonicalTaskID: foreignID,
                lastSyncedTask: foreignTask,
                lastSyncedAt: testEpoch,
                remoteRevision: "b-r1"
            )],
            taskOwners: [foreignID: accountB]
        )
        let store = InMemorySyncStateStore(state: state)
        let adapter = ScriptedAdapter(account: accountA, pulls: [RemoteChanges(changes: [], nextCursor: "a-r1", serverNow: testEpoch)])
        let engine = SyncEngine(adapter: adapter, stateStore: store, now: { testEpoch })

        _ = try await engine.sync()
        let visible = try await engine.currentState()
        let pushes = await adapter.recordedPushes()

        XCTAssertTrue(visible.tasks.isEmpty)
        XCTAssertTrue(visible.taskReplicas.isEmpty)
        XCTAssertTrue(visible.taskOwners.isEmpty)
        XCTAssertTrue(pushes.isEmpty)

        do {
            try await engine.applyLocalChange(.upsertTask(foreignTask))
            XCTFail("Expected a foreign account record to be rejected")
        } catch let error as SyncEngineError {
            guard case let .recordNotOwned(entityType, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(entityType, .task)
            XCTAssertEqual(id, foreignID)
        }
        let persisted = try await store.load()
        XCTAssertEqual(persisted.task(id: foreignID), foreignTask)
        XCTAssertEqual(persisted.taskOwners[foreignID], accountB)
        XCTAssertEqual(persisted.cursor(for: accountA)?.value, "a-r1")
    }

    func testAmbiguousLegacyOwnershipIsHiddenAndCannotBeClaimed() async throws {
        let accountA = SyncAccount(provider: .genericREST, accountID: "account-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "account-b")
        let sharedID = SyncID.deterministic(namespace: "legacy-shared-task")
        let sharedTask = CanonicalTask(id: sharedID, title: "Ambiguous", createdAt: testEpoch, updatedAt: testEpoch)
        let store = InMemorySyncStateStore(state: SyncState(
            tasks: [sharedTask],
            taskReplicas: [
                TaskReplica(externalID: ExternalTaskID(account: accountA, remoteTaskID: "a-task"), canonicalTaskID: sharedID, lastSyncedTask: sharedTask, lastSyncedAt: testEpoch),
                TaskReplica(externalID: ExternalTaskID(account: accountB, remoteTaskID: "b-task"), canonicalTaskID: sharedID, lastSyncedTask: sharedTask, lastSyncedAt: testEpoch)
            ]
        ))
        let engine = SyncEngine(account: accountA, adapter: ScriptedAdapter(account: accountA, pulls: []), stateStore: store, now: { testEpoch })

        let visible = try await engine.currentState()
        XCTAssertTrue(visible.tasks.isEmpty)
        do {
            try await engine.applyLocalChange(.upsertTask(sharedTask))
            XCTFail("Ambiguous legacy ownership must not be claimable")
        } catch let error as SyncEngineError {
            guard case let .recordNotOwned(entityType, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(entityType, .task)
            XCTAssertEqual(id, sharedID)
        }
        let persisted = try await store.load()
        XCTAssertNil(persisted.taskOwners[sharedID])
    }

    func testSQLiteQuarantineReservesAmbiguousIDFromNewAccountClaim() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let databaseURL = directory.appendingPathComponent("quarantine.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountA = SyncAccount(provider: .genericREST, accountID: "account-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "account-b")
        let accountC = SyncAccount(provider: .genericREST, accountID: "account-c")
        let quarantinedID = SyncID.deterministic(namespace: "genericREST:account-c:task:quarantined")
        let knownID = SyncID.deterministic(namespace: "known:account-a")
        let quarantinedTask = CanonicalTask(id: quarantinedID, title: "Ambiguous", createdAt: testEpoch, updatedAt: testEpoch)
        let knownTask = CanonicalTask(id: knownID, title: "Known", createdAt: testEpoch, updatedAt: testEpoch)
        let legacy = SyncState(
            tasks: [knownTask, quarantinedTask],
            taskReplicas: [
                TaskReplica(externalID: ExternalTaskID(account: accountA, remoteTaskID: "ambiguous-a"), canonicalTaskID: quarantinedID, lastSyncedTask: quarantinedTask, lastSyncedAt: testEpoch),
                TaskReplica(externalID: ExternalTaskID(account: accountB, remoteTaskID: "ambiguous-b"), canonicalTaskID: quarantinedID, lastSyncedTask: quarantinedTask, lastSyncedAt: testEpoch),
                TaskReplica(externalID: ExternalTaskID(account: accountA, remoteTaskID: "known"), canonicalTaskID: knownID, lastSyncedTask: knownTask, lastSyncedAt: testEpoch)
            ],
            taskOwners: [knownID: accountA]
        )
        let store = try SQLiteLocalStore(url: databaseURL)
        try await store.save(legacy)
        let quarantineBefore = try await store.isQuarantined(entityType: .task, id: quarantinedID)
        XCTAssertTrue(quarantineBefore)
        let accountAStateBefore = try await store.load(account: accountA)
        XCTAssertEqual(accountAStateBefore.task(id: knownID)?.title, "Known")

        let adapter = ScriptedAdapter(account: accountC, pulls: [RemoteChanges(
            changes: [.task(RemoteTask(remoteID: "quarantined", title: "New account claim", updatedAt: testEpoch, revision: "r1"))],
            nextCursor: "cursor-c",
            serverNow: testEpoch
        )])
        let engine = SyncEngine(account: accountC, adapter: adapter, stateStore: store, now: { testEpoch })
        do {
            _ = try await engine.sync()
            XCTFail("A canonical ID retained in quarantine must not be claimed by a new account")
        } catch let error as SyncEngineError {
            guard case let .recordNotOwned(entityType, id) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(entityType, .task)
            XCTAssertEqual(id, quarantinedID)
        }
        let pushes = await adapter.recordedPushes()
        XCTAssertTrue(pushes.isEmpty)
        let accountAStateAfter = try await store.load(account: accountA)
        XCTAssertEqual(accountAStateAfter.task(id: knownID)?.title, "Known")
        let accountCState = try await store.load(account: accountC)
        XCTAssertTrue(accountCState.tasks.isEmpty)
        let quarantineAfter = try await store.isQuarantined(entityType: .task, id: quarantinedID)
        XCTAssertTrue(quarantineAfter)
    }

    func testForeignConflictCannotBeReadOrResolved() async throws {
        let accountA = SyncAccount(provider: .genericREST, accountID: "account-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "account-b")
        let taskID = SyncID.deterministic(namespace: "account-b:task:conflict")
        let base = CanonicalTask(id: taskID, title: "Base", createdAt: testEpoch, updatedAt: testEpoch)
        let local = CanonicalTask(id: taskID, title: "Local", createdAt: testEpoch, updatedAt: testEpoch)
        let remote = CanonicalTask(id: taskID, title: "Remote", createdAt: testEpoch, updatedAt: testEpoch)
        let conflict = SyncConflict(
            account: accountB,
            canonicalTaskID: taskID,
            kind: .concurrentEdit,
            fields: [.title],
            baseTask: base,
            localTask: local,
            remoteTask: remote,
            createdAt: testEpoch
        )
        let store = InMemorySyncStateStore(state: SyncState(
            tasks: [local],
            taskReplicas: [TaskReplica(externalID: ExternalTaskID(account: accountB, remoteTaskID: "b-task"), canonicalTaskID: taskID, lastSyncedTask: base, lastSyncedAt: testEpoch)],
            conflicts: [conflict],
            taskOwners: [taskID: accountB]
        ))
        let engine = SyncEngine(adapter: ScriptedAdapter(account: accountA, pulls: []), stateStore: store, now: { testEpoch })

        let visibleConflicts = try await engine.queuedConflicts()
        XCTAssertTrue(visibleConflicts.isEmpty)
        do {
            try await engine.resolveConflict(id: conflict.id, resolution: .remoteWon)
            XCTFail("Expected a foreign conflict to be hidden")
        } catch let error as SyncEngineError {
            guard case .conflictNotFound = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let persisted = try await store.load()
        XCTAssertEqual(persisted.conflicts.first?.resolution, .pending)
        XCTAssertEqual(persisted.taskOwners[taskID], accountB)
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
        let runs = try await store.syncRuns(account: account, limit: 1)
        XCTAssertEqual(runs.first?.status, .partiallySucceeded)
        XCTAssertEqual(runs.first?.errorMessage, "Some provider writes were rejected and will be retried.")
    }

    func testAuditHistoryIsAccountScopedAndFailureSurvivesPullError() async throws {
        let accountA = SyncAccount(provider: .genericREST, accountID: "account-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "account-b")
        let store = InMemorySyncStateStore()
        let engine = SyncEngine(
            account: accountA,
            adapter: ThrowingAdapter(account: accountA),
            stateStore: store,
            now: { testEpoch }
        )

        do {
            _ = try await engine.sync()
            XCTFail("Expected the provider pull to fail")
        } catch let error as SyncAdapterError {
            XCTAssertEqual(error, .transport("offline"))
        }

        let accountARuns = try await store.syncRuns(account: accountA, limit: 10)
        let accountBRuns = try await store.syncRuns(account: accountB, limit: 10)
        XCTAssertEqual(accountARuns.count, 1)
        XCTAssertEqual(accountARuns.first?.status, .failed)
        XCTAssertEqual(accountARuns.first?.errorMessage, "Provider transport failed: offline")
        XCTAssertTrue(accountBRuns.isEmpty)
    }

    func testAuditStoreFailureAfterCanonicalCommitDoesNotTurnSuccessIntoFailure() async throws {
        let account = SyncAccount(provider: .genericREST, accountID: "audit-outage")
        let adapter = ScriptedAdapter(account: account, pulls: [RemoteChanges(
            changes: [.list(RemoteList(remoteID: "work", name: "Work", updatedAt: testEpoch, revision: "r1"))],
            nextCursor: "cursor-1",
            serverNow: testEpoch
        )])
        let store = AuditWriteFailureStore()
        let engine = SyncEngine(account: account, adapter: adapter, stateStore: store, now: { testEpoch })

        let report = try await engine.sync()

        XCTAssertTrue(report.committed)
        XCTAssertEqual(report.cursorAfter, "cursor-1")
        let persisted = try await store.load()
        XCTAssertEqual(persisted.cursor(for: account)?.value, "cursor-1")
        let auditAttempts = await store.auditWriteAttempts()
        XCTAssertGreaterThan(auditAttempts, 0)
    }
}

private actor ThrowingAdapter: ExternalSyncAdapter {
    nonisolated let account: SyncAccount
    nonisolated let capabilities: Set<AdapterCapability> = []

    init(account: SyncAccount) { self.account = account }

    func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        throw SyncAdapterError.transport("offline")
    }

    func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        XCTFail("Push must not run when pull fails")
        return PushResult(accepted: 0, nextCursor: cursor, serverNow: testEpoch)
    }
}

private actor AuditWriteFailureStore: SyncStateStore {
    private var state = SyncState()
    private var attempts = 0

    func load() async throws -> SyncState { state }
    func save(_ state: SyncState) async throws { self.state = state }
    func syncRuns(account: SyncAccount, limit: Int?) async throws -> [SyncRun] { [] }
    func cleanup(asOf: Date, retention: TimeInterval) async throws -> StoreCleanupResult {
        StoreCleanupResult(tombstonesRemoved: 0, completedRunsRemoved: 0)
    }
    func upsertSyncRun(_ run: SyncRun) async throws {
        attempts += 1
        throw LocalStoreError.unavailable("audit database offline")
    }
    func remove(account: SyncAccount) async throws {
        state = state.removing(account: account)
    }
    func auditWriteAttempts() -> Int { attempts }
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
