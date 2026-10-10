import Foundation

/// Stable identifier for a record in the canonical local model.
public struct SyncID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init() {
        self.rawValue = UUID()
    }

    public init(_ rawValue: UUID) {
        self.rawValue = rawValue
    }

    public init?(string: String) {
        guard let uuid = UUID(uuidString: string) else { return nil }
        self.rawValue = uuid
    }

    /// Creates a stable UUID without relying on a provider-generated identifier.
    /// This is used when a remote provider does not carry a canonical ID.
    public static func deterministic(namespace: String) -> SyncID {
        // Two independent FNV-1a streams provide a stable 128-bit identifier.
        // A cryptographic identifier is not needed here: this is identity derivation,
        // not an integrity or secrecy boundary.
        let bytes = Array(namespace.utf8)
        var first: UInt64 = 0xcbf29ce484222325
        var second: UInt64 = 0x84222325cbf29ce4
        for byte in bytes {
            first ^= UInt64(byte)
            first &*= 0x100000001b3
            second ^= UInt64(byte &+ 31)
            second &*= 0x100000001b3
        }
        var uuidBytes = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            uuidBytes[index] = UInt8((first >> UInt64(index * 8)) & 0xff)
            uuidBytes[index + 8] = UInt8((second >> UInt64(index * 8)) & 0xff)
        }
        // RFC 4122 variant + version 5 make the value recognizable as a UUID
        // while preserving deterministic identity.
        uuidBytes[6] = (uuidBytes[6] & 0x0f) | 0x50
        uuidBytes[8] = (uuidBytes[8] & 0x3f) | 0x80
        return SyncID(UUID(uuid: (
            uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
            uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
            uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
            uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
        )))
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

/// The two canonical resource families supported by the sync engine.
public enum EntityType: String, Codable, CaseIterable, Hashable, Sendable {
    case list
    case task
}

public enum SyncProvider: String, Codable, CaseIterable, Sendable {
    case eventKit
    case googleTasks
    case microsoftGraph
    case genericREST
}

public struct SyncAccount: Hashable, Codable, Sendable {
    public let provider: SyncProvider
    public let accountID: String

    public init(provider: SyncProvider, accountID: String) {
        self.provider = provider
        self.accountID = accountID
    }
}

public enum TaskPriority: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3
    case urgent = 4
}

public enum DeletionReason: String, Codable, Sendable {
    case user
    case remote
    case conflict
    case retention
}

public struct CanonicalList: Identifiable, Hashable, Codable, Sendable {
    public let id: SyncID
    public var name: String
    public var colorHex: String?
    public var position: String?
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deletionReason: DeletionReason?

    public init(
        id: SyncID = SyncID(),
        name: String,
        colorHex: String? = nil,
        position: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        deletionReason: DeletionReason? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.position = position
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deletionReason = deletionReason
    }

    public var isDeleted: Bool { deletedAt != nil }
}

public struct CanonicalTask: Identifiable, Hashable, Codable, Sendable {
    public let id: SyncID
    public var title: String
    public var notes: String?
    public var listID: SyncID?
    public var isCompleted: Bool
    public var dueDate: Date?
    public var completedAt: Date?
    public var priority: TaskPriority
    public let createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?
    public var deletionReason: DeletionReason?

    public init(
        id: SyncID = SyncID(),
        title: String,
        notes: String? = nil,
        listID: SyncID? = nil,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        completedAt: Date? = nil,
        priority: TaskPriority = .none,
        createdAt: Date,
        updatedAt: Date,
        deletedAt: Date? = nil,
        deletionReason: DeletionReason? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.listID = listID
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
        self.deletionReason = deletionReason
    }

    public var isDeleted: Bool { deletedAt != nil }
}

/// An explicit mapping is required before a local list can be written to a provider.
/// There is intentionally no name-based or fuzzy list matching.
public struct ListMapping: Hashable, Codable, Sendable {
    public let account: SyncAccount
    public let canonicalListID: SyncID
    public let remoteListID: String
    public var lastSeenAt: Date

    public init(account: SyncAccount, canonicalListID: SyncID, remoteListID: String, lastSeenAt: Date) {
        self.account = account
        self.canonicalListID = canonicalListID
        self.remoteListID = remoteListID
        self.lastSeenAt = lastSeenAt
    }
}

