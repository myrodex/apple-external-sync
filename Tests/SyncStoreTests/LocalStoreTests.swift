import Foundation
import XCTest
@testable import SyncStore
import SyncDomain
import SQLite3

final class LocalStoreTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    func testSQLitePersistsEveryEntityAcrossReopen() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let databaseURL = directory.appendingPathComponent("sync.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let mappingKey = MappingKey(provider: "provider", entityType: "task", localID: "local-1", remoteID: "remote-1")
        let mapping = EntityMapping(key: mappingKey, localRevision: "l1", remoteRevision: "r1", createdAt: epoch, updatedAt: epoch)
        let snapshot = CanonicalSnapshot(mappingID: mapping.id, side: .canonical, payload: Data("canonical".utf8), contentHash: "hash", sourceRevision: "r1", capturedAt: epoch)
        let cursor = ProviderCursor(key: ProviderCursorKey(provider: "provider", scope: "account"), value: "cursor-1", updatedAt: epoch)
        let tombstone = Tombstone(provider: "provider", entityType: "task", remoteID: "remote-deleted", side: .remote, deletedAt: epoch, expiresAt: epoch.addingTimeInterval(10))
        let conflict = ConflictRecord(mappingID: mapping.id, key: mappingKey, localPayload: Data("local".utf8), remotePayload: Data("remote".utf8), detectedAt: epoch)
        let run = SyncRun(provider: "provider", startedAt: epoch, finishedAt: epoch.addingTimeInterval(1), status: .succeeded, scannedCount: 1)

        let first = try SQLiteLocalStore(url: databaseURL)
        try await first.apply(StoreTransaction(mappings: [mapping], snapshots: [snapshot], cursors: [cursor], tombstones: [tombstone], conflicts: [conflict], syncRuns: [run]))
        let reopened = try SQLiteLocalStore(url: databaseURL)

        let persistedMapping = try await reopened.mapping(for: mappingKey)
        let persistedSnapshot = try await reopened.snapshot(mappingID: mapping.id, side: .canonical)
        let persistedCursor = try await reopened.cursor(for: cursor.key)
        let persistedTombstone = try await reopened.tombstone(forProvider: "provider", entityType: "task", localID: nil, remoteID: "remote-deleted", side: .remote)
        let persistedConflict = try await reopened.conflict(id: conflict.id)
        let persistedRun = try await reopened.syncRun(id: run.id)
        let persistedStats = try await reopened.statistics()
        XCTAssertEqual(persistedMapping, mapping)
        XCTAssertEqual(persistedSnapshot, snapshot)
        XCTAssertEqual(persistedCursor, cursor)
        XCTAssertEqual(persistedTombstone, tombstone)
        XCTAssertEqual(persistedConflict?.id, conflict.id)
        XCTAssertEqual(persistedConflict?.mappingID, conflict.mappingID)
        XCTAssertEqual(persistedConflict?.key, conflict.key)
        XCTAssertEqual(persistedConflict?.localPayload, conflict.localPayload)
        XCTAssertEqual(persistedConflict?.remotePayload, conflict.remotePayload)
        XCTAssertEqual(persistedConflict?.status, conflict.status)
        XCTAssertEqual(persistedConflict?.detectedAt, conflict.detectedAt)
        XCTAssertEqual(persistedConflict?.updatedAt.timeIntervalSince1970 ?? 0, conflict.updatedAt.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertEqual(persistedRun, run)
        XCTAssertEqual(persistedStats, StoreStatistics(mappings: 1, snapshots: 1, cursors: 1, tombstones: 1, conflicts: 1, syncRuns: 1))
    }

    func testApplyRollsBackAllTablesWhenOneWriteFails() async throws {
        let store = try SQLiteLocalStore.inMemory()
        let key = MappingKey(provider: "p", entityType: "task", localID: "l", remoteID: "r")
        let mapping = EntityMapping(key: key)
        let orphanSnapshot = CanonicalSnapshot(mappingID: UUID(), payload: Data(), contentHash: "orphan")

        do {
            try await store.apply(StoreTransaction(mappings: [mapping], snapshots: [orphanSnapshot]))
            XCTFail("Expected foreign-key failure")
        } catch {
            // The failed transaction must not leave the mapping behind.
        }
        let persistedMapping = try await store.mapping(for: key)
        let persistedStats = try await store.statistics()
        XCTAssertNil(persistedMapping)
        XCTAssertEqual(persistedStats, StoreStatistics(mappings: 0, snapshots: 0, cursors: 0, tombstones: 0, conflicts: 0, syncRuns: 0))
    }

    func testUpsertUsesNaturalMappingKeyAndKeepsExistingIdentity() async throws {
        let store = try SQLiteLocalStore.inMemory()
        let key = MappingKey(provider: "p", entityType: "task", localID: "l", remoteID: "r")
        let first = EntityMapping(id: UUID(), key: key, localRevision: "one")
        let replacement = EntityMapping(id: UUID(), key: key, localRevision: "two")
        try await store.upsertMapping(first)
        try await store.upsertMapping(replacement)

        let storedMapping = try await store.mapping(for: key)
        let stored = try XCTUnwrap(storedMapping)
        XCTAssertEqual(stored.id, first.id)
        XCTAssertEqual(stored.localRevision, "two")
    }

    func testSyncRunsAreAccountScopedAndDisconnectRemovesOnlySelectedAccount() async throws {
        let store = try SQLiteLocalStore.inMemory()
        let accountA = SyncAccount(provider: .genericREST, accountID: "a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "b")
        let runA = SyncRun(account: accountA, startedAt: epoch, status: .failed, errorMessage: "a failed")
        let runB = SyncRun(account: accountB, startedAt: epoch, status: .succeeded)
        try await store.apply(StoreTransaction(syncRuns: [runA, runB]))

        let accountARuns = try await store.syncRuns(account: accountA, limit: 10)
        let accountBRuns = try await store.syncRuns(account: accountB, limit: 10)
        XCTAssertEqual(accountARuns.map(\.id), [runA.id])
        XCTAssertEqual(accountBRuns.map(\.id), [runB.id])

        try await store.remove(account: accountA)
        let removedAccountRuns = try await store.syncRuns(account: accountA, limit: 10)
        let retainedAccountRuns = try await store.syncRuns(account: accountB, limit: 10)
        XCTAssertTrue(removedAccountRuns.isEmpty)
        XCTAssertEqual(retainedAccountRuns.map(\.id), [runB.id])
    }

    func testRemoveAccountDeletesScopedCanonicalStateAndRetainsForeignState() async throws {
        let store = try SQLiteLocalStore.inMemory()
        let accountA = SyncAccount(provider: .genericREST, accountID: "a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "b")
        let listAID = SyncID.deterministic(namespace: "remove:list:a")
        let listBID = SyncID.deterministic(namespace: "remove:list:b")
        let taskAID = SyncID.deterministic(namespace: "remove:task:a")
        let taskBID = SyncID.deterministic(namespace: "remove:task:b")
        let listA = CanonicalList(id: listAID, name: "A", createdAt: epoch, updatedAt: epoch)
        let listB = CanonicalList(id: listBID, name: "B", createdAt: epoch, updatedAt: epoch)
        let taskA = CanonicalTask(id: taskAID, title: "A task", listID: listAID, createdAt: epoch, updatedAt: epoch)
        let taskB = CanonicalTask(id: taskBID, title: "B task", listID: listBID, createdAt: epoch, updatedAt: epoch)
        let conflictA = SyncConflict(
            account: accountA,
            canonicalTaskID: taskAID,
            kind: .concurrentEdit,
            fields: [.title],
            localTask: taskA,
            createdAt: epoch
        )
        let conflictB = SyncConflict(
            account: accountB,
            canonicalTaskID: taskBID,
            kind: .concurrentEdit,
            fields: [.title],
            localTask: taskB,
            createdAt: epoch
        )
        let state = SyncState(
            lists: [listA, listB],
            tasks: [taskA, taskB],
            listMappings: [
                ListMapping(account: accountA, canonicalListID: listAID, remoteListID: "a-list", lastSeenAt: epoch),
                ListMapping(account: accountB, canonicalListID: listBID, remoteListID: "b-list", lastSeenAt: epoch)
            ],
            taskReplicas: [
                TaskReplica(externalID: ExternalTaskID(account: accountA, remoteTaskID: "a-task"), canonicalTaskID: taskAID, lastSyncedTask: taskA, lastSyncedAt: epoch),
                TaskReplica(externalID: ExternalTaskID(account: accountB, remoteTaskID: "b-task"), canonicalTaskID: taskBID, lastSyncedTask: taskB, lastSyncedAt: epoch)
            ],
            listReplicas: [
                ListReplica(account: accountA, canonicalListID: listAID, remoteListID: "a-list", lastSyncedList: listA, lastSyncedAt: epoch),
                ListReplica(account: accountB, canonicalListID: listBID, remoteListID: "b-list", lastSyncedList: listB, lastSyncedAt: epoch)
            ],
            conflicts: [conflictA, conflictB],
            cursors: [
                SyncCursor(account: accountA, value: "a-cursor", updatedAt: epoch),
                SyncCursor(account: accountB, value: "b-cursor", updatedAt: epoch)
            ],
            taskOwners: [taskAID: accountA, taskBID: accountB],
            listOwners: [listAID: accountA, listBID: accountB]
        )
        let runA = SyncRun(account: accountA, startedAt: epoch, status: .failed)
        let runB = SyncRun(account: accountB, startedAt: epoch, status: .succeeded)
        try await store.save(state)
        try await store.apply(StoreTransaction(syncRuns: [runA, runB]))

        try await store.remove(account: accountA)

        let result = try await store.load()
        XCTAssertFalse(result.lists.contains { $0.id == listAID })
        XCTAssertFalse(result.tasks.contains { $0.id == taskAID })
        XCTAssertTrue(result.lists.contains { $0.id == listBID })
        XCTAssertTrue(result.tasks.contains { $0.id == taskBID })
        XCTAssertFalse(result.listMappings.contains { $0.account == accountA })
        XCTAssertFalse(result.taskReplicas.contains { $0.externalID.account == accountA })
        XCTAssertFalse(result.listReplicas.contains { $0.account == accountA })
        XCTAssertFalse(result.conflicts.contains { $0.account == accountA })
        XCTAssertFalse(result.cursors.contains { $0.account == accountA })
        XCTAssertNil(result.taskOwners[taskAID])
        XCTAssertNil(result.listOwners[listAID])
        XCTAssertTrue(result.listMappings.contains { $0.account == accountB })
        XCTAssertTrue(result.taskReplicas.contains { $0.externalID.account == accountB })
        XCTAssertTrue(result.listReplicas.contains { $0.account == accountB })
        XCTAssertTrue(result.conflicts.contains { $0.account == accountB })
        XCTAssertNotNil(result.cursor(for: accountB))
        let removedRuns = try await store.syncRuns(account: accountA, limit: 10)
        let retainedRuns = try await store.syncRuns(account: accountB, limit: 10)
        XCTAssertEqual(removedRuns.count, 0)
        XCTAssertEqual(retainedRuns.map(\.id), [runB.id])
    }

    func testTombstonesExpireAndCleanupCompletedRunsButNotRunningRuns() async throws {
        let store = try SQLiteLocalStore.inMemory()
        let now = epoch.addingTimeInterval(31 * 24 * 60 * 60)
        let expired = Tombstone(provider: "p", entityType: "task", remoteID: "expired", side: .remote, deletedAt: epoch, expiresAt: epoch.addingTimeInterval(30 * 24 * 60 * 60))
        let fresh = Tombstone(provider: "p", entityType: "task", remoteID: "fresh", side: .remote, deletedAt: now, expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60))
        let oldRun = SyncRun(provider: "p", startedAt: epoch, finishedAt: epoch.addingTimeInterval(1), status: .succeeded)
        let activeRun = SyncRun(provider: "p", startedAt: epoch, status: .running)
        try await store.apply(StoreTransaction(tombstones: [expired, fresh], syncRuns: [oldRun, activeRun]))

        let result = try await store.cleanup(asOf: now, retention: 30 * 24 * 60 * 60)
        XCTAssertEqual(result.tombstonesRemoved, 1)
        XCTAssertEqual(result.completedRunsRemoved, 1)
        let expiredTombstone = try await store.tombstone(forProvider: "p", entityType: "task", localID: nil, remoteID: "expired", side: .remote)
        let freshTombstone = try await store.tombstone(forProvider: "p", entityType: "task", localID: nil, remoteID: "fresh", side: .remote)
        let removedRun = try await store.syncRun(id: oldRun.id)
        let retainedRun = try await store.syncRun(id: activeRun.id)
        XCTAssertNil(expiredTombstone)
        XCTAssertNotNil(freshTombstone)
        XCTAssertNil(removedRun)
        XCTAssertNotNil(retainedRun)
    }

    func testConflictQueueIsFIFOAndProviderScoped() async throws {
        let store = InMemoryLocalStore()
        let first = ConflictRecord(key: MappingKey(provider: "a", entityType: "task", localID: "1", remoteID: "1"), localPayload: Data(), remotePayload: Data(), detectedAt: epoch)
        let second = ConflictRecord(key: MappingKey(provider: "b", entityType: "task", localID: "2", remoteID: "2"), localPayload: Data(), remotePayload: Data(), detectedAt: epoch.addingTimeInterval(1))
        var resolved = second
        resolved.status = .resolved
        try await store.apply(StoreTransaction(conflicts: [second, first, resolved]))

        let providerAQueue = try await store.queuedConflicts(provider: "a", limit: 10).map(\.id)
        let providerBQueue = try await store.queuedConflicts(provider: "b", limit: 10)
        XCTAssertEqual(providerAQueue, [first.id])
        XCTAssertTrue(providerBQueue.isEmpty)
    }

    func testConcurrentWritesRemainConsistent() async throws {
        let store = try SQLiteLocalStore.inMemory()
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    let key = MappingKey(provider: "p", entityType: "task", localID: "local-\(index)", remoteID: "remote-\(index)")
                    try? await store.upsertMapping(EntityMapping(key: key))
                    try? await store.upsertCursor(ProviderCursor(key: ProviderCursorKey(provider: "p", scope: "scope-\(index)"), value: "\(index)"))
                }
            }
        }
        let stats = try await store.statistics()
        XCTAssertEqual(stats.mappings, 100)
        XCTAssertEqual(stats.cursors, 100)
    }

    func testConcurrentAccountCheckpointsDoNotEraseEachOther() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let databaseURL = directory.appendingPathComponent("account-checkpoints.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountA = SyncAccount(provider: .genericREST, accountID: "checkpoint-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "checkpoint-b")
        let listAID = SyncID.deterministic(namespace: "checkpoint:list:a")
        let listBID = SyncID.deterministic(namespace: "checkpoint:list:b")
        let listA = CanonicalList(id: listAID, name: "A", createdAt: epoch, updatedAt: epoch)
        let listB = CanonicalList(id: listBID, name: "B", createdAt: epoch, updatedAt: epoch)
        let stateA = SyncState(lists: [listA], cursors: [SyncCursor(account: accountA, value: "a", updatedAt: epoch)], listOwners: [listAID: accountA])
        let stateB = SyncState(lists: [listB], cursors: [SyncCursor(account: accountB, value: "b", updatedAt: epoch)], listOwners: [listBID: accountB])
        let storeA = try SQLiteLocalStore(url: databaseURL)
        let storeB = try SQLiteLocalStore(url: databaseURL)

        await withTaskGroup(of: Void.self) { group in
            group.addTask { try? await storeA.save(stateA, account: accountA) }
            group.addTask { try? await storeB.save(stateB, account: accountB) }
        }

        let scopedA = try await storeA.load(account: accountA)
        let scopedB = try await storeA.load(account: accountB)
        XCTAssertEqual(scopedA.lists.map(\.id), [listAID])
        XCTAssertEqual(scopedB.lists.map(\.id), [listBID])
        XCTAssertEqual(scopedA.cursor(for: accountA)?.value, "a")
        XCTAssertEqual(scopedB.cursor(for: accountB)?.value, "b")
    }

    func testLegacySharedCheckpointMigratesKnownOwnershipAndQuarantinesAmbiguousRecords() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let databaseURL = directory.appendingPathComponent("legacy.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let accountA = SyncAccount(provider: .genericREST, accountID: "legacy-a")
        let accountB = SyncAccount(provider: .genericREST, accountID: "legacy-b")
        let knownID = SyncID.deterministic(namespace: "legacy:known")
        let ambiguousID = SyncID.deterministic(namespace: "legacy:ambiguous")
        let known = CanonicalList(id: knownID, name: "Known", createdAt: epoch, updatedAt: epoch)
        let ambiguous = CanonicalList(id: ambiguousID, name: "Ambiguous", createdAt: epoch, updatedAt: epoch)
        let legacy = SyncState(
            lists: [known, ambiguous],
            listMappings: [
                ListMapping(account: accountA, canonicalListID: knownID, remoteListID: "known", lastSeenAt: epoch),
                ListMapping(account: accountA, canonicalListID: ambiguousID, remoteListID: "ambiguous-a", lastSeenAt: epoch),
                ListMapping(account: accountB, canonicalListID: ambiguousID, remoteListID: "ambiguous-b", lastSeenAt: epoch)
            ],
            cursors: [SyncCursor(account: accountA, value: "cursor-a", updatedAt: epoch)]
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try encoder.encode(legacy)
        try createLegacyDatabase(at: databaseURL, payload: payload)

        do {
            let store = try SQLiteLocalStore(url: databaseURL)
            let migratedA = try await store.load(account: accountA)
            let migratedB = try await store.load(account: accountB)
            let aggregate = try await store.load()
            XCTAssertEqual(migratedA.lists.map(\.id), [knownID])
            XCTAssertTrue(migratedB.lists.isEmpty)
            XCTAssertTrue(aggregate.lists.contains { $0.id == knownID })
            XCTAssertFalse(aggregate.lists.contains { $0.id == ambiguousID })
        }

        do {
            let reopened = try SQLiteLocalStore(url: databaseURL)
            let reopenedA = try await reopened.load(account: accountA)
            XCTAssertEqual(reopenedA.lists.map(\.id), [knownID])
        }
        XCTAssertEqual(try readQuarantineCount(at: databaseURL), 1)
    }

}

