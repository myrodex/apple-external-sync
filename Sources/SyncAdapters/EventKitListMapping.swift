import Foundation
import SyncDomain
import SyncContracts

/// Controls which EventKit reminder calendars are included in a sync account.
/// Selection is evaluated after every full refetch so a user's calendar choice can
/// change without rebuilding the adapter.
public protocol EventKitListSelection: Sendable {
    func includes(_ list: EventKitReminderListSnapshot) async -> Bool

    /// Whether an emitted EventKit pull represents the entire provider collection.
    /// Explicit selection scopes are partial by definition: omitted lists must not be
    /// interpreted by SyncEngine as remote deletions.
    func isCompleteSnapshot() async -> Bool
}

public extension EventKitListSelection {
    /// Custom selection policies default to a partial snapshot. A policy must opt into
    /// full-snapshot deletion inference explicitly through `AllEventKitListsSelection`.
    func isCompleteSnapshot() async -> Bool { false }
}

public struct AllEventKitListsSelection: EventKitListSelection {
    public init() {}
    public func includes(_ list: EventKitReminderListSnapshot) async -> Bool { true }
    public func isCompleteSnapshot() async -> Bool { true }
}

/// Explicit identifier selection. It intentionally does not match by name: names are
/// mutable and are not safe identity keys.
public struct ExplicitEventKitListSelection: EventKitListSelection {
    public private(set) var selectedListIDs: Set<String>

    public init(selectedListIDs: Set<String>) {
        self.selectedListIDs = selectedListIDs
    }

    public func includes(_ list: EventKitReminderListSnapshot) async -> Bool {
        selectedListIDs.contains(list.id)
    }

    public func isCompleteSnapshot() async -> Bool { false }
}

/// Maps canonical list IDs to EventKit calendar identifiers. A mapping is required
/// before a task can be written; the adapter never guesses based on list names.
public protocol EventKitListMapping: Sendable {
    func remoteListID(for canonicalListID: SyncID) async -> String?
    func setRemoteListID(_ remoteListID: String, for canonicalListID: SyncID) async throws
    func removeRemoteListID(for canonicalListID: SyncID) async
}

public actor InMemoryEventKitListMapping: EventKitListMapping {
    private var values: [SyncID: String]

    public init(values: [SyncID: String] = [:]) {
        self.values = values
    }

    public func remoteListID(for canonicalListID: SyncID) -> String? {
        values[canonicalListID]
    }

    public func setRemoteListID(_ remoteListID: String, for canonicalListID: SyncID) throws {
        guard !remoteListID.isEmpty else {
            throw SyncAdapterError.invalidResponse("EventKit returned an empty calendar identifier.")
        }
        values[canonicalListID] = remoteListID
    }

    public func removeRemoteListID(for canonicalListID: SyncID) {
        values.removeValue(forKey: canonicalListID)
    }

    public func allMappings() -> [SyncID: String] { values }
}

/// Actor-backed list selection used by a live app coordinator. The adapter reads the
/// current set for every full refetch, so changing selection takes effect without
/// rebuilding the EventKit adapter or engine.
public actor MutableEventKitListSelection: EventKitListSelection {
    private var selectedListIDs: Set<String>

    public init(selectedListIDs: Set<String> = []) {
        self.selectedListIDs = selectedListIDs
    }

    public func includes(_ list: EventKitReminderListSnapshot) async -> Bool {
        selectedListIDs.contains(list.id)
    }

    public func isCompleteSnapshot() async -> Bool { false }

    public func replace(with listIDs: Set<String>) {
        selectedListIDs = listIDs
    }

    public func selectedIDs() -> Set<String> {
        selectedListIDs
    }
}