public struct ExternalTaskID: Hashable, Codable, Sendable {
    public let account: SyncAccount
    public let remoteTaskID: String

    public init(account: SyncAccount, remoteTaskID: String) {
        self.account = account
        self.remoteTaskID = remoteTaskID
    }
}

/// The last canonical snapshot observed at a successful sync. It is the base for
/// three-way merges and prevents a remote pull from silently overwriting local edits.
public struct TaskReplica: Hashable, Codable, Sendable {
    public let externalID: ExternalTaskID
    public let canonicalTaskID: SyncID
    public var lastSyncedTask: CanonicalTask
    public var lastSyncedAt: Date
    public var remoteRevision: String?

    public init(
        externalID: ExternalTaskID,
        canonicalTaskID: SyncID,
        lastSyncedTask: CanonicalTask,
        lastSyncedAt: Date,
        remoteRevision: String? = nil
    ) {
        self.externalID = externalID
        self.canonicalTaskID = canonicalTaskID
        self.lastSyncedTask = lastSyncedTask
        self.lastSyncedAt = lastSyncedAt
        self.remoteRevision = remoteRevision
    }
}

public struct ListReplica: Hashable, Codable, Sendable {
    public let account: SyncAccount
    public let canonicalListID: SyncID
    public let remoteListID: String
    public var lastSyncedList: CanonicalList
    public var lastSyncedAt: Date
    public var remoteRevision: String?

    public init(
        account: SyncAccount,
        canonicalListID: SyncID,
        remoteListID: String,
        lastSyncedList: CanonicalList,
        lastSyncedAt: Date,
        remoteRevision: String? = nil
    ) {
        self.account = account
        self.canonicalListID = canonicalListID
        self.remoteListID = remoteListID
        self.lastSyncedList = lastSyncedList
        self.lastSyncedAt = lastSyncedAt
        self.remoteRevision = remoteRevision
    }
}

public enum ConflictField: String, Codable, CaseIterable, Sendable {
    case name
    case colorHex
    case position
    case title
    case notes
    case listID
    case isCompleted
    case dueDate
    case completedAt
    case priority
    case deletedAt
}

public enum ConflictKind: String, Codable, Sendable {
    case concurrentEdit
    case missingListMapping
    case providerRejected
    case unsupportedCapability
}

public enum ConflictResolution: String, Codable, Sendable {
    case pending
    case localWon
    case remoteWon
    case merged
    case dismissed
}

public struct SyncConflict: Identifiable, Hashable, Codable, Sendable {
    public let id: SyncID
    public let account: SyncAccount
    public let canonicalTaskID: SyncID?
    public let canonicalListID: SyncID?
    public let kind: ConflictKind
    public let fields: [ConflictField]
    public let baseTask: CanonicalTask?
    public let localTask: CanonicalTask?
    public let remoteTask: CanonicalTask?
    public let baseList: CanonicalList?
    public let localList: CanonicalList?
    public let remoteList: CanonicalList?
    public let createdAt: Date
    public var resolution: ConflictResolution
    public var resolvedAt: Date?

    public init(
        id: SyncID = SyncID(),
        account: SyncAccount,
        canonicalTaskID: SyncID? = nil,
        canonicalListID: SyncID? = nil,
        kind: ConflictKind,
        fields: [ConflictField],
        baseTask: CanonicalTask? = nil,
        localTask: CanonicalTask? = nil,
        remoteTask: CanonicalTask? = nil,
        baseList: CanonicalList? = nil,
        localList: CanonicalList? = nil,
        remoteList: CanonicalList? = nil,
        createdAt: Date,
        resolution: ConflictResolution = .pending,
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.account = account
        self.canonicalTaskID = canonicalTaskID
        self.canonicalListID = canonicalListID
        self.kind = kind
        self.fields = fields
        self.baseTask = baseTask
        self.localTask = localTask
        self.remoteTask = remoteTask
        self.baseList = baseList
        self.localList = localList
        self.remoteList = remoteList
        self.createdAt = createdAt
        self.resolution = resolution
        self.resolvedAt = resolvedAt
    }
}

public struct SyncCursor: Hashable, Codable, Sendable {
    public let account: SyncAccount
    public var value: String?
    public var updatedAt: Date

    public init(account: SyncAccount, value: String? = nil, updatedAt: Date) {
        self.account = account
        self.value = value
        self.updatedAt = updatedAt
    }
}

