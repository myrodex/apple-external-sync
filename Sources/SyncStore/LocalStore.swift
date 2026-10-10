import Foundation
import SyncDomain

public enum LocalStoreError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidConfiguration(String)
    case unavailable(String)
    case migrationFailed(version: Int, underlying: String)
    case sqlite(code: Int32, message: String)
    case notFound(String)
    case invalidData(String)
    case transactionFailed(String)

    public var description: String {
        switch self {
        case .invalidConfiguration(let message): return "Invalid store configuration: \(message)"
        case .unavailable(let message): return "Store unavailable: \(message)"
        case .migrationFailed(let version, let underlying): return "Migration \(version) failed: \(underlying)"
        case .sqlite(let code, let message): return "SQLite error \(code): \(message)"
        case .notFound(let message): return "Store record not found: \(message)"
        case .invalidData(let message): return "Invalid store data: \(message)"
        case .transactionFailed(let message): return "Store transaction failed: \(message)"
        }
    }
}

/// One or more changes that are committed atomically by a store implementation.
/// Keeping the operation value type opaque to SQLite makes it possible to use the same
/// transaction semantics in the in-memory test double.
public struct StoreTransaction: Sendable {
    public var mappings: [EntityMapping]
    public var snapshots: [CanonicalSnapshot]
    public var cursors: [ProviderCursor]
    public var tombstones: [Tombstone]
    public var conflicts: [ConflictRecord]
    public var syncRuns: [SyncRun]

    public init(
        mappings: [EntityMapping] = [],
        snapshots: [CanonicalSnapshot] = [],
        cursors: [ProviderCursor] = [],
        tombstones: [Tombstone] = [],
        conflicts: [ConflictRecord] = [],
        syncRuns: [SyncRun] = []
    ) {
        self.mappings = mappings
        self.snapshots = snapshots
        self.cursors = cursors
        self.tombstones = tombstones
        self.conflicts = conflicts
        self.syncRuns = syncRuns
    }

    public var isEmpty: Bool {
        mappings.isEmpty && snapshots.isEmpty && cursors.isEmpty && tombstones.isEmpty && conflicts.isEmpty && syncRuns.isEmpty
    }
}

/// Persistence contract consumed by SyncEngine. Every mutating method is serialized by
/// the implementation and `apply(_:)` is all-or-nothing across all entity types.
public protocol LocalStore: Sendable {
    func apply(_ transaction: StoreTransaction) async throws

    func mapping(for key: MappingKey) async throws -> EntityMapping?
    func mapping(id: UUID) async throws -> EntityMapping?
    func mappings(provider: String, entityType: String) async throws -> [EntityMapping]
    func upsertMapping(_ mapping: EntityMapping) async throws
    func deleteMapping(for key: MappingKey) async throws

    func snapshot(mappingID: UUID, side: SnapshotSide) async throws -> CanonicalSnapshot?
    func snapshots(mappingID: UUID) async throws -> [CanonicalSnapshot]
    func upsertSnapshot(_ snapshot: CanonicalSnapshot) async throws
    func deleteSnapshots(mappingID: UUID) async throws

    func cursor(for key: ProviderCursorKey) async throws -> ProviderCursor?
    func upsertCursor(_ cursor: ProviderCursor) async throws
    func deleteCursor(for key: ProviderCursorKey) async throws

    func tombstone(forProvider provider: String, entityType: String, localID: String?, remoteID: String?, side: TombstoneSide) async throws -> Tombstone?
    func tombstones(provider: String, entityType: String, includeExpired: Bool, asOf: Date) async throws -> [Tombstone]
    func upsertTombstone(_ tombstone: Tombstone) async throws
    func deleteTombstone(id: UUID) async throws

    func conflict(id: UUID) async throws -> ConflictRecord?
    func queuedConflicts(provider: String?, limit: Int?) async throws -> [ConflictRecord]
    func upsertConflict(_ conflict: ConflictRecord) async throws
    func deleteConflict(id: UUID) async throws

    func syncRun(id: UUID) async throws -> SyncRun?
    func syncRuns(provider: String?, limit: Int?) async throws -> [SyncRun]
    func syncRuns(account: SyncAccount, limit: Int?) async throws -> [SyncRun]
    func upsertSyncRun(_ run: SyncRun) async throws

    /// Removes expired tombstones and completed runs older than the retention window.
    /// Running syncs are never removed. The default retention is 30 days.
    func cleanup(asOf: Date, retention: TimeInterval) async throws -> StoreCleanupResult
    func statistics() async throws -> StoreStatistics
}

public extension LocalStore {
    func upsertMapping(_ mapping: EntityMapping) async throws {
        try await apply(StoreTransaction(mappings: [mapping]))
    }

    func upsertSnapshot(_ snapshot: CanonicalSnapshot) async throws {
        try await apply(StoreTransaction(snapshots: [snapshot]))
    }

    func upsertCursor(_ cursor: ProviderCursor) async throws {
        try await apply(StoreTransaction(cursors: [cursor]))
    }

    func upsertTombstone(_ tombstone: Tombstone) async throws {
        try await apply(StoreTransaction(tombstones: [tombstone]))
    }

    func upsertConflict(_ conflict: ConflictRecord) async throws {
        try await apply(StoreTransaction(conflicts: [conflict]))
    }

    func upsertSyncRun(_ run: SyncRun) async throws {
        try await apply(StoreTransaction(syncRuns: [run]))
    }
}
