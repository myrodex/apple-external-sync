import Foundation
import SyncDomain

public enum AdapterCapability: String, Codable, CaseIterable, Sendable {
    case lists
    case taskNotes
    case dueDates
    case priorities
    case incrementalPull
    case conditionalWrites
    case remoteDeletion
    case providerRevision
    case fieldDiagnostics
}

/// Canonical fields whose representation may differ between providers. The values are
/// stable wire names so diagnostics can be persisted without coupling callers to Swift
/// enum spelling.
public enum AdapterField: String, Codable, CaseIterable, Hashable, Sendable {
    case listTitle = "list.title"
    case listColor = "list.colorHex"
    case listPosition = "list.position"
    case taskTitle = "task.title"
    case taskNotes = "task.notes"
    case taskList = "task.listID"
    case taskCompletion = "task.isCompleted"
    case taskDueDate = "task.dueDate"
    case taskCompletedAt = "task.completedAt"
    case taskPriority = "task.priority"
    case taskPosition = "task.position"
}

public enum FieldSupport: String, Codable, CaseIterable, Sendable {
    case native
    case transformed
    case unsupported
}

public enum FieldDiagnosticCode: String, Codable, CaseIterable, Sendable {
    case fieldLoss = "field_loss"
    case fieldTransformed = "field_transformed"
    case truncated
}

/// A non-fatal provider mapping diagnostic. Adapters must return one whenever a field
/// was dropped or its semantics changed, rather than silently losing user data.
public struct FieldLossDiagnostic: Codable, Hashable, Sendable {
    public let code: FieldDiagnosticCode
    public let field: AdapterField
    public let resourceType: String?
    public let resourceID: String?
    public let message: String
    public let sourceProvider: String?
    public let targetProvider: String?

    public init(
        code: FieldDiagnosticCode,
        field: AdapterField,
        resourceType: String? = nil,
        resourceID: String? = nil,
        message: String,
        sourceProvider: String? = nil,
        targetProvider: String? = nil
    ) {
        self.code = code
        self.field = field
        self.resourceType = resourceType
        self.resourceID = resourceID
        self.message = message
        self.sourceProvider = sourceProvider
        self.targetProvider = targetProvider
    }
}

/// Capability metadata exposed by adapters in addition to the coarse capability set.
public struct AdapterFieldCapabilities: Codable, Hashable, Sendable {
    public let fields: [AdapterField: FieldSupport]
    public let maxTitleLength: Int?
    public let maxNotesLength: Int?

    public init(
        fields: [AdapterField: FieldSupport],
        maxTitleLength: Int? = nil,
        maxNotesLength: Int? = nil
    ) {
        self.fields = fields
        self.maxTitleLength = maxTitleLength
        self.maxNotesLength = maxNotesLength
    }

    public func support(for field: AdapterField) -> FieldSupport {
        fields[field] ?? .unsupported
    }
}

public protocol FieldDiagnosticsProviding: Sendable {
    var fieldCapabilities: AdapterFieldCapabilities { get }
}

public struct RemoteList: Hashable, Codable, Sendable {
    public let remoteID: String
    public var name: String
    public var colorHex: String?
    public var position: String?
    public var isDeleted: Bool
    public var updatedAt: Date?
    public var revision: String?

