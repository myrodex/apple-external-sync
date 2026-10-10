import Foundation
import SyncDomain

public protocol SyncStateStore: Sendable {
    func load() async throws -> SyncState
    func save(_ state: SyncState) async throws
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
