import Foundation
import SyncContracts
import SyncDomain
import SyncStore

/// Errors that prevent a sync batch from being committed. A failed pull or failed push
/// leaves the previously persisted cursor and state untouched.
public enum SyncEngineError: Error, LocalizedError, Equatable, Sendable {
    case accountMismatch(expected: SyncAccount, actual: SyncAccount)
    case invalidRemoteChange(String)
    case stateStoreFailure(String)
    case pushFailed(String)
    case conflictNotFound(SyncID)
    case recordNotOwned(entityType: EntityType, id: SyncID)

    public var errorDescription: String? {
        switch self {
        case let .accountMismatch(expected, actual):
            return "Adapter account \(actual.accountID) does not match configured account \(expected.accountID)."
        case let .invalidRemoteChange(message): return "Invalid remote change: \(message)"
        case let .stateStoreFailure(message): return "Unable to persist sync state: \(message)"
        case let .pushFailed(message): return "Unable to push sync mutations: \(message)"
        case let .conflictNotFound(id): return "Conflict \(id) was not found."
        case let .recordNotOwned(entityType, id): return "The \(entityType.rawValue) \(id) is not owned by this sync account."
        }
    }
}

public struct SyncEngineConfiguration: Sendable, Hashable {
    public var tombstoneRetention: TombstoneRetentionPolicy
    public var inferFullSnapshotDeletions: Bool

    public init(
        tombstoneRetention: TombstoneRetentionPolicy = TombstoneRetentionPolicy(),
        inferFullSnapshotDeletions: Bool = true
    ) {
        self.tombstoneRetention = tombstoneRetention
        self.inferFullSnapshotDeletions = inferFullSnapshotDeletions
    }
}

public struct SyncReport: Sendable, Hashable, Codable {
    public let account: SyncAccount
    public let startedAt: Date
    public let finishedAt: Date
    public let pulledCount: Int
    public let pushedCount: Int
    public let rejectedCount: Int
    public let conflictCount: Int
    public let createdCount: Int
    public let updatedCount: Int
    public let deletedCount: Int
    public let cursorBefore: String?
    public let cursorAfter: String?
    public let committed: Bool
    public let diagnostics: [FieldLossDiagnostic]

    public init(
        account: SyncAccount,
        startedAt: Date,
        finishedAt: Date,
        pulledCount: Int,
        pushedCount: Int,
        rejectedCount: Int,
        conflictCount: Int,
        createdCount: Int,
        updatedCount: Int,
        deletedCount: Int,
        cursorBefore: String?,
        cursorAfter: String?,
        committed: Bool,
        diagnostics: [FieldLossDiagnostic] = []
    ) {
        self.account = account
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.pulledCount = pulledCount
        self.pushedCount = pushedCount
        self.rejectedCount = rejectedCount
        self.conflictCount = conflictCount
        self.createdCount = createdCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.cursorBefore = cursorBefore
        self.cursorAfter = cursorAfter
        self.committed = committed
        self.diagnostics = diagnostics
    }
}

public struct SyncConflictResolution: Sendable, Hashable {
    public let conflictID: SyncID
    public let resolution: ConflictResolution

    public init(conflictID: SyncID, resolution: ConflictResolution) {
        self.conflictID = conflictID
        self.resolution = resolution
    }
}

