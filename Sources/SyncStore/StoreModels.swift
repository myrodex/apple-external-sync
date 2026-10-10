import Foundation
import SyncDomain

/// The side of a synchronization relationship represented by a canonical snapshot.
public enum SnapshotSide: String, Codable, Sendable, CaseIterable {
    case local
    case remote
    case canonical
}

/// A stable identifier for an item in a provider or in the local data model.
public struct StoreEntityKey: Codable, Hashable, Sendable {
    public let provider: String
    public let entityType: String
    public let entityID: String

    public init(provider: String, entityType: String, entityID: String) {
        self.provider = provider
        self.entityType = entityType
        self.entityID = entityID
    }
}

/// The key used to locate a mapping between a local record and a provider record.
public struct MappingKey: Codable, Hashable, Sendable {
    public let provider: String
    public let entityType: String
    public let localID: String
    public let remoteID: String

    public init(provider: String, entityType: String, localID: String, remoteID: String) {
        self.provider = provider
        self.entityType = entityType
        self.localID = localID
        self.remoteID = remoteID
    }
}

public enum MappingState: String, Codable, Sendable, CaseIterable {
    case active
    case pendingDeletion
    case deleted
}

/// The durable relationship between an app record and an external provider record.
public struct EntityMapping: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let key: MappingKey
    public var state: MappingState
    public var localRevision: String?
    public var remoteRevision: String?
    public var localFingerprint: String?
    public var remoteFingerprint: String?
    public var lastSynchronizedAt: Date?
    public let createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        key: MappingKey,
        state: MappingState = .active,
        localRevision: String? = nil,
        remoteRevision: String? = nil,
        localFingerprint: String? = nil,
        remoteFingerprint: String? = nil,
        lastSynchronizedAt: Date? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.key = key
        self.state = state
        self.localRevision = localRevision
        self.remoteRevision = remoteRevision
        self.localFingerprint = localFingerprint
        self.remoteFingerprint = remoteFingerprint
        self.lastSynchronizedAt = lastSynchronizedAt
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A last-known canonical representation. Payloads are intentionally opaque to the store.
public struct CanonicalSnapshot: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let mappingID: UUID
    public let side: SnapshotSide
    public let payload: Data
    public let contentHash: String
    public let sourceRevision: String?
    public let capturedAt: Date

    public init(
        id: UUID = UUID(),
        mappingID: UUID,
        side: SnapshotSide = .canonical,
        payload: Data,
        contentHash: String,
        sourceRevision: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.id = id
        self.mappingID = mappingID
        self.side = side
        self.payload = payload
        self.contentHash = contentHash
        self.sourceRevision = sourceRevision
        self.capturedAt = capturedAt
    }
}

public struct ProviderCursorKey: Codable, Hashable, Sendable {
    public let provider: String
    public let scope: String

    public init(provider: String, scope: String) {
        self.provider = provider
        self.scope = scope
    }
}

/// An opaque provider pagination/change-feed cursor.
public struct ProviderCursor: Codable, Hashable, Sendable {
    public let key: ProviderCursorKey
    public let value: String
    public let updatedAt: Date

    public init(key: ProviderCursorKey, value: String, updatedAt: Date = Date()) {
        self.key = key
        self.value = value
        self.updatedAt = updatedAt
    }
}

public enum TombstoneSide: String, Codable, Sendable, CaseIterable {
    case local
    case remote
    case mapping
}

/// A deletion marker retained long enough to prevent a reappearing record from being recreated.
public struct Tombstone: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let provider: String
    public let entityType: String
    public let localID: String?
    public let remoteID: String?
    public let side: TombstoneSide
    public let reason: String?
    public let deletedAt: Date
    public let expiresAt: Date
    public let metadata: Data?

    public init(
        id: UUID = UUID(),
        provider: String,
        entityType: String,
        localID: String? = nil,
        remoteID: String? = nil,
        side: TombstoneSide,
        reason: String? = nil,
        deletedAt: Date = Date(),
        expiresAt: Date? = nil,
        retention: TimeInterval = 30 * 24 * 60 * 60,
        metadata: Data? = nil
    ) {
        self.id = id
        self.provider = provider
        self.entityType = entityType
        self.localID = localID
        self.remoteID = remoteID
        self.side = side
        self.reason = reason
        self.deletedAt = deletedAt
        self.expiresAt = expiresAt ?? deletedAt.addingTimeInterval(retention)
        self.metadata = metadata
    }
}

public enum ConflictStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case inProgress
    case resolved
    case ignored
}