    public init(
        remoteID: String,
        name: String,
        colorHex: String? = nil,
        position: String? = nil,
        isDeleted: Bool = false,
        updatedAt: Date? = nil,
        revision: String? = nil
    ) {
        self.remoteID = remoteID
        self.name = name
        self.colorHex = colorHex
        self.position = position
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

public struct RemoteTask: Hashable, Codable, Sendable {
    public let remoteID: String
    public var title: String
    public var notes: String?
    public var remoteListID: String?
    public var isCompleted: Bool
    public var dueDate: Date?
    public var completedAt: Date?
    public var priority: TaskPriority
    public var isDeleted: Bool
    public var updatedAt: Date?
    public var revision: String?

    public init(
        remoteID: String,
        title: String,
        notes: String? = nil,
        remoteListID: String? = nil,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        completedAt: Date? = nil,
        priority: TaskPriority = .none,
        isDeleted: Bool = false,
        updatedAt: Date? = nil,
        revision: String? = nil
    ) {
        self.remoteID = remoteID
        self.title = title
        self.notes = notes
        self.remoteListID = remoteListID
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.priority = priority
        self.isDeleted = isDeleted
        self.updatedAt = updatedAt
        self.revision = revision
    }
}

public enum RemoteChange: Hashable, Codable, Sendable {
    case list(RemoteList)
    case task(RemoteTask)
}

public struct RemoteChanges: Hashable, Codable, Sendable {
    public let changes: [RemoteChange]
    public let nextCursor: String?
    public let serverNow: Date
    /// A full snapshot permits the engine to infer remote deletions from absent IDs.
    /// Incremental feeds must emit explicit tombstones instead.
    public let isFullSnapshot: Bool
    public let diagnostics: [FieldLossDiagnostic]

    public init(
        changes: [RemoteChange],
        nextCursor: String?,
        serverNow: Date,
        isFullSnapshot: Bool = false,
        diagnostics: [FieldLossDiagnostic] = []
    ) {
        self.changes = changes
        self.nextCursor = nextCursor
        self.serverNow = serverNow
        self.isFullSnapshot = isFullSnapshot
        self.diagnostics = diagnostics
    }
}

public enum RemoteMutation: Hashable, Codable, Sendable {
    case upsertList(canonicalListID: SyncID, list: RemoteList)
    case deleteList(canonicalListID: SyncID, remoteID: String, revision: String?)
    case upsertTask(canonicalTaskID: SyncID, task: RemoteTask)
    case deleteTask(canonicalTaskID: SyncID, remoteID: String, remoteListID: String?, revision: String?)
}

public struct RemoteIDMapping: Hashable, Codable, Sendable {
    public let canonicalTaskID: SyncID?
    public let canonicalListID: SyncID?
    public let remoteID: String
    public let revision: String?

    public init(canonicalTaskID: SyncID? = nil, canonicalListID: SyncID? = nil, remoteID: String, revision: String? = nil) {
        self.canonicalTaskID = canonicalTaskID
        self.canonicalListID = canonicalListID
        self.remoteID = remoteID
        self.revision = revision
    }
}

public struct PushResult: Hashable, Codable, Sendable {
    public let accepted: Int
    public let rejected: [RejectedMutation]
    public let mappings: [RemoteIDMapping]
    public let nextCursor: String?
    public let serverNow: Date
    public let diagnostics: [FieldLossDiagnostic]

    public init(
        accepted: Int,
        rejected: [RejectedMutation] = [],
        mappings: [RemoteIDMapping] = [],
        nextCursor: String?,
        serverNow: Date,
        diagnostics: [FieldLossDiagnostic] = []
    ) {
        self.accepted = accepted
        self.rejected = rejected
        self.mappings = mappings
        self.nextCursor = nextCursor
        self.serverNow = serverNow
        self.diagnostics = diagnostics
    }
}

public struct RejectedMutation: Hashable, Codable, Sendable {
    public let mutation: RemoteMutation
    public let reason: String
    public let retryable: Bool

    public init(mutation: RemoteMutation, reason: String, retryable: Bool) {
        self.mutation = mutation
        self.reason = reason
        self.retryable = retryable
    }
}

public enum SyncAdapterError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case authenticationRequired
    case invalidResponse(String)
    case transport(String)
    case rateLimited(retryAfter: TimeInterval?)
    case conditionalWriteFailed(remoteRevision: String?)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .authenticationRequired: return "Authentication is required for this provider."
        case .invalidResponse(let message): return "Provider returned an invalid response: \(message)"
        case .transport(let message): return "Provider transport failed: \(message)"
        case .rateLimited(let retryAfter):
            return retryAfter.map { "Provider rate-limited the request; retry after \($0) seconds." }
                ?? "Provider rate-limited the request."
        case .conditionalWriteFailed(let revision):
            return revision.map { "The remote item changed (revision \($0))." }
                ?? "The remote item changed before the write completed."
        case .unsupported(let message): return "Provider capability is unsupported: \(message)"
        }
    }
}

public protocol ExternalSyncAdapter: Sendable {
    var account: SyncAccount { get }
    var capabilities: Set<AdapterCapability> { get }

    func pullChanges(since cursor: String?) async throws -> RemoteChanges
    func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult
}

public protocol DeviceOnlyOAuthProvider: Sendable {
    associatedtype Credential: Sendable
    func beginAuthorization() async throws -> URL
    func handleCallback(url: URL) async throws -> Credential
    func refresh(credential: Credential) async throws -> Credential
    func revoke(credential: Credential) async throws
}

public struct OAuthAuthorizationRequest: Sendable, Hashable {
    public let provider: SyncProvider
    public let authorizationURL: URL
    public let state: String
    public let codeVerifier: String?

    public init(provider: SyncProvider, authorizationURL: URL, state: String, codeVerifier: String? = nil) {
        self.provider = provider
        self.authorizationURL = authorizationURL
        self.state = state
        self.codeVerifier = codeVerifier
    }
}

public protocol ExternalSyncAdapterFactory: Sendable {
    func makeAdapter(account: SyncAccount) throws -> any ExternalSyncAdapter
}
