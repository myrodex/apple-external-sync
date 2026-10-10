import Foundation

/// The small boundary consumed by SwiftUI. Implementations belong to the sync
/// runtime and are responsible for adapters, persistence, merge policy, and
/// provider permissions. Views never call providers directly.
public protocol SyncAppCoordinator: Sendable {
    func loadSnapshot() async throws -> SyncAppSnapshot
    func requestPermissions() async throws -> SyncAppSnapshot
    func connect(provider: SyncProviderChoice) async throws -> SyncAppSnapshot
    func disconnect() async throws -> SyncAppSnapshot
    func updateListSelection(_ selectedListIDs: Set<String>) async throws -> SyncAppSnapshot
    func syncNow() async throws -> SyncAppSnapshot
    func resolveConflict(id: String, resolution: SyncConflictResolution) async throws -> SyncAppSnapshot
}

/// A deterministic coordinator for SwiftUI previews, documentation screenshots,
/// and app-shell tests. It deliberately models every state transition through the
/// same contract as production instead of embedding fake sync logic in views.
public actor PreviewSyncCoordinator: SyncAppCoordinator {
    private var snapshot: SyncAppSnapshot
    public init(snapshot: SyncAppSnapshot = PreviewSyncCoordinator.defaultSnapshot) {
        self.snapshot = snapshot
    }

    public func loadSnapshot() async throws -> SyncAppSnapshot { snapshot }

    public func requestPermissions() async throws -> SyncAppSnapshot {
        snapshot.permissions = snapshot.permissions.map {
            SyncPermission(kind: $0.kind, status: .granted, explanation: $0.explanation)
        }
        snapshot.lastError = nil
        return snapshot
    }

    public func connect(provider: SyncProviderChoice) async throws -> SyncAppSnapshot {
        snapshot.connection = SyncConnectionState(
            provider: provider,
            status: .connected,
            accountName: "Preview account",
            detail: "Connected for preview"
        )
        snapshot.lastError = nil
        return snapshot
    }

    public func disconnect() async throws -> SyncAppSnapshot {
        snapshot.connection = SyncConnectionState()
        snapshot.availableLists = []
        snapshot.selectedListIDs = []
        return snapshot
    }

    public func updateListSelection(_ selectedListIDs: Set<String>) async throws -> SyncAppSnapshot {
        let validIDs = Set(snapshot.availableLists.map(\.id))
        snapshot.selectedListIDs = selectedListIDs.intersection(validIDs)
        snapshot.lastError = nil
        return snapshot
    }

    public func syncNow() async throws -> SyncAppSnapshot {
        guard snapshot.connection.isConnected else {
            throw SyncAppCoordinatorError.notConnected
        }
        guard snapshot.hasSelectedLists else {
            throw SyncAppCoordinatorError.noListsSelected
        }
        let now = Date()
        snapshot.lastSync = SyncRunSummary(
            startedAt: now.addingTimeInterval(-0.25),
            finishedAt: now,
            status: .succeeded,
            scannedCount: snapshot.selectedListIDs.count,
            updatedCount: snapshot.selectedListIDs.count
        )
        snapshot.lastError = nil
        return snapshot
    }

    public func resolveConflict(id: String, resolution: SyncConflictResolution) async throws -> SyncAppSnapshot {
        guard snapshot.conflicts.contains(where: { $0.id == id }) else {
            throw SyncAppCoordinatorError.conflictNotFound
        }
        snapshot.conflicts.removeAll { $0.id == id }
        snapshot.lastError = nil
        return snapshot
    }

    public static let defaultSnapshot = SyncAppSnapshot(
        connection: SyncConnectionState(),
        permissions: [
            SyncPermission(kind: .reminders, explanation: "Read and update the lists you choose to sync."),
            SyncPermission(kind: .notifications, explanation: "Notify you when a background sync needs attention.")
        ],
        availableLists: [
            SyncListOption(id: "work", name: "Work", detail: "12 tasks"),
            SyncListOption(id: "personal", name: "Personal", detail: "8 tasks"),
            SyncListOption(id: "shopping", name: "Shopping", detail: "4 tasks")
        ]
    )
}

public enum SyncAppCoordinatorError: Error, LocalizedError, Equatable, Sendable {
    case notConnected
    case noListsSelected
    case conflictNotFound
    case invalidSelection

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Connect an account before starting a sync."
        case .noListsSelected: return "Choose at least one list before starting a sync."
        case .conflictNotFound: return "That conflict is no longer available."
        case .invalidSelection: return "One or more selected lists are no longer available."
        }
    }
}
