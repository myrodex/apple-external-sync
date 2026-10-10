import Foundation
import XCTest
@testable import SyncStore
import SyncDomain

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
