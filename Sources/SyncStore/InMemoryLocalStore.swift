import Foundation
import SyncDomain

/// An actor-backed test double with the same transaction and retention semantics as
/// `SQLiteLocalStore`. It is useful for deterministic engine tests and previews.
public actor InMemoryLocalStore: LocalStore {
    private struct State: Sendable {
        var mappings: [UUID: EntityMapping] = [:]
        var snapshots: [UUID: CanonicalSnapshot] = [:]
        var cursors: [ProviderCursorKey: ProviderCursor] = [:]
        var tombstones: [UUID: Tombstone] = [:]
        var conflicts: [UUID: ConflictRecord] = [:]
        var syncRuns: [UUID: SyncRun] = [:]
    }

    private var state = State()

    public init() {}

    public func apply(_ transaction: StoreTransaction) async throws {
        guard !transaction.isEmpty else { return }
        var next = state
        for mapping in transaction.mappings { upsert(mapping, into: &next) }
        for snapshot in transaction.snapshots { upsert(snapshot, into: &next) }
        for cursor in transaction.cursors { next.cursors[cursor.key] = cursor }
        for tombstone in transaction.tombstones {
            if let existing = next.tombstones.first(where: { value in
                let value = value.value
                return value.provider == tombstone.provider && value.entityType == tombstone.entityType && value.localID == tombstone.localID && value.remoteID == tombstone.remoteID && value.side == tombstone.side
            }), existing.key != tombstone.id {
                next.tombstones.removeValue(forKey: existing.key)
                var replacement = tombstone
                replacement = Tombstone(
                    id: existing.key,
                    provider: tombstone.provider,
                    entityType: tombstone.entityType,
                    localID: tombstone.localID,
                    remoteID: tombstone.remoteID,
                    side: tombstone.side,
                    reason: tombstone.reason,
                    deletedAt: tombstone.deletedAt,
                    expiresAt: tombstone.expiresAt,
                    metadata: tombstone.metadata
                )
                next.tombstones[replacement.id] = replacement
            } else {
                next.tombstones[tombstone.id] = tombstone
            }
        }
        for conflict in transaction.conflicts { next.conflicts[conflict.id] = conflict }
        for run in transaction.syncRuns { next.syncRuns[run.id] = run }
        state = next
    }

    public func mapping(for key: MappingKey) async throws -> EntityMapping? {
        state.mappings.values.first { $0.key == key }
    }

    public func mapping(id: UUID) async throws -> EntityMapping? {
        state.mappings[id]
    }

    public func mappings(provider: String, entityType: String) async throws -> [EntityMapping] {
        state.mappings.values
            .filter { $0.key.provider == provider && $0.key.entityType == entityType }
            .sorted { $0.updatedAt == $1.updatedAt ? $0.id.uuidString < $1.id.uuidString : $0.updatedAt > $1.updatedAt }
    }

    public func upsertMapping(_ mapping: EntityMapping) async throws {
        try await apply(StoreTransaction(mappings: [mapping]))
    }

    public func deleteMapping(for key: MappingKey) async throws {
        var next = state
        let ids = next.mappings.values.filter { $0.key == key }.map(\.id)
        for id in ids {
            next.mappings.removeValue(forKey: id)
            next.snapshots = next.snapshots.filter { $0.value.mappingID != id }
        }
        state = next
    }

    public func snapshot(mappingID: UUID, side: SnapshotSide) async throws -> CanonicalSnapshot? {
        state.snapshots.values.first { $0.mappingID == mappingID && $0.side == side }
    }

    public func snapshots(mappingID: UUID) async throws -> [CanonicalSnapshot] {
        state.snapshots.values.filter { $0.mappingID == mappingID }.sorted {
            $0.capturedAt == $1.capturedAt ? $0.side.rawValue < $1.side.rawValue : $0.capturedAt > $1.capturedAt
        }
    }

    public func upsertSnapshot(_ snapshot: CanonicalSnapshot) async throws {
        try await apply(StoreTransaction(snapshots: [snapshot]))
    }

    public func deleteSnapshots(mappingID: UUID) async throws {
        state.snapshots = state.snapshots.filter { $0.value.mappingID != mappingID }
    }

    public func cursor(for key: ProviderCursorKey) async throws -> ProviderCursor? {
        state.cursors[key]
    }

    public func upsertCursor(_ cursor: ProviderCursor) async throws {
        try await apply(StoreTransaction(cursors: [cursor]))
    }

    public func deleteCursor(for key: ProviderCursorKey) async throws {
        state.cursors.removeValue(forKey: key)
    }

    public func tombstone(
        forProvider provider: String,
        entityType: String,
        localID: String?,
        remoteID: String?,
        side: TombstoneSide
    ) async throws -> Tombstone? {
        state.tombstones.values.first {
            $0.provider == provider && $0.entityType == entityType && $0.localID == localID && $0.remoteID == remoteID && $0.side == side
        }
    }

    public func tombstones(provider: String, entityType: String, includeExpired: Bool = false, asOf: Date = Date()) async throws -> [Tombstone] {
        state.tombstones.values
            .filter { $0.provider == provider && $0.entityType == entityType && (includeExpired || $0.expiresAt > asOf) }
            .sorted { $0.deletedAt == $1.deletedAt ? $0.id.uuidString < $1.id.uuidString : $0.deletedAt > $1.deletedAt }
    }

    public func upsertTombstone(_ tombstone: Tombstone) async throws {
        try await apply(StoreTransaction(tombstones: [tombstone]))
    }

    public func deleteTombstone(id: UUID) async throws {
        state.tombstones.removeValue(forKey: id)
    }

    public func conflict(id: UUID) async throws -> ConflictRecord? {
        state.conflicts[id]
    }

    public func queuedConflicts(provider: String? = nil, limit: Int? = nil) async throws -> [ConflictRecord] {
        var result = state.conflicts.values.filter { conflict in
            conflict.status == .queued && (provider == nil || conflict.key.provider == provider)
        }.sorted {
            $0.detectedAt == $1.detectedAt ? $0.id.uuidString < $1.id.uuidString : $0.detectedAt < $1.detectedAt
        }
        if let limit { result = Array(result.prefix(max(0, limit))) }
        return result
    }

    public func upsertConflict(_ conflict: ConflictRecord) async throws {
        try await apply(StoreTransaction(conflicts: [conflict]))
    }

    public func deleteConflict(id: UUID) async throws {
        state.conflicts.removeValue(forKey: id)
    }

    public func syncRun(id: UUID) async throws -> SyncRun? {
        state.syncRuns[id]
    }

    public func syncRuns(provider: String? = nil, limit: Int? = nil) async throws -> [SyncRun] {
        var result = state.syncRuns.values.filter { provider == nil || $0.provider == provider }.sorted {
            $0.startedAt == $1.startedAt ? $0.id.uuidString > $1.id.uuidString : $0.startedAt > $1.startedAt
        }
        if let limit { result = Array(result.prefix(max(0, limit))) }
        return result
    }

    public func syncRuns(account: SyncAccount, limit: Int? = nil) async throws -> [SyncRun] {
        var result = state.syncRuns.values
            .filter { $0.provider == account.provider.rawValue && $0.accountID == account.accountID }
            .sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString > $1.id.uuidString : $0.startedAt > $1.startedAt
            }
        if let limit { result = Array(result.prefix(max(0, limit))) }
        return result
    }

    public func upsertSyncRun(_ run: SyncRun) async throws {
        try await apply(StoreTransaction(syncRuns: [run]))
    }

    public func cleanup(asOf: Date = Date(), retention: TimeInterval = SQLiteLocalStore.defaultRetention) async throws -> StoreCleanupResult {
        guard retention >= 0 else { throw LocalStoreError.invalidConfiguration("retention must be non-negative") }
        let beforeTombstones = state.tombstones.count
        state.tombstones = state.tombstones.filter { $0.value.expiresAt > asOf }
        let cutoff = asOf.addingTimeInterval(-retention)
        let beforeRuns = state.syncRuns.count
        state.syncRuns = state.syncRuns.filter { run in
            guard let finishedAt = run.value.finishedAt else { return true }
            guard finishedAt <= cutoff else { return true }
            return run.value.status == .running
        }
        return StoreCleanupResult(tombstonesRemoved: beforeTombstones - state.tombstones.count, completedRunsRemoved: beforeRuns - state.syncRuns.count)
    }

    public func statistics() async throws -> StoreStatistics {
        StoreStatistics(mappings: state.mappings.count, snapshots: state.snapshots.count, cursors: state.cursors.count, tombstones: state.tombstones.count, conflicts: state.conflicts.count, syncRuns: state.syncRuns.count)
    }

    private func upsert(_ mapping: EntityMapping, into state: inout State) {
        // Match SQLite's natural-key conflict policy: changing a value should not create
        // a second durable identity for the same provider/local/remote tuple.
        if let existing = state.mappings.first(where: { $0.value.key == mapping.key && $0.key != mapping.id }) {
            var replacement = mapping
            replacement = EntityMapping(
                id: existing.key,
                key: mapping.key,
                state: mapping.state,
                localRevision: mapping.localRevision,
                remoteRevision: mapping.remoteRevision,
                localFingerprint: mapping.localFingerprint,
                remoteFingerprint: mapping.remoteFingerprint,
                lastSynchronizedAt: mapping.lastSynchronizedAt,
                createdAt: mapping.createdAt,
                updatedAt: mapping.updatedAt
            )
            state.mappings.removeValue(forKey: existing.key)
            state.mappings[replacement.id] = replacement
            return
        }
        state.mappings[mapping.id] = mapping
    }

    private func upsert(_ snapshot: CanonicalSnapshot, into state: inout State) {
        if let existing = state.snapshots.first(where: { $0.value.mappingID == snapshot.mappingID && $0.value.side == snapshot.side }) {
            state.snapshots.removeValue(forKey: existing.key)
        }
        state.snapshots[snapshot.id] = snapshot
    }
}
