import Foundation
import SQLite3
import SyncDomain

/// A SQLite-backed local store. The connection is actor-isolated, so all reads and writes
/// are serialized while multi-table `apply` calls are committed in one SQLite transaction.
public actor SQLiteLocalStore: LocalStore, SyncStateStore {
    public static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60

    private nonisolated(unsafe) var connection: OpaquePointer?

    private init(databasePath: String, isMemory: Bool) throws {
        let handle = try Self.openDatabase(path: databasePath, isMemory: isMemory)
        self.connection = handle
        do {
            try Self.execute(handle, "PRAGMA foreign_keys = ON;")
            try Self.execute(handle, "PRAGMA busy_timeout = 5000;")
            if !isMemory { try Self.execute(handle, "PRAGMA journal_mode = WAL;") }
            try Self.execute(handle, "PRAGMA synchronous = NORMAL;")
            try Self.migrate(handle)
        } catch {
            sqlite3_close(handle)
            self.connection = nil
            throw error
        }
    }

    public init(url: URL) throws {
        try self.init(databasePath: url.path, isMemory: url.path == ":memory:")
    }

    public init(path: String) throws {
        try self.init(databasePath: path, isMemory: path == ":memory:")
    }

    public static func inMemory() throws -> SQLiteLocalStore {
        try SQLiteLocalStore(databasePath: ":memory:", isMemory: true)
    }

    deinit {
        if let connection { sqlite3_close(connection) }
    }

    // MARK: - SyncStateStore

    /// The sync engine owns one canonical state document per SQLite database. The
    /// lower-level LocalStore tables remain available for provider-independent
    /// persistence APIs, while this table is the single engine checkpoint and is
    /// committed atomically by the same SQLite connection.
    public func load() async throws -> SyncState {
        let rows = try query("SELECT payload FROM sync_state WHERE id = 1;")
        guard let row = rows.first else { return SyncState() }
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try decoder.decode(SyncState.self, from: row.blob("payload"))
        } catch {
            throw LocalStoreError.invalidData("Unable to decode canonical sync state: \(error.localizedDescription)")
        }
    }

    public func save(_ state: SyncState) async throws {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(state)
            try execute("""
                INSERT INTO sync_state (id, payload, updated_at)
                VALUES (1, ?, ?)
                ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at;
                """, bindings: [.blob(payload), .double(Date().timeIntervalSince1970)])
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.invalidData("Unable to encode canonical sync state: \(error.localizedDescription)")
        }
    }

    /// Atomically removes account-owned canonical state from the single sync checkpoint.
    /// Lower-level LocalStore rows intentionally remain untouched: those tables have no
    /// account column and are not used by SyncEngine's account-scoped checkpoint.
    public func remove(account: SyncAccount) async throws {
        let current = try await load()
        let next = current.removing(account: account)
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let payload = try encoder.encode(next)
            try beginTransaction()
            do {
                try execute("""
                    INSERT INTO sync_state (id, payload, updated_at)
                    VALUES (1, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET payload = excluded.payload, updated_at = excluded.updated_at;
                    """, bindings: [.blob(payload), .double(Date().timeIntervalSince1970)])
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
        } catch let error as LocalStoreError {
            throw error
        } catch {
            throw LocalStoreError.invalidData("Unable to remove account state: \(error.localizedDescription)")
        }
    }

    // MARK: - LocalStore

    public func apply(_ transaction: StoreTransaction) async throws {
        guard !transaction.isEmpty else { return }
        try beginTransaction()
        do {
            for mapping in transaction.mappings { try upsertMappingSQL(mapping) }
            for snapshot in transaction.snapshots { try upsertSnapshotSQL(snapshot) }
            for cursor in transaction.cursors { try upsertCursorSQL(cursor) }
            for tombstone in transaction.tombstones { try upsertTombstoneSQL(tombstone) }
            for conflict in transaction.conflicts { try upsertConflictSQL(conflict) }
            for run in transaction.syncRuns { try upsertSyncRunSQL(run) }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func mapping(for key: MappingKey) async throws -> EntityMapping? {
        let rows = try query("""
            SELECT id, provider, entity_type, local_id, remote_id, state,
                   local_revision, remote_revision, local_fingerprint, remote_fingerprint,
                   last_synchronized_at, created_at, updated_at
            FROM mappings
            WHERE provider = ? AND entity_type = ? AND local_id = ? AND remote_id = ?;
            """, bindings: [.text(key.provider), .text(key.entityType), .text(key.localID), .text(key.remoteID)])
        return try rows.first.map(mappingFromRow)
    }

    public func mapping(id: UUID) async throws -> EntityMapping? {
        let rows = try query("""
            SELECT id, provider, entity_type, local_id, remote_id, state,
                   local_revision, remote_revision, local_fingerprint, remote_fingerprint,
                   last_synchronized_at, created_at, updated_at
            FROM mappings WHERE id = ?;
            """, bindings: [.text(id.uuidString)])
        return try rows.first.map(mappingFromRow)
    }

    public func mappings(provider: String, entityType: String) async throws -> [EntityMapping] {
        let rows = try query("""
            SELECT id, provider, entity_type, local_id, remote_id, state,
                   local_revision, remote_revision, local_fingerprint, remote_fingerprint,
                   last_synchronized_at, created_at, updated_at
            FROM mappings
            WHERE provider = ? AND entity_type = ?
            ORDER BY updated_at DESC, id ASC;
            """, bindings: [.text(provider), .text(entityType)])
        return try rows.map(mappingFromRow)
    }

    public func upsertMapping(_ mapping: EntityMapping) async throws {
        try await apply(StoreTransaction(mappings: [mapping]))
    }

    public func deleteMapping(for key: MappingKey) async throws {
        try execute("""
            DELETE FROM mappings
            WHERE provider = ? AND entity_type = ? AND local_id = ? AND remote_id = ?;
            """, bindings: [.text(key.provider), .text(key.entityType), .text(key.localID), .text(key.remoteID)])
    }

    public func snapshot(mappingID: UUID, side: SnapshotSide) async throws -> CanonicalSnapshot? {
        let rows = try query("""
            SELECT id, mapping_id, side, payload, content_hash, source_revision, captured_at
            FROM canonical_snapshots WHERE mapping_id = ? AND side = ?;
            """, bindings: [.text(mappingID.uuidString), .text(side.rawValue)])
        return try rows.first.map(snapshotFromRow)
    }

    public func snapshots(mappingID: UUID) async throws -> [CanonicalSnapshot] {
        let rows = try query("""
            SELECT id, mapping_id, side, payload, content_hash, source_revision, captured_at
            FROM canonical_snapshots WHERE mapping_id = ? ORDER BY captured_at DESC, side ASC;
            """, bindings: [.text(mappingID.uuidString)])
        return try rows.map(snapshotFromRow)
    }

    public func upsertSnapshot(_ snapshot: CanonicalSnapshot) async throws {
        try await apply(StoreTransaction(snapshots: [snapshot]))
    }

    public func deleteSnapshots(mappingID: UUID) async throws {
        try execute("DELETE FROM canonical_snapshots WHERE mapping_id = ?;", bindings: [.text(mappingID.uuidString)])
    }

    public func cursor(for key: ProviderCursorKey) async throws -> ProviderCursor? {
        let rows = try query("""
            SELECT provider, scope, value, updated_at
            FROM provider_cursors WHERE provider = ? AND scope = ?;
            """, bindings: [.text(key.provider), .text(key.scope)])
        return try rows.first.map(cursorFromRow)
    }

    public func upsertCursor(_ cursor: ProviderCursor) async throws {
        try await apply(StoreTransaction(cursors: [cursor]))
    }

    public func deleteCursor(for key: ProviderCursorKey) async throws {
        try execute("DELETE FROM provider_cursors WHERE provider = ? AND scope = ?;", bindings: [.text(key.provider), .text(key.scope)])
    }

    public func tombstone(
        forProvider provider: String,
        entityType: String,
        localID: String?,
        remoteID: String?,
        side: TombstoneSide
    ) async throws -> Tombstone? {
        let rows = try query("""
            SELECT id, provider, entity_type, local_id, remote_id, side, reason,
                   deleted_at, expires_at, metadata
            FROM tombstones
            WHERE provider = ? AND entity_type = ?
              AND local_id_key = ? AND remote_id_key = ? AND side = ?;
            """, bindings: [
                .text(provider), .text(entityType), .text(localID ?? ""), .text(remoteID ?? ""), .text(side.rawValue)
            ])
        return try rows.first.map(tombstoneFromRow)
    }

    public func tombstones(provider: String, entityType: String, includeExpired: Bool = false, asOf: Date = Date()) async throws -> [Tombstone] {
        var sql = """
            SELECT id, provider, entity_type, local_id, remote_id, side, reason,
                   deleted_at, expires_at, metadata
            FROM tombstones WHERE provider = ? AND entity_type = ?
            """
        var bindings: [SQLiteBinding] = [.text(provider), .text(entityType)]
        if !includeExpired {
            sql += " AND expires_at > ?"
            bindings.append(.double(asOf.timeIntervalSince1970))
        }
        sql += " ORDER BY deleted_at DESC, id ASC;"
        let rows = try query(sql, bindings: bindings)
        return try rows.map(tombstoneFromRow)
    }

    public func upsertTombstone(_ tombstone: Tombstone) async throws {
        try await apply(StoreTransaction(tombstones: [tombstone]))
    }

    public func deleteTombstone(id: UUID) async throws {
        try execute("DELETE FROM tombstones WHERE id = ?;", bindings: [.text(id.uuidString)])
    }

    public func conflict(id: UUID) async throws -> ConflictRecord? {
        let rows = try query(Self.conflictSelect + " WHERE id = ?;", bindings: [.text(id.uuidString)])
        return try rows.first.map(conflictFromRow)
    }

    public func queuedConflicts(provider: String? = nil, limit: Int? = nil) async throws -> [ConflictRecord] {
        var sql = Self.conflictSelect + " WHERE status = ?"
        var bindings: [SQLiteBinding] = [.text(ConflictStatus.queued.rawValue)]
        if let provider {
            sql += " AND provider = ?"
            bindings.append(.text(provider))
        }
        sql += " ORDER BY detected_at ASC, id ASC"
        if let limit {
            sql += " LIMIT \(max(0, limit))"
        }
        sql += ";"
        let rows = try query(sql, bindings: bindings)
        return try rows.map(conflictFromRow)
    }

    public func upsertConflict(_ conflict: ConflictRecord) async throws {
        try await apply(StoreTransaction(conflicts: [conflict]))
    }

    public func deleteConflict(id: UUID) async throws {
        try execute("DELETE FROM conflicts WHERE id = ?;", bindings: [.text(id.uuidString)])
    }

    public func syncRun(id: UUID) async throws -> SyncRun? {
        let rows = try query(Self.syncRunSelect + " WHERE id = ?;", bindings: [.text(id.uuidString)])
        return try rows.first.map(syncRunFromRow)
    }

    public func syncRuns(provider: String? = nil, limit: Int? = nil) async throws -> [SyncRun] {
        var sql = Self.syncRunSelect
        var bindings: [SQLiteBinding] = []
        if let provider {
            sql += " WHERE provider = ?"
            bindings.append(.text(provider))
        }
        sql += " ORDER BY started_at DESC, id DESC"
        if let limit {
            sql += " LIMIT \(max(0, limit))"
        }
        sql += ";"
        let rows = try query(sql, bindings: bindings)
        return try rows.map(syncRunFromRow)
    }

    public func upsertSyncRun(_ run: SyncRun) async throws {
        try await apply(StoreTransaction(syncRuns: [run]))
    }

    public func cleanup(asOf: Date = Date(), retention: TimeInterval = SQLiteLocalStore.defaultRetention) async throws -> StoreCleanupResult {
        guard retention >= 0 else { throw LocalStoreError.invalidConfiguration("retention must be non-negative") }
        let cutoff = asOf.timeIntervalSince1970 - retention
        try beginTransaction()
        do {
            try execute("DELETE FROM tombstones WHERE expires_at <= ?;", bindings: [.double(asOf.timeIntervalSince1970)])
            let tombstonesRemoved = Int(sqlite3_changes(try requireConnection()))
            try execute("""
                DELETE FROM sync_runs
                WHERE finished_at IS NOT NULL AND finished_at <= ?
                  AND status IN ('succeeded', 'partiallySucceeded', 'failed', 'cancelled');
                """, bindings: [.double(cutoff)])
            let completedRunsRemoved = Int(sqlite3_changes(try requireConnection()))
            try execute("COMMIT;")
            return StoreCleanupResult(tombstonesRemoved: tombstonesRemoved, completedRunsRemoved: completedRunsRemoved)
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    public func statistics() async throws -> StoreStatistics {
        func count(_ table: String) throws -> Int {
            let rows = try query("SELECT COUNT(*) AS count FROM \(table);")
            guard let value = try rows.first?.int("count") else { throw LocalStoreError.invalidData("Missing count for \(table)") }
            return value
        }
        return StoreStatistics(
            mappings: try count("mappings"),
            snapshots: try count("canonical_snapshots"),
            cursors: try count("provider_cursors"),
            tombstones: try count("tombstones"),
            conflicts: try count("conflicts"),
            syncRuns: try count("sync_runs")
        )
    }

    // MARK: - SQL writes

    private func upsertMappingSQL(_ mapping: EntityMapping) throws {
        try execute("""
            INSERT INTO mappings (
                id, provider, entity_type, local_id, remote_id, state,
                local_revision, remote_revision, local_fingerprint, remote_fingerprint,
                last_synchronized_at, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, entity_type, local_id, remote_id) DO UPDATE SET
                state = excluded.state,
                local_revision = excluded.local_revision,
                remote_revision = excluded.remote_revision,
                local_fingerprint = excluded.local_fingerprint,
                remote_fingerprint = excluded.remote_fingerprint,
                last_synchronized_at = excluded.last_synchronized_at,
                created_at = excluded.created_at,
                updated_at = excluded.updated_at;
            """, bindings: [
                .text(mapping.id.uuidString), .text(mapping.key.provider), .text(mapping.key.entityType),
                .text(mapping.key.localID), .text(mapping.key.remoteID), .text(mapping.state.rawValue),
                .optionalText(mapping.localRevision), .optionalText(mapping.remoteRevision),
                .optionalText(mapping.localFingerprint), .optionalText(mapping.remoteFingerprint),
                .optionalDate(mapping.lastSynchronizedAt), .double(mapping.createdAt.timeIntervalSince1970),
                .double(mapping.updatedAt.timeIntervalSince1970)
            ])
    }

    private func upsertSnapshotSQL(_ snapshot: CanonicalSnapshot) throws {
        try execute("""
            INSERT INTO canonical_snapshots (
                id, mapping_id, side, payload, content_hash, source_revision, captured_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(mapping_id, side) DO UPDATE SET
                id = excluded.id,
                payload = excluded.payload,
                content_hash = excluded.content_hash,
                source_revision = excluded.source_revision,
                captured_at = excluded.captured_at;
            """, bindings: [
                .text(snapshot.id.uuidString), .text(snapshot.mappingID.uuidString), .text(snapshot.side.rawValue),
                .blob(snapshot.payload), .text(snapshot.contentHash), .optionalText(snapshot.sourceRevision),
                .double(snapshot.capturedAt.timeIntervalSince1970)
            ])
    }

    private func upsertCursorSQL(_ cursor: ProviderCursor) throws {
        try execute("""
            INSERT INTO provider_cursors (provider, scope, value, updated_at)
            VALUES (?, ?, ?, ?)
            ON CONFLICT(provider, scope) DO UPDATE SET
                value = excluded.value,
                updated_at = excluded.updated_at;
            """, bindings: [
                .text(cursor.key.provider), .text(cursor.key.scope), .text(cursor.value),
                .double(cursor.updatedAt.timeIntervalSince1970)
            ])
    }

    private func upsertTombstoneSQL(_ tombstone: Tombstone) throws {
        try execute("""
            INSERT INTO tombstones (
                id, provider, entity_type, local_id, remote_id, local_id_key, remote_id_key,
                side, reason, deleted_at, expires_at, metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(provider, entity_type, local_id_key, remote_id_key, side) DO UPDATE SET
                id = excluded.id,
                local_id = excluded.local_id,
                remote_id = excluded.remote_id,
                reason = excluded.reason,
                deleted_at = excluded.deleted_at,
                expires_at = excluded.expires_at,
                metadata = excluded.metadata;
            """, bindings: [
                .text(tombstone.id.uuidString), .text(tombstone.provider), .text(tombstone.entityType),
                .optionalText(tombstone.localID), .optionalText(tombstone.remoteID), .text(tombstone.localID ?? ""),
                .text(tombstone.remoteID ?? ""), .text(tombstone.side.rawValue), .optionalText(tombstone.reason),
                .double(tombstone.deletedAt.timeIntervalSince1970), .double(tombstone.expiresAt.timeIntervalSince1970),
                .optionalBlob(tombstone.metadata)
            ])
    }

    private func upsertConflictSQL(_ conflict: ConflictRecord) throws {
        try execute("""
            INSERT INTO conflicts (
                id, mapping_id, provider, entity_type, local_id, remote_id,
                local_payload, remote_payload, local_revision, remote_revision,
                detected_at, status, resolution_payload, resolved_at, last_error, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                mapping_id = excluded.mapping_id,
                provider = excluded.provider,
                entity_type = excluded.entity_type,
                local_id = excluded.local_id,
                remote_id = excluded.remote_id,
                local_payload = excluded.local_payload,
                remote_payload = excluded.remote_payload,
                local_revision = excluded.local_revision,
                remote_revision = excluded.remote_revision,
                detected_at = excluded.detected_at,
                status = excluded.status,
                resolution_payload = excluded.resolution_payload,
                resolved_at = excluded.resolved_at,
                last_error = excluded.last_error,
                updated_at = excluded.updated_at;
            """, bindings: [
                .text(conflict.id.uuidString), .optionalText(conflict.mappingID?.uuidString), .text(conflict.key.provider),
                .text(conflict.key.entityType), .text(conflict.key.localID), .text(conflict.key.remoteID),
                .blob(conflict.localPayload), .blob(conflict.remotePayload), .optionalText(conflict.localRevision),
                .optionalText(conflict.remoteRevision), .double(conflict.detectedAt.timeIntervalSince1970),
                .text(conflict.status.rawValue), .optionalBlob(conflict.resolutionPayload),
                .optionalDate(conflict.resolvedAt), .optionalText(conflict.lastError),
                .double(conflict.updatedAt.timeIntervalSince1970)
            ])
    }

    private func upsertSyncRunSQL(_ run: SyncRun) throws {
        try execute("""
            INSERT INTO sync_runs (
                id, provider, started_at, finished_at, status, scanned_count, created_count,
                updated_count, deleted_count, conflict_count, error_message, metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                provider = excluded.provider,
                started_at = excluded.started_at,
                finished_at = excluded.finished_at,
                status = excluded.status,
                scanned_count = excluded.scanned_count,
                created_count = excluded.created_count,
                updated_count = excluded.updated_count,
                deleted_count = excluded.deleted_count,
                conflict_count = excluded.conflict_count,
                error_message = excluded.error_message,
                metadata = excluded.metadata;
            """, bindings: [
                .text(run.id.uuidString), .text(run.provider), .double(run.startedAt.timeIntervalSince1970),
                .optionalDate(run.finishedAt), .text(run.status.rawValue), .int(run.scannedCount), .int(run.createdCount),
                .int(run.updatedCount), .int(run.deletedCount), .int(run.conflictCount), .optionalText(run.errorMessage),
                .optionalBlob(run.metadata)
            ])
    }

    // MARK: - Migrations and SQLite primitives

    private static func openDatabase(path: String, isMemory: Bool) throws -> OpaquePointer {
        if !isMemory {
            let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path, &handle, flags, nil)
        guard result == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            if let handle { sqlite3_close(handle) }
            throw LocalStoreError.sqlite(code: result, message: message)
        }
        return handle
    }

    private static func migrate(_ handle: OpaquePointer) throws {
        try execute(handle, """
            CREATE TABLE IF NOT EXISTS schema_migrations (
                version INTEGER PRIMARY KEY NOT NULL,
                applied_at REAL NOT NULL
            );
            """)
        let rows = try query(handle, "SELECT COALESCE(MAX(version), 0) AS version FROM schema_migrations;")
        let current = try rows.first?.int("version") ?? 0
        for migration in Self.migrations where migration.version > current {
            try execute(handle, "BEGIN IMMEDIATE;")
            do {
                try executeScript(handle, migration.sql)
                try execute(handle, "INSERT INTO schema_migrations(version, applied_at) VALUES (?, ?);", bindings: [
                    .int(migration.version), .double(Date().timeIntervalSince1970)
                ])
                try execute(handle, "COMMIT;")
            } catch {
                try? execute(handle, "ROLLBACK;")
                throw LocalStoreError.migrationFailed(version: migration.version, underlying: String(describing: error))
            }
        }
    }

    private static let migrations: [(version: Int, sql: String)] = [(1, """
        CREATE TABLE IF NOT EXISTS mappings (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            local_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            state TEXT NOT NULL,
            local_revision TEXT,
            remote_revision TEXT,
            local_fingerprint TEXT,
            remote_fingerprint TEXT,
            last_synchronized_at REAL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            UNIQUE(provider, entity_type, local_id, remote_id)
        );
        CREATE INDEX IF NOT EXISTS idx_mappings_provider_type ON mappings(provider, entity_type, updated_at DESC);

        CREATE TABLE IF NOT EXISTS canonical_snapshots (
            id TEXT PRIMARY KEY NOT NULL,
            mapping_id TEXT NOT NULL REFERENCES mappings(id) ON DELETE CASCADE,
            side TEXT NOT NULL,
            payload BLOB NOT NULL,
            content_hash TEXT NOT NULL,
            source_revision TEXT,
            captured_at REAL NOT NULL,
            UNIQUE(mapping_id, side)
        );
        CREATE INDEX IF NOT EXISTS idx_snapshots_mapping ON canonical_snapshots(mapping_id, captured_at DESC);

        CREATE TABLE IF NOT EXISTS provider_cursors (
            provider TEXT NOT NULL,
            scope TEXT NOT NULL,
            value TEXT NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(provider, scope)
        );

        CREATE TABLE IF NOT EXISTS tombstones (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            local_id TEXT,
            remote_id TEXT,
            local_id_key TEXT NOT NULL,
            remote_id_key TEXT NOT NULL,
            side TEXT NOT NULL,
            reason TEXT,
            deleted_at REAL NOT NULL,
            expires_at REAL NOT NULL,
            metadata BLOB,
            UNIQUE(provider, entity_type, local_id_key, remote_id_key, side)
        );
        CREATE INDEX IF NOT EXISTS idx_tombstones_expiration ON tombstones(expires_at);

        CREATE TABLE IF NOT EXISTS conflicts (
            id TEXT PRIMARY KEY NOT NULL,
            mapping_id TEXT REFERENCES mappings(id) ON DELETE SET NULL,
            provider TEXT NOT NULL,
            entity_type TEXT NOT NULL,
            local_id TEXT NOT NULL,
            remote_id TEXT NOT NULL,
            local_payload BLOB NOT NULL,
            remote_payload BLOB NOT NULL,
            local_revision TEXT,
            remote_revision TEXT,
            detected_at REAL NOT NULL,
            status TEXT NOT NULL,
            resolution_payload BLOB,
            resolved_at REAL,
            last_error TEXT,
            updated_at REAL NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_conflicts_queue ON conflicts(status, detected_at ASC);
        CREATE INDEX IF NOT EXISTS idx_conflicts_provider ON conflicts(provider, status, detected_at ASC);

        CREATE TABLE IF NOT EXISTS sync_runs (
            id TEXT PRIMARY KEY NOT NULL,
            provider TEXT NOT NULL,
            started_at REAL NOT NULL,
            finished_at REAL,
            status TEXT NOT NULL,
            scanned_count INTEGER NOT NULL DEFAULT 0,
            created_count INTEGER NOT NULL DEFAULT 0,
            updated_count INTEGER NOT NULL DEFAULT 0,
            deleted_count INTEGER NOT NULL DEFAULT 0,
            conflict_count INTEGER NOT NULL DEFAULT 0,
            error_message TEXT,
            metadata BLOB
        );
        CREATE INDEX IF NOT EXISTS idx_sync_runs_provider_started ON sync_runs(provider, started_at DESC);
        CREATE INDEX IF NOT EXISTS idx_sync_runs_cleanup ON sync_runs(finished_at, status);
        """), (2, """
        CREATE TABLE IF NOT EXISTS sync_state (
            id INTEGER PRIMARY KEY CHECK (id = 1),
            payload BLOB NOT NULL,
            updated_at REAL NOT NULL
        );
        """)]

    private enum SQLiteBinding {
        case null
        case text(String)
        case int(Int)
        case double(Double)
        case blob(Data)
        case optionalText(String?)
        case optionalDate(Date?)
        case optionalBlob(Data?)

        var resolved: SQLiteBinding {
            switch self {
            case .optionalText(let value): return value.map(SQLiteBinding.text) ?? .null
            case .optionalDate(let value): return value.map { .double($0.timeIntervalSince1970) } ?? .null
            case .optionalBlob(let value): return value.map(SQLiteBinding.blob) ?? .null
            default: return self
            }
        }
    }

    private static func executeScript(_ handle: OpaquePointer, _ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw LocalStoreError.sqlite(code: result, message: message)
        }
    }

    private static func execute(_ handle: OpaquePointer, _ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(handle, sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, handle: handle)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw sqliteError(result, handle: handle)
        }
    }

    private static func query(_ handle: OpaquePointer, _ sql: String, bindings: [SQLiteBinding] = []) throws -> [SQLiteRow] {
        let statement = try prepare(handle, sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement, handle: handle)
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(SQLiteRow(statement: statement))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw sqliteError(result, handle: handle)
            }
        }
    }

    private static func prepare(_ handle: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(result, handle: handle) }
        return statement
    }

    private static func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer, handle: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value.resolved {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .int(let integer):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .optionalText, .optionalDate, .optionalBlob:
                throw LocalStoreError.invalidConfiguration("Optional binding must be resolved before binding")
            }
            guard result == SQLITE_OK else { throw sqliteError(result, handle: handle) }
        }
    }

    private static func sqliteError(_ result: Int32, handle: OpaquePointer) -> LocalStoreError {
        .sqlite(code: result, message: String(cString: sqlite3_errmsg(handle)))
    }

    private func requireConnection() throws -> OpaquePointer {
        guard let connection else { throw LocalStoreError.unavailable("database connection is closed") }
        return connection
    }

    private func beginTransaction() throws {
        try execute("BEGIN IMMEDIATE;")
    }

    private func execute(_ sql: String, bindings: [SQLiteBinding] = []) throws {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw sqliteError(result)
        }
    }

    private func query(_ sql: String, bindings: [SQLiteBinding] = []) throws -> [SQLiteRow] {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [SQLiteRow] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(SQLiteRow(statement: statement))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw sqliteError(result)
            }
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let connection = try requireConnection()
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { throw sqliteError(result) }
        return statement
    }

    private func bind(_ bindings: [SQLiteBinding], to statement: OpaquePointer) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value.resolved {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .int(let integer):
                result = sqlite3_bind_int64(statement, index, sqlite3_int64(integer))
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .blob(let data):
                result = data.withUnsafeBytes { bytes in
                    sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(data.count), SQLITE_TRANSIENT)
                }
            case .optionalText, .optionalDate, .optionalBlob:
                throw LocalStoreError.invalidConfiguration("Optional binding must be resolved before binding")
            }
            guard result == SQLITE_OK else { throw sqliteError(result) }
        }
    }

    private func sqliteError(_ result: Int32) -> LocalStoreError {
        let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown sqlite error"
        return .sqlite(code: result, message: message)
    }

    // MARK: - Row conversion

    private func mappingFromRow(_ row: SQLiteRow) throws -> EntityMapping {
        EntityMapping(
            id: try row.uuid("id"),
            key: MappingKey(provider: try row.text("provider"), entityType: try row.text("entity_type"), localID: try row.text("local_id"), remoteID: try row.text("remote_id")),
            state: try row.enumValue("state", as: MappingState.self),
            localRevision: row.optionalText("local_revision"),
            remoteRevision: row.optionalText("remote_revision"),
            localFingerprint: row.optionalText("local_fingerprint"),
            remoteFingerprint: row.optionalText("remote_fingerprint"),
            lastSynchronizedAt: row.optionalDate("last_synchronized_at"),
            createdAt: try row.date("created_at"),
            updatedAt: try row.date("updated_at")
        )
    }

    private func snapshotFromRow(_ row: SQLiteRow) throws -> CanonicalSnapshot {
        CanonicalSnapshot(
            id: try row.uuid("id"), mappingID: try row.uuid("mapping_id"),
            side: try row.enumValue("side", as: SnapshotSide.self), payload: try row.blob("payload"),
            contentHash: try row.text("content_hash"), sourceRevision: row.optionalText("source_revision"),
            capturedAt: try row.date("captured_at")
        )
    }

    private func cursorFromRow(_ row: SQLiteRow) throws -> ProviderCursor {
        ProviderCursor(key: ProviderCursorKey(provider: try row.text("provider"), scope: try row.text("scope")), value: try row.text("value"), updatedAt: try row.date("updated_at"))
    }

    private func tombstoneFromRow(_ row: SQLiteRow) throws -> Tombstone {
        Tombstone(
            id: try row.uuid("id"), provider: try row.text("provider"), entityType: try row.text("entity_type"),
            localID: row.optionalText("local_id"), remoteID: row.optionalText("remote_id"), side: try row.enumValue("side", as: TombstoneSide.self),
            reason: row.optionalText("reason"), deletedAt: try row.date("deleted_at"), expiresAt: try row.date("expires_at"),
            metadata: row.optionalBlob("metadata")
        )
    }

    private func conflictFromRow(_ row: SQLiteRow) throws -> ConflictRecord {
        ConflictRecord(
            id: try row.uuid("id"), mappingID: row.optionalUUID("mapping_id"),
            key: MappingKey(provider: try row.text("provider"), entityType: try row.text("entity_type"), localID: try row.text("local_id"), remoteID: try row.text("remote_id")),
            localPayload: try row.blob("local_payload"), remotePayload: try row.blob("remote_payload"),
            localRevision: row.optionalText("local_revision"), remoteRevision: row.optionalText("remote_revision"),
            detectedAt: try row.date("detected_at"), status: try row.enumValue("status", as: ConflictStatus.self),
            resolutionPayload: row.optionalBlob("resolution_payload"), resolvedAt: row.optionalDate("resolved_at"),
            lastError: row.optionalText("last_error"), updatedAt: try row.date("updated_at")
        )
    }

    private func syncRunFromRow(_ row: SQLiteRow) throws -> SyncRun {
        SyncRun(
            id: try row.uuid("id"), provider: try row.text("provider"), startedAt: try row.date("started_at"),
            finishedAt: row.optionalDate("finished_at"), status: try row.enumValue("status", as: SyncRunStatus.self),
            scannedCount: try row.int("scanned_count"), createdCount: try row.int("created_count"), updatedCount: try row.int("updated_count"),
            deletedCount: try row.int("deleted_count"), conflictCount: try row.int("conflict_count"),
            errorMessage: row.optionalText("error_message"), metadata: row.optionalBlob("metadata")
        )
    }

    private static let conflictSelect = """
        SELECT id, mapping_id, provider, entity_type, local_id, remote_id,
               local_payload, remote_payload, local_revision, remote_revision,
               detected_at, status, resolution_payload, resolved_at, last_error, updated_at
        FROM conflicts
        """

    private static let syncRunSelect = """
        SELECT id, provider, started_at, finished_at, status, scanned_count, created_count,
               updated_count, deleted_count, conflict_count, error_message, metadata
        FROM sync_runs
        """
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private struct SQLiteRow {
    private let values: [String: SQLiteCell]

    init(statement: OpaquePointer) {
        var values: [String: SQLiteCell] = [:]
        let count = sqlite3_column_count(statement)
        for index in 0..<count {
            guard let name = sqlite3_column_name(statement, index) else { continue }
            values[String(cString: name)] = SQLiteCell(statement: statement, index: index)
        }
        self.values = values
    }

    func text(_ name: String) throws -> String {
        guard let value = values[name], case .text(let text) = value else { throw LocalStoreError.invalidData("Missing text column \(name)") }
        return text
    }

    func optionalText(_ name: String) -> String? {
        guard let value = values[name], case .text(let text) = value else { return nil }
        return text
    }

    func int(_ name: String) throws -> Int {
        guard let value = values[name], case .integer(let integer) = value else { throw LocalStoreError.invalidData("Missing integer column \(name)") }
        return integer
    }

    func date(_ name: String) throws -> Date {
        Date(timeIntervalSince1970: try double(name))
    }

    func optionalDate(_ name: String) -> Date? {
        guard let value = values[name], case .real(let real) = value else { return nil }
        return Date(timeIntervalSince1970: real)
    }

    func double(_ name: String) throws -> Double {
        guard let value = values[name] else { throw LocalStoreError.invalidData("Missing numeric column \(name)") }
        switch value {
        case .real(let real): return real
        case .integer(let integer): return Double(integer)
        default: throw LocalStoreError.invalidData("Invalid numeric column \(name)")
        }
    }

    func blob(_ name: String) throws -> Data {
        guard let value = values[name], case .blob(let data) = value else { throw LocalStoreError.invalidData("Missing blob column \(name)") }
        return data
    }

    func optionalBlob(_ name: String) -> Data? {
        guard let value = values[name], case .blob(let data) = value else { return nil }
        return data
    }

    func uuid(_ name: String) throws -> UUID {
        guard let uuid = UUID(uuidString: try text(name)) else { throw LocalStoreError.invalidData("Invalid UUID in \(name)") }
        return uuid
    }

    func optionalUUID(_ name: String) -> UUID? {
        guard let value = optionalText(name) else { return nil }
        return UUID(uuidString: value)
    }

    func enumValue<T: RawRepresentable>(_ name: String, as type: T.Type) throws -> T where T.RawValue == String {
        guard let result = T(rawValue: try text(name)) else { throw LocalStoreError.invalidData("Invalid \(name) value") }
        return result
    }
}

private enum SQLiteCell {
    case null
    case integer(Int)
    case real(Double)
    case text(String)
    case blob(Data)

    init(statement: OpaquePointer, index: Int32) {
        switch sqlite3_column_type(statement, index) {
        case SQLITE_INTEGER: self = .integer(Int(sqlite3_column_int64(statement, index)))
        case SQLITE_FLOAT: self = .real(sqlite3_column_double(statement, index))
        case SQLITE_TEXT:
            self = sqlite3_column_text(statement, index).map { .text(String(cString: $0)) } ?? .null
        case SQLITE_BLOB:
            let count = Int(sqlite3_column_bytes(statement, index))
            if count == 0 { self = .blob(Data()) }
            else if let bytes = sqlite3_column_blob(statement, index) { self = .blob(Data(bytes: bytes, count: count)) }
            else { self = .null }
        default: self = .null
        }
    }
}