/// A conflict waiting for an explicit or policy-driven resolution.
public struct ConflictRecord: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let mappingID: UUID?
    public let key: MappingKey
    public let localPayload: Data
    public let remotePayload: Data
    public let localRevision: String?
    public let remoteRevision: String?
    public let detectedAt: Date
    public var status: ConflictStatus
    public var resolutionPayload: Data?
    public var resolvedAt: Date?
    public var lastError: String?
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        mappingID: UUID? = nil,
        key: MappingKey,
        localPayload: Data,
        remotePayload: Data,
        localRevision: String? = nil,
        remoteRevision: String? = nil,
        detectedAt: Date = Date(),
        status: ConflictStatus = .queued,
        resolutionPayload: Data? = nil,
        resolvedAt: Date? = nil,
        lastError: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.mappingID = mappingID
        self.key = key
        self.localPayload = localPayload
        self.remotePayload = remotePayload
        self.localRevision = localRevision
        self.remoteRevision = remoteRevision
        self.detectedAt = detectedAt
        self.status = status
        self.resolutionPayload = resolutionPayload
        self.resolvedAt = resolvedAt
        self.lastError = lastError
        self.updatedAt = updatedAt
    }
}

public enum SyncRunStatus: String, Codable, Sendable, CaseIterable {
    case running
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled
}

public extension SyncRunStatus {
    static let defaultRetention: TimeInterval = 30 * 24 * 60 * 60
}

/// A durable audit record for one sync invocation.
public struct SyncRun: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    /// Provider identifier retained as a string because `LocalStore` supports providers
    /// outside the built-in `SyncProvider` enum.
    public let provider: String
    /// Stable provider-account identity. Runs are never queried by provider alone: two
    /// accounts on the same provider must not reveal one another's history.
    public let accountID: String
    public let startedAt: Date
    public var finishedAt: Date?
    public var status: SyncRunStatus
    public var scannedCount: Int
    public var createdCount: Int
    public var updatedCount: Int
    public var deletedCount: Int
    public var conflictCount: Int
    public var errorMessage: String?
    public var metadata: Data?

    public init(
        id: UUID = UUID(),
        account: SyncAccount,
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: SyncRunStatus = .running,
        scannedCount: Int = 0,
        createdCount: Int = 0,
        updatedCount: Int = 0,
        deletedCount: Int = 0,
        conflictCount: Int = 0,
        errorMessage: String? = nil,
        metadata: Data? = nil
    ) {
        self.init(
            id: id,
            provider: account.provider.rawValue,
            accountID: account.accountID,
            startedAt: startedAt,
            finishedAt: finishedAt,
            status: status,
            scannedCount: scannedCount,
            createdCount: createdCount,
            updatedCount: updatedCount,
            deletedCount: deletedCount,
            conflictCount: conflictCount,
            errorMessage: errorMessage,
            metadata: metadata
        )
    }

    public var accountKey: String { "\(provider):\(accountID)" }

    public init(
        id: UUID = UUID(),
        provider: String,
        accountID: String = "",
        startedAt: Date = Date(),
        finishedAt: Date? = nil,
        status: SyncRunStatus = .running,
        scannedCount: Int = 0,
        createdCount: Int = 0,
        updatedCount: Int = 0,
        deletedCount: Int = 0,
        conflictCount: Int = 0,
        errorMessage: String? = nil,
        metadata: Data? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accountID = accountID
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.scannedCount = scannedCount
        self.createdCount = createdCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.conflictCount = conflictCount
        self.errorMessage = errorMessage
        self.metadata = metadata
    }
}

public struct StoreCleanupResult: Codable, Hashable, Sendable {
    public let tombstonesRemoved: Int
    public let completedRunsRemoved: Int

    public init(tombstonesRemoved: Int, completedRunsRemoved: Int) {
        self.tombstonesRemoved = tombstonesRemoved
        self.completedRunsRemoved = completedRunsRemoved
    }
}

public struct StoreStatistics: Codable, Hashable, Sendable {
    public let mappings: Int
    public let snapshots: Int
    public let cursors: Int
    public let tombstones: Int
    public let conflicts: Int
    public let syncRuns: Int

    public init(mappings: Int, snapshots: Int, cursors: Int, tombstones: Int, conflicts: Int, syncRuns: Int) {
        self.mappings = mappings
        self.snapshots = snapshots
        self.cursors = cursors
        self.tombstones = tombstones
        self.conflicts = conflicts
        self.syncRuns = syncRuns
    }
}
