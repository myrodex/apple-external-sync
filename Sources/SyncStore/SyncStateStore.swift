import Foundation
import SyncDomain

public protocol SyncStateStore: Sendable {
    func load() async throws -> SyncState
    func save(_ state: SyncState) async throws
    /// Atomically removes all canonical sync state owned by one provider account.
    /// Provider credentials are managed separately by the app's secure token store.
    func remove(account: SyncAccount) async throws
}

public extension SyncStateStore {
    func remove(account: SyncAccount) async throws {
        let state = try await load()
        try await save(state.removing(account: account))
    }
}

public actor InMemorySyncStateStore: SyncStateStore {
    private var state: SyncState

    public init(state: SyncState = SyncState()) {
        self.state = state
    }

    public func load() async throws -> SyncState { state }

    public func save(_ state: SyncState) async throws {
        self.state = state
    }
}

public extension SyncState {
    /// Removes account-owned mappings, replicas, cursors, and conflicts. Canonical
    /// lists/tasks are removed only when no other provider account still references
    /// their IDs, preventing account disconnect from deleting another account's data.
    func removing(account: SyncAccount) -> SyncState {
        var next = self
        let removedListIDs = Set(next.listMappings.filter { $0.account == account }.map(\.canonicalListID))
            .union(next.listReplicas.filter { $0.account == account }.map(\.canonicalListID))
        let removedTaskIDs = Set(next.taskReplicas.filter { $0.externalID.account == account }.map(\.canonicalTaskID))
        next.listMappings.removeAll { $0.account == account }
        next.listReplicas.removeAll { $0.account == account }
        next.taskReplicas.removeAll { $0.externalID.account == account }
        next.cursors.removeAll { $0.account == account }
        next.conflicts.removeAll { $0.account == account }
        let retainedListIDs = Set(next.listMappings.map(\.canonicalListID)).union(next.listReplicas.map(\.canonicalListID))
        let retainedTaskIDs = Set(next.taskReplicas.map(\.canonicalTaskID))
        next.lists.removeAll { removedListIDs.contains($0.id) && !retainedListIDs.contains($0.id) }
        next.tasks.removeAll { removedTaskIDs.contains($0.id) && !retainedTaskIDs.contains($0.id) }
        return next
    }
}

public enum SyncStateMaintenance {
    public static func pruneExpiredTombstones(
        in state: SyncState,
        now: Date,
        policy: TombstoneRetentionPolicy = TombstoneRetentionPolicy()
    ) -> SyncState {
        var state = state
        state.tasks.removeAll { task in
            guard let deletedAt = task.deletedAt else { return false }
            return policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.lists.removeAll { list in
            guard let deletedAt = list.deletedAt else { return false }
            return policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.taskReplicas.removeAll { replica in
            guard let deletedAt = replica.lastSyncedTask.deletedAt else { return false }
            return policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.listReplicas.removeAll { replica in
            guard let deletedAt = replica.lastSyncedList.deletedAt else { return false }
            return policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.listMappings.removeAll { mapping in
            guard let list = state.lists.first(where: { $0.id == mapping.canonicalListID }) else {
                return true
            }
            return list.deletedAt.map { policy.isExpired(deletedAt: $0, now: now) } ?? false
        }
        return state
    }
}
