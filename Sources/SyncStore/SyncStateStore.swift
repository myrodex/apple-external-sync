import Foundation
import SyncDomain

public protocol SyncStateStore: Sendable {
    func load() async throws -> SyncState
    func save(_ state: SyncState) async throws
    /// Account-scoped reads and writes are the engine boundary. Implementations must merge
    /// only the selected account into the durable checkpoint so stale work from another
    /// account cannot erase its cursor, mappings, or conflicts.
    func load(account: SyncAccount) async throws -> SyncState
    func save(_ state: SyncState, account: SyncAccount) async throws
    /// Internal authorization evidence used to distinguish a new local ID from a foreign
    /// or ambiguous ID without returning another account's records to the caller.
    func ownershipCandidates(entityType: EntityType, id: SyncID) async throws -> Set<SyncAccount>
    /// Returns true when the ID is retained in the durable ambiguous/quarantine
    /// checkpoint. Quarantined IDs are permanently reserved until an explicit repair.
    func isQuarantined(entityType: EntityType, id: SyncID) async throws -> Bool
    /// Durable audit records are part of the same account-scoped persistence boundary as
    /// the canonical checkpoint. Implementations must never return another account's runs.
    func syncRuns(account: SyncAccount, limit: Int?) async throws -> [SyncRun]
    func upsertSyncRun(_ run: SyncRun) async throws
    func cleanup(asOf: Date, retention: TimeInterval) async throws -> StoreCleanupResult
    /// Atomically removes all canonical sync state owned by one provider account.
    /// Provider credentials are managed separately by the app's secure token store.
    func remove(account: SyncAccount) async throws
}

public extension SyncStateStore {
    func load(account: SyncAccount) async throws -> SyncState {
        try await load().scoped(to: account)
    }

    func save(_ state: SyncState, account: SyncAccount) async throws {
        let current = try await load()
        try await save(current.replacing(account: account, with: state))
    }

    func ownershipCandidates(entityType: EntityType, id: SyncID) async throws -> Set<SyncAccount> { [] }
    func isQuarantined(entityType: EntityType, id: SyncID) async throws -> Bool {
        try await ownershipCandidates(entityType: entityType, id: id).count > 1
    }

    func remove(account: SyncAccount) async throws {
        let state = try await load()
        try await save(state.removing(account: account))
    }
}

public actor InMemorySyncStateStore: SyncStateStore {
    private var state: SyncState
    private var runs: [UUID: SyncRun]

    public init(state: SyncState = SyncState(), runs: [SyncRun] = []) {
        self.state = state
        self.runs = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
    }

    public func load() async throws -> SyncState { state }

    public func save(_ state: SyncState) async throws {
        self.state = state
    }

    public func load(account: SyncAccount) async throws -> SyncState {
        state.scoped(to: account)
    }

    public func save(_ state: SyncState, account: SyncAccount) async throws {
        self.state = self.state.replacing(account: account, with: state)
    }

    public func isQuarantined(entityType: EntityType, id: SyncID) async throws -> Bool {
        switch entityType {
        case .task:
            return state.taskOwnershipCandidates(id).count > 1
        case .list:
            return state.listOwnershipCandidates(id).count > 1
        }
    }

    public func ownershipCandidates(entityType: EntityType, id: SyncID) async throws -> Set<SyncAccount> {
        switch entityType {
        case .task:
            var candidates = state.taskOwnershipCandidates(id)
            if state.tasks.contains(where: { $0.id == id }) && candidates.isEmpty {
                candidates = Set(state.taskReplicas.filter { $0.canonicalTaskID == id }.map { $0.externalID.account })
            }
            return candidates
        case .list:
            var candidates = state.listOwnershipCandidates(id)
            if state.lists.contains(where: { $0.id == id }) && candidates.isEmpty {
                candidates = Set(state.listMappings.filter { $0.canonicalListID == id }.map(\.account))
            }
            return candidates
        }
    }

    public func remove(account: SyncAccount) async throws {
        state = state.removing(account: account)
        runs = runs.filter { $0.value.provider != account.provider.rawValue || $0.value.accountID != account.accountID }
    }

    public func syncRuns(account: SyncAccount, limit: Int? = nil) async throws -> [SyncRun] {
        var result = runs.values
            .filter { $0.provider == account.provider.rawValue && $0.accountID == account.accountID }
            .sorted {
                $0.startedAt == $1.startedAt ? $0.id.uuidString > $1.id.uuidString : $0.startedAt > $1.startedAt
            }
        if let limit { result = Array(result.prefix(max(0, limit))) }
        return result
    }

    public func upsertSyncRun(_ run: SyncRun) async throws {
        runs[run.id] = run
    }

    public func cleanup(asOf: Date, retention: TimeInterval) async throws -> StoreCleanupResult {
        guard retention >= 0 else { throw LocalStoreError.invalidConfiguration("retention must be non-negative") }
        let before = runs.count
        let cutoff = asOf.addingTimeInterval(-retention)
        runs = runs.filter { run in
            guard let finishedAt = run.value.finishedAt, finishedAt <= cutoff else { return true }
            return run.value.status == .running
        }
        return StoreCleanupResult(tombstonesRemoved: 0, completedRunsRemoved: before - runs.count)
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
            .union(next.listOwners.filter { $0.value == account }.map(\.key))
            .union(next.conflicts.filter { $0.account == account }.compactMap(\.canonicalListID))
        let removedTaskIDs = Set(next.taskReplicas.filter { $0.externalID.account == account }.map(\.canonicalTaskID))
            .union(next.taskOwners.filter { $0.value == account }.map(\.key))
            .union(next.conflicts.filter { $0.account == account }.compactMap(\.canonicalTaskID))
        next.listMappings.removeAll { $0.account == account }
        next.listReplicas.removeAll { $0.account == account }
        next.taskReplicas.removeAll { $0.externalID.account == account }
        next.listOwners = next.listOwners.filter { $0.value != account }
        next.taskOwners = next.taskOwners.filter { $0.value != account }
        next.cursors.removeAll { $0.account == account }
        next.conflicts.removeAll { $0.account == account }
        let retainedListIDs = Set(next.listMappings.map(\.canonicalListID))
            .union(next.listReplicas.map(\.canonicalListID))
            .union(next.listOwners.keys)
            .union(next.conflicts.compactMap(\.canonicalListID))
        let retainedTaskIDs = Set(next.taskReplicas.map(\.canonicalTaskID))
            .union(next.taskOwners.keys)
            .union(next.conflicts.compactMap(\.canonicalTaskID))
        next.lists.removeAll { removedListIDs.contains($0.id) && !retainedListIDs.contains($0.id) }
        next.tasks.removeAll { removedTaskIDs.contains($0.id) && !retainedTaskIDs.contains($0.id) }
        return next
    }
}

