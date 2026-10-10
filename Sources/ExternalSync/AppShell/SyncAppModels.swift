import Foundation
import SyncDomain

/// Providers surfaced by the app shell. The sync engine owns provider mechanics;
/// the shell only carries the user's explicit provider choice into that engine.
public enum SyncProviderChoice: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case appleReminders
    case googleTasks
    case microsoftToDo
    case customREST

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .appleReminders: return "Apple Reminders"
        case .googleTasks: return "Google Tasks"
        case .microsoftToDo: return "Microsoft To Do"
        case .customREST: return "Custom REST service"
        }
    }

    public var systemImage: String {
        switch self {
        case .appleReminders: return "checklist"
        case .googleTasks: return "g.circle"
        case .microsoftToDo: return "checkmark.square"
        case .customREST: return "server.rack"
        }
    }

    public init?(syncProvider: SyncProvider) {
        switch syncProvider {
        case .eventKit: self = .appleReminders
        case .googleTasks: self = .googleTasks
        case .microsoftGraph: self = .microsoftToDo
        case .genericREST: self = .customREST
        }
    }

    public var syncProvider: SyncProvider {
        switch self {
        case .appleReminders: return .eventKit
        case .googleTasks: return .googleTasks
        case .microsoftToDo: return .microsoftGraph
        case .customREST: return .genericREST
        }
    }
}

public enum SyncPermissionKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case reminders
    case calendar
    case notifications

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .reminders: return "Reminders"
        case .calendar: return "Calendar"
        case .notifications: return "Notifications"
        }
    }

    public var systemImage: String {
        switch self {
        case .reminders: return "checklist"
        case .calendar: return "calendar"
        case .notifications: return "bell"
        }
    }

    /// Reminders access is required for the Reminders-first sync path. Calendar
    /// access is intentionally not requested because list/task sync does not need it;
    /// notifications improve reporting but are optional.
    public var isRequiredForSync: Bool {
        self == .reminders
    }
}

public enum SyncPermissionStatus: String, Codable, Hashable, Sendable {
    case notRequested
    case requesting
    case granted
    case denied
    case restricted

    public var isGranted: Bool { self == .granted }
}

public struct SyncPermission: Codable, Hashable, Sendable, Identifiable {
    public let kind: SyncPermissionKind
    public var status: SyncPermissionStatus
    public var explanation: String

    public init(
        kind: SyncPermissionKind,
        status: SyncPermissionStatus = .notRequested,
        explanation: String
    ) {
        self.kind = kind
        self.status = status
        self.explanation = explanation
    }

    public var id: SyncPermissionKind { kind }
}


public struct SyncCapabilitySummary: Codable, Hashable, Sendable, Identifiable {
    public let field: String
    public let support: String

    public init(field: String, support: String) {
        self.field = field
        self.support = support
    }

    public var id: String { field }
}

public struct SyncWarningSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let code: String
    public let field: String?
    public let message: String
    public let resourceID: String?

    public init(
        id: UUID = UUID(),
        code: String,
        field: String? = nil,
        message: String,
        resourceID: String? = nil
    ) {
        self.id = id
        self.code = code
        self.field = field
        self.message = message
        self.resourceID = resourceID
    }
}

public struct SyncListOption: Codable, Hashable, Sendable, Identifiable {
    /// This is the provider's opaque list ID. It must not be derived from the name.
    public let id: String
    public let name: String
    public let detail: String?
    public let isReadOnly: Bool

    public init(id: String, name: String, detail: String? = nil, isReadOnly: Bool = false) {
        self.id = id
        self.name = name
        self.detail = detail
        self.isReadOnly = isReadOnly
    }
}

public enum AppSyncRunStatus: String, Codable, Hashable, Sendable {
    case running
    case succeeded
    case partiallySucceeded
    case failed
    case cancelled

    public var title: String {
        switch self {
        case .running: return "Syncing"
        case .succeeded: return "Synced"
        case .partiallySucceeded: return "Synced with warnings"
        case .failed: return "Sync failed"
        case .cancelled: return "Sync cancelled"
        }
    }

    /// A committed sync with rejected writes or conflicts is not a successful
    /// background run: the scheduler must report non-success so the system can retry.
    public var isSuccessfulForBackground: Bool {
        self == .succeeded
    }

    public var systemImage: String {
        switch self {
        case .running: return "arrow.triangle.2.circlepath"
        case .succeeded: return "checkmark.circle.fill"
        case .partiallySucceeded: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle"
        }
    }
}