extension LocalStoreTests {
    func testSQLitePersistsCanonicalSyncStateForEngineRuntime() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let databaseURL = directory.appendingPathComponent("engine.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let account = SyncAccount(provider: .eventKit, accountID: "device")
        let list = CanonicalList(name: "Work", createdAt: epoch, updatedAt: epoch)
        let state = SyncState(
            lists: [list],
            cursors: [SyncCursor(account: account, value: "cursor-1", updatedAt: epoch)]
        )
        let first = try SQLiteLocalStore(url: databaseURL)
        try await first.save(state)
        let reopened = try SQLiteLocalStore(url: databaseURL)
        let loaded = try await reopened.load()

        XCTAssertEqual(loaded, state)
    }
}


private func createLegacyDatabase(at url: URL, payload: Data) throws {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
        throw NSError(domain: "LegacyTest", code: 1)
    }
    defer { sqlite3_close(handle) }
    let hex = payload.map { String(format: "%02x", $0) }.joined()
    let sql = """
        CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY NOT NULL, applied_at REAL NOT NULL);
        INSERT INTO schema_migrations(version, applied_at) VALUES (1, 0), (2, 0), (3, 0);
        CREATE TABLE sync_state (id INTEGER PRIMARY KEY CHECK (id = 1), payload BLOB NOT NULL, updated_at REAL NOT NULL);
        INSERT INTO sync_state(id, payload, updated_at) VALUES (1, X'\(hex)', 0);
        """
    var errorMessage: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
        let message = errorMessage.map { String(cString: $0) } ?? "unknown"
        sqlite3_free(errorMessage)
        throw NSError(domain: "LegacyTest", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func readQuarantineCount(at url: URL) throws -> Int {
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let handle else {
        throw NSError(domain: "LegacyTest", code: 3)
    }
    defer { sqlite3_close(handle) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sync_state_quarantine;", -1, &statement, nil) == SQLITE_OK, let statement else {
        throw NSError(domain: "LegacyTest", code: 4)
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "LegacyTest", code: 5) }
    return Int(sqlite3_column_int64(statement, 0))
}
