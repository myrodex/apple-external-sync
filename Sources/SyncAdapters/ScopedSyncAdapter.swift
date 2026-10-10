import Foundation
import SyncContracts
import SyncDomain

/// Mutable selection shared by the app shell and a single engine adapter. The provider
/// adapter remains stateless; changing the user's list selection only changes this scope.
public actor SelectedListScope {
    private var selectedRemoteListIDs: Set<String>

    public init(selectedRemoteListIDs: Set<String> = []) {
        self.selectedRemoteListIDs = selectedRemoteListIDs
    }

    public func set(_ ids: Set<String>) {
        selectedRemoteListIDs = ids
    }

    public func ids() -> Set<String> { selectedRemoteListIDs }
}

/// Filters one provider adapter to the explicit lists selected in the app. A filtered
/// snapshot is intentionally marked incremental: omitting an unselected list must never
/// be interpreted as a remote deletion by the engine.
public struct SelectedListsSyncAdapter: ExternalSyncAdapter, FieldDiagnosticsProviding {
    public let account: SyncAccount
    public let capabilities: Set<AdapterCapability>
    public let fieldCapabilities: AdapterFieldCapabilities

    private let base: any ExternalSyncAdapter
    private let scope: SelectedListScope

    public init(base: any ExternalSyncAdapter, scope: SelectedListScope) {
        self.base = base
        self.scope = scope
        self.account = base.account
        self.capabilities = base.capabilities
        self.fieldCapabilities = (base as? any FieldDiagnosticsProviding)?.fieldCapabilities ?? .allNative
    }

    public func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        let pulled = try await base.pullChanges(since: cursor)
        let selected = await scope.ids()
        let changes = pulled.changes.filter { change in
            switch change {
            case .list(let list): return selected.contains(list.remoteID)
            case .task(let task): return task.remoteListID.map(selected.contains) ?? false
            }
        }
        return RemoteChanges(
            changes: changes,
            nextCursor: pulled.nextCursor,
            serverNow: pulled.serverNow,
            isFullSnapshot: false,
            diagnostics: pulled.diagnostics
        )
    }

    public func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        let selected = await scope.ids()
        let filtered = mutations.filter { mutation in
            switch mutation {
            case .upsertList(_, let list): return selected.contains(list.remoteID) || list.remoteID.isEmpty
            case .deleteList(_, let remoteID, _): return selected.contains(remoteID)
            case .upsertTask(_, let task): return task.remoteListID.map(selected.contains) ?? false
            case .deleteTask(_, _, let remoteListID, _): return remoteListID.map(selected.contains) ?? false
            }
        }
        let acceptedScope = Set(filtered)
        let outsideScope = mutations.filter { !acceptedScope.contains($0) }.map {
            RejectedMutation(mutation: $0, reason: "The mutation targets a list that is not selected for synchronization.", retryable: false)
        }
        guard !filtered.isEmpty else {
            return PushResult(accepted: 0, rejected: outsideScope, nextCursor: cursor, serverNow: Date(), diagnostics: [])
        }
        let result = try await base.push(filtered, cursor: cursor)
        return PushResult(
            accepted: result.accepted,
            rejected: result.rejected + outsideScope,
            mappings: result.mappings,
            nextCursor: result.nextCursor,
            serverNow: result.serverNow,
            diagnostics: result.diagnostics
        )
    }
}