public struct SyncState: Codable, Sendable, Hashable {
    public var lists: [CanonicalList]
    public var tasks: [CanonicalTask]
    public var listMappings: [ListMapping]
    public var taskReplicas: [TaskReplica]
    public var listReplicas: [ListReplica]
    public var conflicts: [SyncConflict]
    public var cursors: [SyncCursor]
    /// Explicit ownership for canonical records that have not yet acquired a provider
    /// mapping/replica (for example a newly-created local record). Ownership is persisted
    /// so a second provider account cannot claim or push an unlinked record by ID.
    public var taskOwners: [SyncID: SyncAccount]
    public var listOwners: [SyncID: SyncAccount]
    public var schemaVersion: Int

    public init(
        lists: [CanonicalList] = [],
        tasks: [CanonicalTask] = [],
        listMappings: [ListMapping] = [],
        taskReplicas: [TaskReplica] = [],
        listReplicas: [ListReplica] = [],
        conflicts: [SyncConflict] = [],
        cursors: [SyncCursor] = [],
        taskOwners: [SyncID: SyncAccount] = [:],
        listOwners: [SyncID: SyncAccount] = [:],
        schemaVersion: Int = 1
    ) {
        self.lists = lists
        self.tasks = tasks
        self.listMappings = listMappings
        self.taskReplicas = taskReplicas
        self.listReplicas = listReplicas
        self.conflicts = conflicts
        self.cursors = cursors
        self.taskOwners = taskOwners
        self.listOwners = listOwners
        self.schemaVersion = schemaVersion
    }