/// A deterministic, actor-serialized pull/merge/push engine. The canonical `SyncState` is
/// persisted with one state-store save at the end of a successful batch, so state and cursor
/// advance together. Provider adapters remain stateless and are responsible only for transport
/// and provider-specific translation.
public actor SyncEngine {
    private let account: SyncAccount
    private let adapter: any ExternalSyncAdapter
    private let stateStore: any SyncStateStore
    private let configuration: SyncEngineConfiguration
    private let now: @Sendable () -> Date

    public init(
        account: SyncAccount? = nil,
        adapter: any ExternalSyncAdapter,
        stateStore: any SyncStateStore,
        configuration: SyncEngineConfiguration = SyncEngineConfiguration(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account ?? adapter.account
        self.adapter = adapter
        self.stateStore = stateStore
        self.configuration = configuration
        self.now = now
    }

    public func currentState() async throws -> SyncState {
        try await stateStore.load(account: account)
    }

    public func queuedConflicts() async throws -> [SyncConflict] {
        let state = try await stateStore.load(account: account)
        return state.conflicts
            .filter { $0.resolution == .pending }
            .sorted { lhs, rhs in
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                return lhs.id.description < rhs.id.description
            }
    }

    /// Resolve an existing conflict and atomically persist the selected value. A remote-win
    /// resolution also updates the canonical task snapshot; local-win leaves the local value
    /// in place. Merged is a caller-confirmed local value in this API and therefore has the
    /// same canonical effect as localWon.
    public func resolveConflict(id: SyncID, resolution: ConflictResolution) async throws {
        try await resolveConflict(SyncConflictResolution(conflictID: id, resolution: resolution))
    }

    public func resolveConflict(_ resolution: SyncConflictResolution) async throws {
        var state = try await stateStore.load(account: account)
        guard let index = state.conflicts.firstIndex(where: { $0.id == resolution.conflictID && $0.account == account }) else {
            // Deliberately report the same result for a missing or foreign conflict ID.
            throw SyncEngineError.conflictNotFound(resolution.conflictID)
        }
        let conflict = state.conflicts[index]
        guard conflict.resolution == .pending else { return }
        if let taskID = conflict.canonicalTaskID { try ensureOwnedTask(taskID, in: state) }
        if let listID = conflict.canonicalListID { try ensureOwnedList(listID, in: state) }

        let resolvedAt = now()
        switch resolution.resolution {
        case .remoteWon:
            if let taskID = conflict.canonicalTaskID, let remote = conflict.remoteTask,
               let taskIndex = state.tasks.firstIndex(where: { $0.id == taskID }) {
                state.tasks[taskIndex] = remote
                if let replicaIndex = state.taskReplicas.firstIndex(where: { $0.externalID.account == account && $0.canonicalTaskID == taskID }) {
                    state.taskReplicas[replicaIndex].lastSyncedTask = remote
                    state.taskReplicas[replicaIndex].lastSyncedAt = resolvedAt
                }
            }
            if let listID = conflict.canonicalListID, let remote = conflict.remoteList,
               let listIndex = state.lists.firstIndex(where: { $0.id == listID }) {
                state.lists[listIndex] = remote
                if let replicaIndex = state.listReplicas.firstIndex(where: { $0.account == account && $0.canonicalListID == listID }) {
                    state.listReplicas[replicaIndex].lastSyncedList = remote
                    state.listReplicas[replicaIndex].lastSyncedAt = resolvedAt
                }
            }
        case .localWon, .merged, .dismissed, .pending:
            break
        }
        state.conflicts[index].resolution = resolution.resolution
        state.conflicts[index].resolvedAt = resolvedAt
        try await stateStore.save(state, account: account)
    }

    /// Apply one local mutation transactionally. The next sync compares these values with
    /// their replicas and emits provider mutations; no eager network call is made here.
    public func applyLocalChange(_ change: LocalChange) async throws {
        var state = try await stateStore.load(account: account)
        let timestamp = now()
        switch change {
        case let .upsertTask(task):
            try await ensureNoForeignOwnership(entityType: .task, id: task.id)
            try ensureOwnedOrClaimTask(task.id, in: &state)
            if let listID = task.listID {
                try await ensureNoForeignOwnership(entityType: .list, id: listID)
                try ensureOwnedList(listID, in: state)
            }
            upsertTask(task, into: &state)
        case let .deleteTask(id, reason, at):
            try await ensureNoForeignOwnership(entityType: .task, id: id)
            guard let index = state.tasks.firstIndex(where: { $0.id == id }) else { return }
            try ensureOwnedTask(id, in: state)
            state.tasks[index] = state.tasks[index].markingDeleted(at: at, reason: reason)
        case let .upsertList(list):
            try await ensureNoForeignOwnership(entityType: .list, id: list.id)
            try ensureOwnedOrClaimList(list.id, in: &state)
            upsertList(list, into: &state)
        case let .deleteList(id, reason, at):
            try await ensureNoForeignOwnership(entityType: .list, id: id)
            guard let index = state.lists.firstIndex(where: { $0.id == id }) else { return }
            try ensureOwnedList(id, in: state)
            var copy = state.lists[index]
            copy.deletedAt = at
            copy.deletionReason = reason
            copy.updatedAt = at
            state.lists[index] = copy
        }
        state = SyncStateMaintenance.pruneExpiredTombstones(
            in: state,
            now: timestamp,
            policy: configuration.tombstoneRetention,
            account: account
        )
        try await stateStore.save(state, account: account)
    }

    /// Pull, merge, push, then commit one provider batch. If pull, merge, or push throws,
    /// `save` is never called, so the cursor remains at the last committed value.
    public func sync() async throws -> SyncReport {
        let startedAt = now()
        guard adapter.account == account else {
            throw SyncEngineError.accountMismatch(expected: account, actual: adapter.account)
        }

        // Keep audit history bounded even when the engine is used directly rather than
        // through the app coordinator's launch cleanup path. Cleanup is best-effort and
        // cannot affect the canonical sync result.
        _ = try? await stateStore.cleanup(asOf: startedAt, retention: SyncRunStatus.defaultRetention)
        let durableRun = SyncRun(account: account, startedAt: startedAt)
        // A running record is intentionally written before provider I/O. If the process
        // dies during pull/push, the next launch can surface the unfinished run and offer
        // retry instead of silently losing the failure.
        await persistAuditRun(durableRun)

        let original: SyncState
        do {
            original = try await stateStore.load(account: account)
        } catch {
            await persistAuditRun(failedAuditRun(durableRun, error: error, finishedAt: now()))
            throw error
        }
        let cursorBefore = original.cursor(for: account)?.value
        let pulled: RemoteChanges
        do {
            pulled = try await adapter.pullChanges(since: cursorBefore)
        } catch {
            await persistAuditRun(failedAuditRun(durableRun, error: error, finishedAt: now()))
            throw error
        }
        var next = original
        var counters = Counters()
        let effectiveNow = max(startedAt, pulled.serverNow)
        // Remove expired tombstones before applying a fresh provider snapshot. At the
        // retention boundary an active provider object is an intentional recreation, not
        // an edit to the old deleted identity.
        next = SyncStateMaintenance.pruneExpiredTombstones(
            in: next,
            now: effectiveNow,
            policy: configuration.tombstoneRetention,
            account: account
        )

        do {
            let outcome = try await applyRemoteChanges(
                pulled,
                to: &next,
                at: effectiveNow,
                counters: &counters
            )
            var mutations = outcome.mutations
            // Sort mutation order so list creation/mapping precedes task writes and repeated
            // runs are byte-for-byte deterministic.
            mutations.sort(by: mutationOrder)
            let pushResult: PushResult
            if mutations.isEmpty {
                pushResult = PushResult(accepted: 0, nextCursor: pulled.nextCursor, serverNow: effectiveNow)
            } else {
                pushResult = try await adapter.push(mutations, cursor: pulled.nextCursor ?? cursorBefore)
            }

            // Apply remote ID mappings returned by provider creates before calculating
            // baselines. Rejected writes deliberately leave the previous baseline so they
            // are retried on the next sync.
            try applyRemoteMappings(pushResult.mappings, to: &next, at: effectiveNow)
            applyAcceptedBaselines(mutations: mutations, pushResult: pushResult, state: &next, at: effectiveNow)
            counters.pushed = pushResult.accepted
            counters.rejected = pushResult.rejected.count

            // Cursor advances only after every local operation and network request above has
            // completed. The state save is the single atomic commit boundary.
            // A partially rejected push must not consume the pull page. Persist accepted
            // canonical work so it remains visible, but leave the checkpoint untouched so
            // the rejected mutation and its remote change are replayed on the next run.
            let canAdvanceCursor = pushResult.rejected.isEmpty
            if canAdvanceCursor, let nextCursor = pulled.nextCursor {
                upsertCursor(SyncCursor(account: account, value: nextCursor, updatedAt: effectiveNow), into: &next)
            } else if canAdvanceCursor, let cursorBefore {
                // Full snapshots frequently have no provider cursor; preserve the old one.
                upsertCursor(SyncCursor(account: account, value: cursorBefore, updatedAt: effectiveNow), into: &next)
            }
            next = SyncStateMaintenance.pruneExpiredTombstones(in: next, now: effectiveNow, policy: configuration.tombstoneRetention, account: account)
            try await stateStore.save(next, account: account)
            let finishedAt = now()
            let report = SyncReport(
                account: account,
                startedAt: startedAt,
                finishedAt: finishedAt,
                pulledCount: pulled.changes.count,
                pushedCount: counters.pushed,
                rejectedCount: counters.rejected,
                conflictCount: counters.conflicts,
                createdCount: counters.created,
                updatedCount: counters.updated,
                deletedCount: counters.deleted,
                cursorBefore: cursorBefore,
                cursorAfter: next.cursor(for: account)?.value,
                committed: true,
                diagnostics: pulled.diagnostics + pushResult.diagnostics
            )
            await persistAuditRun(completedAuditRun(durableRun, report: report))
            return report
        } catch let error as SyncEngineError {
            await persistAuditRun(failedAuditRun(durableRun, error: error, finishedAt: now()))
            throw error
        } catch {
            await persistAuditRun(failedAuditRun(durableRun, error: error, finishedAt: now()))
            throw SyncEngineError.pushFailed(error.localizedDescription)
        }
    }

    private struct Counters {
        var created = 0
        var updated = 0
        var deleted = 0
        var conflicts = 0
        var pushed = 0
        var rejected = 0
    }

    private struct ApplyOutcome {
        var mutations: [RemoteMutation] = []
    }

    private func completedAuditRun(_ run: SyncRun, report: SyncReport) -> SyncRun {
        var completed = run
        completed.finishedAt = report.finishedAt
        completed.status = report.rejectedCount == 0 && report.conflictCount == 0 ? .succeeded : .partiallySucceeded
        completed.scannedCount = report.pulledCount
        completed.createdCount = report.createdCount
        completed.updatedCount = report.updatedCount
        completed.deletedCount = report.deletedCount
        completed.conflictCount = report.conflictCount
        completed.errorMessage = switch (report.rejectedCount, report.conflictCount) {
        case (0, 0): nil
        case (_, 0): "Some provider writes were rejected and will be retried."
        default: "Sync completed with conflicts requiring review."
        }
        return completed
    }

    private func failedAuditRun(_ run: SyncRun, error: Error, finishedAt: Date) -> SyncRun {
        var failed = run
        failed.finishedAt = finishedAt
        failed.status = .failed
        failed.errorMessage = error.localizedDescription
        return failed
    }

    private func persistAuditRun(_ run: SyncRun) async {
        // Audit data is an observability aid, not the canonical commit boundary. Swallow
        // failures so callers receive the provider/state result that actually occurred.
        try? await stateStore.upsertSyncRun(run)
    }

    private func applyRemoteChanges(
        _ changes: RemoteChanges,
        to state: inout SyncState,
        at date: Date,
        counters: inout Counters
    ) async throws -> ApplyOutcome {
        var outcome = ApplyOutcome()
        var seenLists = Set<String>()
        var seenTasks = Set<String>()

        // Process lists first so task list references can resolve regardless of provider order.
        for change in changes.changes {
            if case let .list(list) = change {
                seenLists.insert(list.remoteID)
                let canonicalID = state.mapping(account: account, remoteListID: list.remoteID)?.canonicalListID
                    ?? SyncID.deterministic(namespace: "\(account.provider.rawValue):\(account.accountID):list:\(list.remoteID)")
                try await ensureNoForeignOwnership(entityType: .list, id: canonicalID)
                try applyRemoteList(list, to: &state, at: date, counters: &counters)
            }
        }
        for change in changes.changes {
            if case let .task(task) = change {
                seenTasks.insert(task.remoteID)
                let canonicalID = state.replica(account: account, remoteTaskID: task.remoteID)?.canonicalTaskID
                    ?? SyncID.deterministic(namespace: "\(account.provider.rawValue):\(account.accountID):task:\(task.remoteID)")
                try await ensureNoForeignOwnership(entityType: .task, id: canonicalID)
                try applyRemoteTask(task, to: &state, at: date, counters: &counters)
            }
        }

        if changes.isFullSnapshot && configuration.inferFullSnapshotDeletions {
            let listIDs = state.listMappings
                .filter { $0.account == account }
                .map(\.remoteListID)
            for remoteID in listIDs where !seenLists.contains(remoteID) {
                let name = state.listReplica(account: account, remoteListID: remoteID)?.lastSyncedList.name
                    ?? state.listMappings.first(where: { $0.account == account && $0.remoteListID == remoteID }).flatMap { state.list(id: $0.canonicalListID)?.name }
                    ?? ""
                let canonicalID = state.mapping(account: account, remoteListID: remoteID)?.canonicalListID
                    ?? SyncID.deterministic(namespace: "\(account.provider.rawValue):\(account.accountID):list:\(remoteID)")
                try await ensureNoForeignOwnership(entityType: .list, id: canonicalID)
                try applyRemoteList(RemoteList(remoteID: remoteID, name: name, isDeleted: true, updatedAt: date), to: &state, at: date, counters: &counters)
            }
            let taskIDs = state.taskReplicas
                .filter { $0.externalID.account == account }
                .map { $0.externalID.remoteTaskID }
            for remoteID in taskIDs where !seenTasks.contains(remoteID) {
                guard let replica = state.replica(account: account, remoteTaskID: remoteID) else { continue }
                let task = RemoteTask(remoteID: remoteID, title: replica.lastSyncedTask.title, notes: replica.lastSyncedTask.notes,
                                      remoteListID: replica.lastSyncedTask.listID.flatMap { state.mapping(account: account, canonicalListID: $0)?.remoteListID },
                                      isCompleted: replica.lastSyncedTask.isCompleted, dueDate: replica.lastSyncedTask.dueDate,
                                      completedAt: replica.lastSyncedTask.completedAt, priority: replica.lastSyncedTask.priority,
                                      isDeleted: true, updatedAt: date, revision: replica.remoteRevision)
                try await ensureNoForeignOwnership(entityType: .task, id: replica.canonicalTaskID)
                try applyRemoteTask(task, to: &state, at: date, counters: &counters)
            }
        }

        // Generate pushes only after all remote changes have updated state/replicas. This
        // makes local-only edits visible while avoiding echoing the remote snapshot.
        outcome.mutations = localMutations(from: state)
        return outcome
    }

    private func applyRemoteList(
        _ remote: RemoteList,
        to state: inout SyncState,
        at date: Date,
        counters: inout Counters
    ) throws {
        let mapping = state.mapping(account: account, remoteListID: remote.remoteID)
        let canonicalID = mapping?.canonicalListID ?? SyncID.deterministic(namespace: "\(account.provider.rawValue):\(account.accountID):list:\(remote.remoteID)")
        try ensureOwnedOrClaimList(canonicalID, in: &state)
        let existingIndex = state.lists.firstIndex(where: { $0.id == canonicalID })
        let existing = existingIndex.map { state.lists[$0] }
        let base = state.listReplicas.first(where: { $0.account == account && $0.canonicalListID == canonicalID })?.lastSyncedList
        let remoteList = CanonicalList(
            id: canonicalID,
            name: remote.name,
            colorHex: remote.colorHex,
            position: remote.position,
            createdAt: existing?.createdAt ?? (remote.updatedAt ?? date),
            updatedAt: remote.updatedAt ?? date,
            deletedAt: remote.isDeleted ? (remote.updatedAt ?? date) : nil,
            deletionReason: remote.isDeleted ? .remote : nil
        )

        if let existing {
            if let deletedAt = existing.deletedAt, !configuration.tombstoneRetention.isExpired(deletedAt: deletedAt, now: date), !remote.isDeleted {
                // A provider replayed an upsert for a still-retained tombstone. Keep the
                // canonical delete and the deleted baseline; do not let replayed data
                // resurrect or schedule an unnecessary write.
                return
            } else if let base {
                let result = CanonicalListMerger.merge(base: base, local: existing, remote: remoteList, now: date)
                if result.isConflict {
                    enqueueListConflict(for: canonicalID, base: base, local: existing, remote: remoteList, fields: result.conflicts, state: &state, at: date)
                    counters.conflicts += 1
                } else if let merged = result.list {
                    if existing != merged { counters.updated += 1 }
                    if merged.deletedAt != nil && existing.deletedAt == nil { counters.deleted += 1 }
                    upsertList(merged, into: &state)
                }
            } else if CanonicalListMerger.sameContent(existing, remoteList) {
                upsertList(remoteList, into: &state)
            } else {
                enqueueListConflict(for: canonicalID, base: nil, local: existing, remote: remoteList, fields: CanonicalListMerger.allFields, state: &state, at: date)
                counters.conflicts += 1
            }
        } else {
            upsertList(remoteList, into: &state)
            if remote.isDeleted { counters.deleted += 1 } else { counters.created += 1 }
        }

        upsertListMapping(ListMapping(account: account, canonicalListID: canonicalID, remoteListID: remote.remoteID, lastSeenAt: date), into: &state)
        let baseline = ListReplica(
            account: account,
            canonicalListID: canonicalID,
            remoteListID: remote.remoteID,
            lastSyncedList: remoteList,
            lastSyncedAt: date,
            remoteRevision: remote.revision
        )
        upsertListReplica(baseline, into: &state)
    }

    private func applyRemoteTask(
        _ remote: RemoteTask,
        to state: inout SyncState,
        at date: Date,
        counters: inout Counters
    ) throws {
        let existingReplica = state.replica(account: account, remoteTaskID: remote.remoteID)
        let canonicalID = existingReplica?.canonicalTaskID ?? SyncID.deterministic(namespace: "\(account.provider.rawValue):\(account.accountID):task:\(remote.remoteID)")
        try ensureOwnedOrClaimTask(canonicalID, in: &state)
        let existingIndex = state.tasks.firstIndex(where: { $0.id == canonicalID })
        let existing = existingIndex.map { state.tasks[$0] }
        if let existing, let deletedAt = existing.deletedAt,
           !configuration.tombstoneRetention.isExpired(deletedAt: deletedAt, now: date),
           !remote.isDeleted {
            // A provider replayed an upsert for a still-retained tombstone. Keep both the
            // canonical delete and the deleted replica baseline.
            return
        }
        let remoteTask = canonicalTask(from: remote, canonicalID: canonicalID, listID: canonicalListID(remoteListID: remote.remoteListID, state: state), at: date, existing: existing)

        if let existing, let base = existingReplica?.lastSyncedTask {
            if remote.isDeleted {
                let result = CanonicalTaskMerger.merge(base: base, local: existing, remote: remoteTask, now: date)
                if result.isConflict {
                    enqueueConflict(for: canonicalID, base: base, local: existing, remote: remoteTask, fields: result.conflicts, state: &state, at: date)
                    counters.conflicts += 1
                } else if let merged = result.task {
                    upsertTask(merged.markingDeleted(at: date, reason: .remote), into: &state)
                    counters.deleted += 1
                }
            } else {
                let result = CanonicalTaskMerger.merge(base: base, local: existing, remote: remoteTask, now: date)
                if result.isConflict {
                    // CanonicalTaskMerger intentionally returns no task when fields conflict.
                    // Keep local data, queue conflict, and establish remote as the new base.
                    enqueueConflict(for: canonicalID, base: base, local: existing, remote: remoteTask, fields: result.conflicts, state: &state, at: date)
                    counters.conflicts += 1
                } else if let merged = result.task {
                    if existing != merged { counters.updated += 1 }
                    upsertTask(merged, into: &state)
                }
            }
        } else if let existing {
            // No base exists (usually a locally-created object). Remote is authoritative only
            // when the local object has no user edits; otherwise queue a conflict.
            if existing.domainEquals(remoteTask) {
                upsertTask(remoteTask, into: &state)
            } else {
                enqueueConflict(for: canonicalID, base: nil, local: existing, remote: remoteTask, fields: CanonicalTaskMerger.allFields, state: &state, at: date)
                counters.conflicts += 1
            }
        } else {
            if remote.isDeleted {
                // Keep a tombstone even when the initial pull contains only a delete.
                var deleted = remoteTask
                deleted.deletedAt = remote.updatedAt ?? date
                deleted.deletionReason = .remote
                upsertTask(deleted, into: &state)
                counters.deleted += 1
            } else {
                upsertTask(remoteTask, into: &state)
                counters.created += 1
            }
        }

        let replica = TaskReplica(
            externalID: ExternalTaskID(account: account, remoteTaskID: remote.remoteID),
            canonicalTaskID: canonicalID,
            lastSyncedTask: remoteTask,
            lastSyncedAt: date,
            remoteRevision: remote.revision
        )
        upsertReplica(replica, into: &state)
    }

    private func canonicalTask(
        from remote: RemoteTask,
        canonicalID: SyncID,
        listID: SyncID?,
        at date: Date,
        existing: CanonicalTask?
    ) -> CanonicalTask {
        CanonicalTask(
            id: canonicalID,
            title: remote.title,
            notes: remote.notes,
            listID: listID,
            isCompleted: remote.isCompleted,
            dueDate: remote.dueDate,
            completedAt: remote.completedAt,
            priority: remote.priority,
            createdAt: existing?.createdAt ?? (remote.updatedAt ?? date),
            updatedAt: remote.updatedAt ?? date,
            deletedAt: remote.isDeleted ? (remote.updatedAt ?? date) : nil,
            deletionReason: remote.isDeleted ? .remote : nil
        )
    }

    private func canonicalListID(remoteListID: String?, state: SyncState) -> SyncID? {
        guard let remoteListID else { return nil }
        return state.mapping(account: account, remoteListID: remoteListID)?.canonicalListID
    }

    private func localMutations(from state: SyncState) -> [RemoteMutation] {
        var result: [RemoteMutation] = []
        let accountLists = state.listMappings.filter { $0.account == account }
        let pendingTaskConflicts = Set(state.conflicts.filter { $0.account == account && $0.resolution == .pending }.compactMap(\.canonicalTaskID))
        let pendingListConflicts = Set(state.conflicts.filter { $0.account == account && $0.resolution == .pending }.compactMap(\.canonicalListID))

        for list in state.lists.sorted(by: { $0.id.description < $1.id.description }) {
            guard ownsList(list.id, in: state) else { continue }
            guard !pendingListConflicts.contains(list.id) else { continue }
            guard let mapping = accountLists.first(where: { $0.canonicalListID == list.id }) else {
                if list.deletedAt == nil {
                    result.append(.upsertList(canonicalListID: list.id, list: RemoteList(remoteID: "", name: list.name, colorHex: list.colorHex, position: list.position, isDeleted: false, updatedAt: list.updatedAt)))
                }
                continue
            }
            let baseline = state.listReplicas.first { $0.account == account && $0.canonicalListID == list.id }?.lastSyncedList
            if list.deletedAt != nil {
                guard baseline?.deletedAt == nil else { continue }
                result.append(.deleteList(canonicalListID: list.id, remoteID: mapping.remoteListID, revision: state.listReplicas.first { $0.account == account && $0.canonicalListID == list.id }?.remoteRevision))
            } else if baseline == nil || !CanonicalListMerger.sameContent(list, baseline!) {
                result.append(.upsertList(canonicalListID: list.id, list: RemoteList(remoteID: mapping.remoteListID, name: list.name, colorHex: list.colorHex, position: list.position, updatedAt: list.updatedAt, revision: state.listReplicas.first { $0.account == account && $0.canonicalListID == list.id }?.remoteRevision)))
            }
        }

        for task in state.tasks.sorted(by: { $0.id.description < $1.id.description }) {
            guard ownsTask(task.id, in: state) else { continue }
            guard !pendingTaskConflicts.contains(task.id) else { continue }
            let replica = state.taskReplicas.first { $0.externalID.account == account && $0.canonicalTaskID == task.id }
            let remoteID = replica?.externalID.remoteTaskID ?? ""
            let listRemoteID = task.listID.flatMap { state.mapping(account: account, canonicalListID: $0)?.remoteListID }
            if task.deletedAt != nil {
                guard let replica, replica.lastSyncedTask.deletedAt == nil else { continue }
                result.append(.deleteTask(canonicalTaskID: task.id, remoteID: remoteID, remoteListID: listRemoteID, revision: replica.remoteRevision))
            } else {
                let changed = replica == nil || replica?.lastSyncedTask != task
                guard changed else { continue }
                result.append(.upsertTask(canonicalTaskID: task.id, task: RemoteTask(
                    remoteID: remoteID,
                    title: task.title,
                    notes: task.notes,
                    remoteListID: listRemoteID,
                    isCompleted: task.isCompleted,
                    dueDate: task.dueDate,
                    completedAt: task.completedAt,
                    priority: task.priority,
                    isDeleted: false,
                    updatedAt: task.updatedAt,
                    revision: replica?.remoteRevision
                )))
            }
        }
        return result
    }

    private func applyRemoteMappings(_ mappings: [RemoteIDMapping], to state: inout SyncState, at date: Date) throws {
        for mapping in mappings {
            if let listID = mapping.canonicalListID {
                try ensureOwnedList(listID, in: state)
                upsertListMapping(ListMapping(account: account, canonicalListID: listID, remoteListID: mapping.remoteID, lastSeenAt: date), into: &state)
                if let list = state.lists.first(where: { $0.id == listID }) {
                    let existingRevision = state.listReplicas.first { $0.account == account && $0.canonicalListID == listID }?.remoteRevision
                    upsertListReplica(ListReplica(account: account, canonicalListID: listID, remoteListID: mapping.remoteID, lastSyncedList: list, lastSyncedAt: date, remoteRevision: mapping.revision ?? existingRevision), into: &state)
                }
            }
            if let taskID = mapping.canonicalTaskID,
               let task = state.tasks.first(where: { $0.id == taskID }) {
                try ensureOwnedTask(taskID, in: state)
                let current = state.taskReplicas.first { $0.externalID.account == account && $0.canonicalTaskID == taskID }
                let remoteID = mapping.remoteID
                let replica = TaskReplica(
                    externalID: ExternalTaskID(account: account, remoteTaskID: remoteID),
                    canonicalTaskID: taskID,
                    lastSyncedTask: current?.lastSyncedTask ?? task,
                    lastSyncedAt: date,
                    remoteRevision: mapping.revision
                )
                if let currentIndex = state.taskReplicas.firstIndex(where: { $0.externalID.account == account && $0.canonicalTaskID == taskID }) {
                    state.taskReplicas.remove(at: currentIndex)
                }
                upsertReplica(replica, into: &state)
            }
        }
    }

    private func applyAcceptedBaselines(
        mutations: [RemoteMutation],
        pushResult: PushResult,
        state: inout SyncState,
        at date: Date
    ) {
        let rejected = Set(pushResult.rejected.map { mutationID($0.mutation) })
        for mutation in mutations where !rejected.contains(mutationID(mutation)) {
            switch mutation {
            case let .upsertList(canonicalID, _):
                guard ownsList(canonicalID, in: state),
                      let list = state.lists.first(where: { $0.id == canonicalID }),
                      let mapping = state.listMappings.first(where: { $0.account == account && $0.canonicalListID == canonicalID }) else { continue }
                upsertListReplica(ListReplica(account: account, canonicalListID: canonicalID, remoteListID: mapping.remoteListID, lastSyncedList: list, lastSyncedAt: date), into: &state)
            case let .deleteList(canonicalID, _, _):
                guard ownsList(canonicalID, in: state),
                      let list = state.lists.first(where: { $0.id == canonicalID }),
                      let mapping = state.listMappings.first(where: { $0.account == account && $0.canonicalListID == canonicalID }) else { continue }
                upsertListReplica(ListReplica(account: account, canonicalListID: canonicalID, remoteListID: mapping.remoteListID, lastSyncedList: list, lastSyncedAt: date), into: &state)
            case let .upsertTask(canonicalID, _):
                guard ownsTask(canonicalID, in: state), let task = state.tasks.first(where: { $0.id == canonicalID }) else { continue }
                if let index = state.taskReplicas.firstIndex(where: { $0.externalID.account == account && $0.canonicalTaskID == canonicalID }) {
                    state.taskReplicas[index].lastSyncedTask = task
                    state.taskReplicas[index].lastSyncedAt = date
                }
            case let .deleteTask(canonicalID, _, _, _):
                guard ownsTask(canonicalID, in: state), let task = state.tasks.first(where: { $0.id == canonicalID }) else { continue }
                if let index = state.taskReplicas.firstIndex(where: { $0.externalID.account == account && $0.canonicalTaskID == canonicalID }) {
                    state.taskReplicas[index].lastSyncedTask = task
                    state.taskReplicas[index].lastSyncedAt = date
                }
            }
        }
    }

    private func mutationID(_ mutation: RemoteMutation) -> String {
        switch mutation {
        case let .upsertList(id, list): return "list-upsert-\(id.description)-\(list.remoteID)"
        case let .deleteList(id, remoteID, _): return "list-delete-\(id.description)-\(remoteID)"
        case let .upsertTask(id, task): return "task-upsert-\(id.description)-\(task.remoteID)"
        case let .deleteTask(id, remoteID, _, _): return "task-delete-\(id.description)-\(remoteID)"
        }
    }

    private func mutationOrder(_ lhs: RemoteMutation, _ rhs: RemoteMutation) -> Bool {
        func key(_ mutation: RemoteMutation) -> String {
            switch mutation {
            case let .upsertList(id, _): return "0-\(id.description)"
            case let .deleteList(id, _, _): return "1-\(id.description)"
            case let .upsertTask(id, _): return "2-\(id.description)"
            case let .deleteTask(id, _, _, _): return "3-\(id.description)"
            }
        }
        return key(lhs) < key(rhs)
    }

    private func enqueueConflict(
        for canonicalID: SyncID,
        base: CanonicalTask?,
        local: CanonicalTask,
        remote: CanonicalTask,
        fields: [ConflictField],
        state: inout SyncState,
        at date: Date
    ) {
        let conflictID = SyncID.deterministic(namespace: [account.provider.rawValue, account.accountID, canonicalID.description, remote.updatedAt.description, fields.map(\.rawValue).joined(separator: ",")].joined(separator: "|"))
        guard !state.conflicts.contains(where: { $0.id == conflictID && $0.resolution == .pending }) else { return }
        state.conflicts.append(SyncConflict(
            id: conflictID,
            account: account,
            canonicalTaskID: canonicalID,
            kind: .concurrentEdit,
            fields: fields,
            baseTask: base,
            localTask: local,
            remoteTask: remote,
            createdAt: date
        ))
    }

    private func enqueueListConflict(
        for canonicalID: SyncID,
        base: CanonicalList?,
        local: CanonicalList,
        remote: CanonicalList,
        fields: [ConflictField],
        state: inout SyncState,
        at date: Date
    ) {
        let conflictID = SyncID.deterministic(namespace: [account.provider.rawValue, account.accountID, canonicalID.description, remote.updatedAt.description, fields.map(\.rawValue).joined(separator: ",")].joined(separator: "|"))
        guard !state.conflicts.contains(where: { $0.id == conflictID && $0.resolution == .pending }) else { return }
        state.conflicts.append(SyncConflict(
            id: conflictID,
            account: account,
            canonicalListID: canonicalID,
            kind: .concurrentEdit,
            fields: fields,
            baseList: base,
            localList: local,
            remoteList: remote,
            createdAt: date
        ))
    }

    private func ownerOfTask(_ id: SyncID, in state: SyncState) -> SyncAccount? {
        state.taskOwner(id)
    }

    private func ownerOfList(_ id: SyncID, in state: SyncState) -> SyncAccount? {
        state.listOwner(id)
    }

    private func ownsTask(_ id: SyncID, in state: SyncState) -> Bool {
        ownerOfTask(id, in: state) == account
    }

    private func ownsList(_ id: SyncID, in state: SyncState) -> Bool {
        ownerOfList(id, in: state) == account
    }

    private func ensureNoForeignOwnership(entityType: EntityType, id: SyncID) async throws {
        guard try await !stateStore.isQuarantined(entityType: entityType, id: id) else {
            throw SyncEngineError.recordNotOwned(entityType: entityType, id: id)
        }
        let candidates = try await stateStore.ownershipCandidates(entityType: entityType, id: id)
        guard candidates.isEmpty || (candidates.count == 1 && candidates.contains(account)) else {
            throw SyncEngineError.recordNotOwned(entityType: entityType, id: id)
        }
    }

    private func ensureOwnedTask(_ id: SyncID, in state: SyncState) throws {
        guard ownsTask(id, in: state) else { throw SyncEngineError.recordNotOwned(entityType: .task, id: id) }
    }

    private func ensureOwnedList(_ id: SyncID, in state: SyncState) throws {
        guard ownsList(id, in: state) else { throw SyncEngineError.recordNotOwned(entityType: .list, id: id) }
    }

    private func ensureOwnedOrClaimTask(_ id: SyncID, in state: inout SyncState) throws {
        let candidates = state.taskOwnershipCandidates(id)
        if candidates.contains(where: { $0 != account }) || candidates.count > 1 {
            throw SyncEngineError.recordNotOwned(entityType: .task, id: id)
        }
        state.taskOwners[id] = account
    }

    private func ensureOwnedOrClaimList(_ id: SyncID, in state: inout SyncState) throws {
        let candidates = state.listOwnershipCandidates(id)
        if candidates.contains(where: { $0 != account }) || candidates.count > 1 {
            throw SyncEngineError.recordNotOwned(entityType: .list, id: id)
        }
        state.listOwners[id] = account
    }

    private func upsertTask(_ task: CanonicalTask, into state: inout SyncState) {
        if let index = state.tasks.firstIndex(where: { $0.id == task.id }) { state.tasks[index] = task }
        else { state.tasks.append(task) }
    }

    private func upsertList(_ list: CanonicalList, into state: inout SyncState) {
        if let index = state.lists.firstIndex(where: { $0.id == list.id }) { state.lists[index] = list }
        else { state.lists.append(list) }
    }

    private func upsertListMapping(_ mapping: ListMapping, into state: inout SyncState) {
        if let index = state.listMappings.firstIndex(where: { $0.account == mapping.account && $0.remoteListID == mapping.remoteListID }) {
            state.listMappings[index] = mapping
        } else if let index = state.listMappings.firstIndex(where: { $0.account == mapping.account && $0.canonicalListID == mapping.canonicalListID }) {
            state.listMappings[index] = mapping
        } else {
            state.listMappings.append(mapping)
        }
    }

    private func upsertListReplica(_ replica: ListReplica, into state: inout SyncState) {
        if let index = state.listReplicas.firstIndex(where: { $0.account == replica.account && $0.canonicalListID == replica.canonicalListID }) { state.listReplicas[index] = replica }
        else { state.listReplicas.append(replica) }
    }

    private func upsertReplica(_ replica: TaskReplica, into state: inout SyncState) {
        if let index = state.taskReplicas.firstIndex(where: { $0.externalID == replica.externalID }) { state.taskReplicas[index] = replica }
        else { state.taskReplicas.append(replica) }
    }

    private func upsertCursor(_ cursor: SyncCursor, into state: inout SyncState) {
        if let index = state.cursors.firstIndex(where: { $0.account == cursor.account }) { state.cursors[index] = cursor }
        else { state.cursors.append(cursor) }
    }
}

private extension CanonicalTask {
    func domainEquals(_ other: CanonicalTask) -> Bool {
        title == other.title && notes == other.notes && listID == other.listID && isCompleted == other.isCompleted && dueDate == other.dueDate && completedAt == other.completedAt && priority == other.priority && deletedAt == other.deletedAt
    }
}
