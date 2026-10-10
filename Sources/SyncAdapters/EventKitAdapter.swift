import Foundation
import SyncDomain
import SyncContracts

/// EventKit Reminders adapter.
///
/// EventKit has no server-side change cursor. `pullChanges` therefore performs a
/// complete refetch of the selected calendars and returns a deterministic snapshot.
/// The adapter's `events()` stream coalesces `EKEventStoreChanged` notifications and
/// is the integration hook for triggering another pull in the sync engine.
public actor EventKitRemindersAdapter: ExternalSyncAdapter, FieldDiagnosticsProviding {
    public nonisolated let account: SyncAccount
    public nonisolated let capabilities: Set<AdapterCapability> = [
        .lists, .taskNotes, .dueDates, .priorities, .remoteDeletion, .providerRevision, .fieldDiagnostics
    ]

    public nonisolated let fieldCapabilities = AdapterFieldCapabilities(
        fields: [
            .listTitle: .native,
            .listColor: .native,
            .listPosition: .unsupported,
            .taskTitle: .native,
            .taskNotes: .native,
            .taskList: .native,
            .taskCompletion: .native,
            .taskDueDate: .native,
            .taskCompletedAt: .native,
            .taskPriority: .transformed,
            .taskPosition: .unsupported
        ]
    )

    private let store: any EventKitRemindersStore
    private let selection: any EventKitListSelection
    private let mapping: any EventKitListMapping
    private let changeSource: any EventKitStoreChangeSource
    private let now: @Sendable () -> Date

    public init(
        account: SyncAccount,
        store: any EventKitRemindersStore,
        selection: any EventKitListSelection = AllEventKitListsSelection(),
        mapping: any EventKitListMapping,
        changeSource: any EventKitStoreChangeSource,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.account = account
        self.store = store
        self.selection = selection
        self.mapping = mapping
        self.changeSource = changeSource
        self.now = now
    }

    public func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        _ = cursor // EventKit has no incremental cursor; every pull is a complete snapshot.
        try await requireReadAccess()
        let lists = try await selectedLists()
        let reminders = try await store.fetchReminders(listIDs: Set(lists.map(\.id)))
        let listChanges = lists.map { list in
            RemoteChange.list(RemoteList(
                remoteID: list.id,
                name: list.name,
                colorHex: list.colorHex,
                position: nil,
                isDeleted: false,
                updatedAt: list.updatedAt,
                revision: list.revision
            ))
        }
        let selectedIDs = Set(lists.map(\.id))
        let taskChanges = reminders
            .filter { selectedIDs.contains($0.listID) }
            .map { reminder in
                RemoteChange.task(RemoteTask(
                    remoteID: reminder.id,
                    title: reminder.title,
                    notes: reminder.notes,
                    remoteListID: reminder.listID,
                    isCompleted: reminder.isCompleted,
                    dueDate: reminder.dueDate,
                    completedAt: reminder.completedAt,
                    priority: reminder.priority,
                    isDeleted: false,
                    updatedAt: reminder.updatedAt,
                    revision: reminder.revision
                ))
            }
        let diagnostics = lists.map { list in
            FieldLossDiagnostic(
                code: .fieldLoss,
                field: .listPosition,
                resourceType: "list",
                resourceID: list.id,
                message: "EventKit does not expose a stable list ordering key.",
                sourceProvider: account.provider.rawValue
            )
        }
        return RemoteChanges(
            changes: listChanges + taskChanges,
            nextCursor: nil,
            serverNow: now(),
            isFullSnapshot: true,
            diagnostics: diagnostics
        )
    }

    public func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        _ = cursor
        try await requireWriteAccess()
        var accepted = 0
        var rejected: [RejectedMutation] = []
        var mappings: [RemoteIDMapping] = []
        var diagnostics: [FieldLossDiagnostic] = []

        for mutation in mutations {
            do {
                switch mutation {
                case let .upsertList(canonicalListID, list):
                    guard !list.isDeleted else {
                        try await deleteList(canonicalListID: canonicalListID, remoteID: list.remoteID)
                        accepted += 1
                        continue
                    }
                    if list.position != nil {
                        diagnostics.append(FieldLossDiagnostic(
                            code: .fieldLoss,
                            field: .listPosition,
                            resourceType: "list",
                            resourceID: list.remoteID.isEmpty ? nil : list.remoteID,
                            message: "EventKit cannot persist the canonical list ordering key.",
                            sourceProvider: account.provider.rawValue
                        ))
                    }
                    let write = EventKitReminderListWrite(
                        id: list.remoteID.isEmpty ? nil : list.remoteID,
                        name: list.name,
                        colorHex: list.colorHex
                    )
                    let result = try await store.saveList(write)
                    try await mapping.setRemoteListID(result.id, for: canonicalListID)
                    mappings.append(RemoteIDMapping(canonicalListID: canonicalListID, remoteID: result.id, revision: result.revision))
                    accepted += 1

                case let .deleteList(canonicalListID, remoteID, _):
                    try await deleteList(canonicalListID: canonicalListID, remoteID: remoteID)
                    accepted += 1

                case let .upsertTask(canonicalTaskID, task):
                    guard !task.isDeleted else {
                        guard !task.remoteID.isEmpty else {
                            throw SyncAdapterError.unsupported("Deleting an EventKit reminder requires a remote identifier.")
                        }
                        try await store.deleteReminder(id: task.remoteID)
                        accepted += 1
                        continue
                    }
                    guard let remoteListID = task.remoteListID, !remoteListID.isEmpty else {
                        throw SyncAdapterError.unsupported("An EventKit reminder must be mapped to a reminder list.")
                    }
                    if task.priority == .urgent {
                        diagnostics.append(FieldLossDiagnostic(
                            code: .fieldTransformed,
                            field: .taskPriority,
                            resourceType: "task",
                            resourceID: task.remoteID.isEmpty ? nil : task.remoteID,
                            message: "EventKit has no separate urgent priority; urgent is stored as high.",
                            sourceProvider: account.provider.rawValue
                        ))
                    }
                    let result = try await store.saveReminder(EventKitReminderWrite(
                        id: task.remoteID.isEmpty ? nil : task.remoteID,
                        listID: remoteListID,
                        title: task.title,
                        notes: task.notes,
                        isCompleted: task.isCompleted,
                        dueDate: task.dueDate,
                        completedAt: task.completedAt,
                        priority: task.priority
                    ))
                    mappings.append(RemoteIDMapping(canonicalTaskID: canonicalTaskID, remoteID: result.id, revision: result.revision))
                    accepted += 1

                case let .deleteTask(_, remoteID, _, _):
                    guard !remoteID.isEmpty else {
                        throw SyncAdapterError.unsupported("Deleting an EventKit reminder requires a remote identifier.")
                    }
                    try await store.deleteReminder(id: remoteID)
                    accepted += 1
                }
            } catch {
                rejected.append(RejectedMutation(mutation: mutation, reason: error.localizedDescription, retryable: false))
            }
        }

        return PushResult(
            accepted: accepted,
            rejected: rejected,
            mappings: mappings,
            nextCursor: nil,
            serverNow: now(),
            diagnostics: diagnostics
        )
    }

    /// A coarse change signal. Consumers should call `pullChanges` after each event.
    public nonisolated func events() -> AsyncStream<Void> {
        changeSource.events()
    }

    public func authorizationStatus() async -> EventKitRemindersAuthorizationStatus {
        await store.authorizationStatus()
    }

    @discardableResult
    public func requestFullAccess() async throws -> Bool {
        try await store.requestFullAccess()
    }

    private func selectedLists() async throws -> [EventKitReminderListSnapshot] {
        let allLists = try await store.fetchLists()
        var selected: [EventKitReminderListSnapshot] = []
        selected.reserveCapacity(allLists.count)
        for list in allLists where await selection.includes(list) {
            selected.append(list)
        }
        return selected
    }

    private func requireReadAccess() async throws {
        let status = await store.authorizationStatus()
        guard status.canRead else {
            if status == .notDetermined {
                throw SyncAdapterError.authenticationRequired
            }
            throw SyncAdapterError.unavailable("EventKit reminders read access is not available (status: \(status.rawValue)).")
        }
    }

    private func requireWriteAccess() async throws {
        let status = await store.authorizationStatus()
        guard status.canSynchronize else {
            if status == .notDetermined {
                throw SyncAdapterError.authenticationRequired
            }
            throw SyncAdapterError.unavailable("EventKit reminders write access is not available (status: \(status.rawValue)).")
        }
    }

    private func deleteList(canonicalListID: SyncID, remoteID: String) async throws {
        guard !remoteID.isEmpty else {
            guard await mapping.remoteListID(for: canonicalListID) != nil else {
                throw SyncAdapterError.unsupported("Deleting an EventKit list requires an explicit list mapping.")
            }
            await mapping.removeRemoteListID(for: canonicalListID)
            return
        }
        try await store.deleteList(id: remoteID)
        await mapping.removeRemoteListID(for: canonicalListID)
    }
}