public struct SyncRunSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let status: AppSyncRunStatus
    public let scannedCount: Int
    public let createdCount: Int
    public let updatedCount: Int
    public let deletedCount: Int
    public let conflictCount: Int
    public let errorMessage: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date,
        finishedAt: Date? = nil,
        status: AppSyncRunStatus,
        scannedCount: Int = 0,
        createdCount: Int = 0,
        updatedCount: Int = 0,
        deletedCount: Int = 0,
        conflictCount: Int = 0,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.status = status
        self.scannedCount = scannedCount
        self.createdCount = createdCount
        self.updatedCount = updatedCount
        self.deletedCount = deletedCount
        self.conflictCount = conflictCount
        self.errorMessage = errorMessage
    }

    public var changedCount: Int { createdCount + updatedCount + deletedCount }
}

public struct SyncConflictSummary: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let listName: String?
    public let fields: [String]
    public let detectedAt: Date

    public init(id: String, title: String, listName: String? = nil, fields: [String], detectedAt: Date) {
        self.id = id
        self.title = title
        self.listName = listName
        self.fields = fields
        self.detectedAt = detectedAt
    }
}

public enum SyncErrorPhase: String, Codable, Hashable, Sendable {
    case permissions
    case connection
    case listSelection
    case pull
    case merge
    case push
    case persistence
    case unknown
}

public struct SyncErrorState: Codable, Hashable, Sendable, Identifiable {
    public let id: UUID
    public let phase: SyncErrorPhase
    public let message: String
    public let occurredAt: Date
    public let recoveryAction: String?

    public init(
        id: UUID = UUID(),
        phase: SyncErrorPhase,
        message: String,
        occurredAt: Date = Date(),
        recoveryAction: String? = nil
    ) {
        self.id = id
        self.phase = phase
        self.message = message
        self.occurredAt = occurredAt
        self.recoveryAction = recoveryAction
    }
}

public struct SyncOAuthAuthorization: Hashable, Sendable {
    public let provider: SyncProviderChoice
    public let url: URL

    public init(provider: SyncProviderChoice, url: URL) {
        self.provider = provider
        self.url = url
    }
}

public enum SyncConnectionStatus: String, Codable, Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case authenticationRequired
    case failed

    public var title: String {
        switch self {
        case .disconnected: return "Not connected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .authenticationRequired: return "Sign-in required"
        case .failed: return "Connection unavailable"
        }
    }
}

public struct SyncConnectionState: Codable, Hashable, Sendable {
    public var provider: SyncProviderChoice?
    public var status: SyncConnectionStatus
    public var accountName: String?
    public var detail: String?

    public init(
        provider: SyncProviderChoice? = nil,
        status: SyncConnectionStatus = .disconnected,
        accountName: String? = nil,
        detail: String? = nil
    ) {
        self.provider = provider
        self.status = status
        self.accountName = accountName
        self.detail = detail
    }

    public var isConnected: Bool { status == .connected }
}

public struct SyncAppSnapshot: Codable, Hashable, Sendable {
    public var connection: SyncConnectionState
    public var permissions: [SyncPermission]
    public var availableLists: [SyncListOption]
    public var selectedListIDs: Set<String>
    public var lastSync: SyncRunSummary?
    public var conflicts: [SyncConflictSummary]
    public var capabilities: [SyncCapabilitySummary]
    public var warnings: [SyncWarningSummary]
    public var lastError: SyncErrorState?

    public init(
        connection: SyncConnectionState = SyncConnectionState(),
        permissions: [SyncPermission] = [],
        availableLists: [SyncListOption] = [],
        selectedListIDs: Set<String> = [],
        lastSync: SyncRunSummary? = nil,
        conflicts: [SyncConflictSummary] = [],
        capabilities: [SyncCapabilitySummary] = [],
        warnings: [SyncWarningSummary] = [],
        lastError: SyncErrorState? = nil
    ) {
        self.connection = connection
        self.permissions = permissions
        self.availableLists = availableLists
        self.selectedListIDs = selectedListIDs
        self.lastSync = lastSync
        self.conflicts = conflicts
        self.capabilities = capabilities
        self.warnings = warnings
        self.lastError = lastError
    }

    public var pendingPermissionCount: Int {
        permissions.filter { $0.kind.isRequiredForSync && !$0.status.isGranted }.count
    }

    public var hasRequiredPermissions: Bool {
        permissions.filter { $0.kind.isRequiredForSync }.allSatisfy { $0.status.isGranted }
    }

    public var hasSelectedLists: Bool {
        !selectedListIDs.isEmpty
    }
}

public enum SyncConflictResolution: String, Codable, Hashable, Sendable {
    case keepLocal
    case keepRemote
    case dismiss
}