public extension SyncState {
    /// Replaces one account's projection while retaining every other account's durable
    /// records. Store implementations use this inside their write transaction.
    func replacing(account: SyncAccount, with accountState: SyncState) -> SyncState {
        var next = removing(account: account)
        for list in accountState.lists {
            if let index = next.lists.firstIndex(where: { $0.id == list.id }) { next.lists[index] = list }
            else { next.lists.append(list) }
        }
        for task in accountState.tasks {
            if let index = next.tasks.firstIndex(where: { $0.id == task.id }) { next.tasks[index] = task }
            else { next.tasks.append(task) }
        }
        next.listMappings.append(contentsOf: accountState.listMappings)
        next.taskReplicas.append(contentsOf: accountState.taskReplicas)
        next.listReplicas.append(contentsOf: accountState.listReplicas)
        next.conflicts.append(contentsOf: accountState.conflicts)
        next.cursors.append(contentsOf: accountState.cursors)
        next.taskOwners.merge(accountState.taskOwners) { _, replacement in replacement }
        next.listOwners.merge(accountState.listOwners) { _, replacement in replacement }
        next.schemaVersion = max(next.schemaVersion, accountState.schemaVersion)
        return next
    }
}

public enum SyncStateMaintenance {
    public static func pruneExpiredTombstones(
        in state: SyncState,
        now: Date,
        policy: TombstoneRetentionPolicy = TombstoneRetentionPolicy(),
        account: SyncAccount? = nil
    ) -> SyncState {
        var state = state
        // Snapshot ownership before mutating the arrays; querying the state from inside
        // removeAll's inout closure violates Swift exclusivity and could otherwise make
        // account-scoped retention cleanup racy.
        let taskOwners = state.taskOwners
        let taskReplicaIDsByAccount = Dictionary(grouping: state.taskReplicas, by: { $0.externalID.account })
            .mapValues { Set($0.map(\.canonicalTaskID)) }
        let listOwners = state.listOwners
        let listMappingIDsByAccount = Dictionary(grouping: state.listMappings, by: { $0.account })
            .mapValues { Set($0.map(\.canonicalListID)) }
        state.tasks.removeAll { task in
            guard let deletedAt = task.deletedAt else { return false }
            guard let account else { return policy.isExpired(deletedAt: deletedAt, now: now) }
            let owned = taskOwners[task.id] == account || taskReplicaIDsByAccount[account]?.contains(task.id) == true
            return owned && policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.lists.removeAll { list in
            guard let deletedAt = list.deletedAt else { return false }
            guard let account else { return policy.isExpired(deletedAt: deletedAt, now: now) }
            let owned = listOwners[list.id] == account || listMappingIDsByAccount[account]?.contains(list.id) == true
            return owned && policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.taskReplicas.removeAll { replica in
            guard let deletedAt = replica.lastSyncedTask.deletedAt else { return false }
            guard account == nil || replica.externalID.account == account else { return false }
            return policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.listReplicas.removeAll { replica in
            guard let deletedAt = replica.lastSyncedList.deletedAt else { return false }
            guard account == nil || replica.account == account else { return false }
            return policy.isExpired(deletedAt: deletedAt, now: now)
        }
        state.listMappings.removeAll { mapping in
            guard account == nil || mapping.account == account else { return false }
            guard let list = state.lists.first(where: { $0.id == mapping.canonicalListID }) else {
                return true
            }
            return list.deletedAt.map { policy.isExpired(deletedAt: $0, now: now) } ?? false
        }
        // Do not leave owner entries pointing at records whose tombstone was purged. A
        // stale owner would make a future local ID permanently unclaimable after retention.
        let liveTaskIDs = Set(state.tasks.map(\.id))
        let liveListIDs = Set(state.lists.map(\.id))
        let retainedTaskIDs = Set(state.taskReplicas.map(\.canonicalTaskID))
            .union(state.conflicts.compactMap(\.canonicalTaskID))
        let retainedListIDs = Set(state.listMappings.map(\.canonicalListID))
            .union(state.listReplicas.map(\.canonicalListID))
            .union(state.conflicts.compactMap(\.canonicalListID))
        state.taskOwners = state.taskOwners.filter { entry in
            let (id, owner) = entry
            return !((account == nil || owner == account) && !liveTaskIDs.contains(id) && !retainedTaskIDs.contains(id))
        }
        state.listOwners = state.listOwners.filter { entry in
            let (id, owner) = entry
            return !((account == nil || owner == account) && !liveListIDs.contains(id) && !retainedListIDs.contains(id))
        }
        return state
    }
}