    private enum CodingKeys: String, CodingKey {
        case lists, tasks, listMappings, taskReplicas, listReplicas, conflicts, cursors
        case taskOwners, listOwners, schemaVersion
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lists = try container.decodeIfPresent([CanonicalList].self, forKey: .lists) ?? []
        tasks = try container.decodeIfPresent([CanonicalTask].self, forKey: .tasks) ?? []
        listMappings = try container.decodeIfPresent([ListMapping].self, forKey: .listMappings) ?? []
        taskReplicas = try container.decodeIfPresent([TaskReplica].self, forKey: .taskReplicas) ?? []
        listReplicas = try container.decodeIfPresent([ListReplica].self, forKey: .listReplicas) ?? []
        conflicts = try container.decodeIfPresent([SyncConflict].self, forKey: .conflicts) ?? []
        cursors = try container.decodeIfPresent([SyncCursor].self, forKey: .cursors) ?? []
        taskOwners = try container.decodeIfPresent([SyncID: SyncAccount].self, forKey: .taskOwners) ?? [:]
        listOwners = try container.decodeIfPresent([SyncID: SyncAccount].self, forKey: .listOwners) ?? [:]
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lists, forKey: .lists)
        try container.encode(tasks, forKey: .tasks)
        try container.encode(listMappings, forKey: .listMappings)
        try container.encode(taskReplicas, forKey: .taskReplicas)
        try container.encode(listReplicas, forKey: .listReplicas)
        try container.encode(conflicts, forKey: .conflicts)
        try container.encode(cursors, forKey: .cursors)
        try container.encode(taskOwners, forKey: .taskOwners)
        try container.encode(listOwners, forKey: .listOwners)
        try container.encode(schemaVersion, forKey: .schemaVersion)
    }

    public func list(id: SyncID) -> CanonicalList? { lists.first { $0.id == id } }
    public func task(id: SyncID) -> CanonicalTask? { tasks.first { $0.id == id } }
    public func mapping(account: SyncAccount, canonicalListID: SyncID) -> ListMapping? {
        listMappings.first { $0.account == account && $0.canonicalListID == canonicalListID }
    }
    public func mapping(account: SyncAccount, remoteListID: String) -> ListMapping? {
        listMappings.first { $0.account == account && $0.remoteListID == remoteListID }
    }
    public func replica(account: SyncAccount, remoteTaskID: String) -> TaskReplica? {
        taskReplicas.first {
            $0.externalID.account == account && $0.externalID.remoteTaskID == remoteTaskID
        }
    }
    public func listReplica(account: SyncAccount, remoteListID: String) -> ListReplica? {
        listReplicas.first {
            $0.account == account && $0.remoteListID == remoteListID
        }
    }
    /// All persisted ownership evidence for a canonical task. An explicit owner map is
    /// authoritative; the replica/conflict fallback exists for checkpoints written before
    /// owner maps were introduced. A record with evidence from multiple accounts is
    /// intentionally ambiguous and must not be projected into any account.
    public func taskOwnershipCandidates(_ id: SyncID) -> Set<SyncAccount> {
        var candidates = Set<SyncAccount>()
        if let owner = taskOwners[id] { candidates.insert(owner) }
        candidates.formUnion(taskReplicas.filter { $0.canonicalTaskID == id }.map { $0.externalID.account })
        candidates.formUnion(conflicts.compactMap { $0.canonicalTaskID == id ? $0.account : nil })
        return candidates
    }

    public func listOwnershipCandidates(_ id: SyncID) -> Set<SyncAccount> {
        var candidates = Set<SyncAccount>()
        if let owner = listOwners[id] { candidates.insert(owner) }
        candidates.formUnion(listMappings.filter { $0.canonicalListID == id }.map(\.account))
        candidates.formUnion(listReplicas.filter { $0.canonicalListID == id }.map(\.account))
        candidates.formUnion(conflicts.compactMap { $0.canonicalListID == id ? $0.account : nil })
        return candidates
    }

    public func taskOwner(_ id: SyncID) -> SyncAccount? {
        let candidates = taskOwnershipCandidates(id)
        return candidates.count == 1 ? candidates.first : nil
    }

    public func listOwner(_ id: SyncID) -> SyncAccount? {
        let candidates = listOwnershipCandidates(id)
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Returns only records and sync metadata visible to one provider account. The full
    /// persisted state may contain several accounts, but this projection never does. If a
    /// legacy checkpoint contains conflicting ownership evidence, the ambiguous record is
    /// hidden until an explicit owner map or account-specific repair resolves it.
    public func scoped(to account: SyncAccount) -> SyncState {
        let visibleConflicts = conflicts.filter { conflict in
            guard conflict.account == account else { return false }
            if let taskID = conflict.canonicalTaskID, let owner = taskOwner(taskID), owner != account { return false }
            if let listID = conflict.canonicalListID, let owner = listOwner(listID), owner != account { return false }
            return true
        }
        let taskIDs = Set(tasks.compactMap { taskOwner($0.id) == account ? $0.id : nil })
            .union(taskOwners.compactMap { $0.value == account ? $0.key : nil })
            .union(taskReplicas.compactMap { taskOwner($0.canonicalTaskID) == account ? $0.canonicalTaskID : nil })
            .union(visibleConflicts.compactMap(\.canonicalTaskID))
        let listIDs = Set(lists.compactMap { listOwner($0.id) == account ? $0.id : nil })
            .union(listOwners.compactMap { $0.value == account ? $0.key : nil })
            .union(listMappings.compactMap { listOwner($0.canonicalListID) == account ? $0.canonicalListID : nil })
            .union(listReplicas.compactMap { listOwner($0.canonicalListID) == account ? $0.canonicalListID : nil })
            .union(visibleConflicts.compactMap(\.canonicalListID))
        return SyncState(
            lists: lists.filter { listIDs.contains($0.id) },
            tasks: tasks.filter { taskIDs.contains($0.id) },
            listMappings: listMappings.filter { $0.account == account && listOwner($0.canonicalListID) == account },
            taskReplicas: taskReplicas.filter { $0.externalID.account == account && taskOwner($0.canonicalTaskID) == account },
            listReplicas: listReplicas.filter { $0.account == account && listOwner($0.canonicalListID) == account },
            conflicts: visibleConflicts,
            cursors: cursors.filter { $0.account == account },
            taskOwners: taskOwners.filter { $0.value == account },
            listOwners: listOwners.filter { $0.value == account },
            schemaVersion: schemaVersion
        )
    }
    public func cursor(for account: SyncAccount) -> SyncCursor? {
        cursors.first { $0.account == account }
    }
}

public struct TombstoneRetentionPolicy: Sendable, Hashable {
    public var retention: TimeInterval

    public init(retention: TimeInterval = 30 * 24 * 60 * 60) {
        self.retention = retention
    }

    public func isExpired(deletedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(deletedAt) >= retention
    }
}

public struct SystemClock: Sendable {
    public init() {}
    public var now: Date { Date() }
}
