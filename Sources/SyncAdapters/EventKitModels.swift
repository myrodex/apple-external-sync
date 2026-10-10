import Foundation
import SyncDomain

/// Access levels reported by EventKit for the reminders entity.
///
/// EventKit gained separate read/write access levels on iOS 17 and macOS 14. The
/// adapter only treats `.fullAccess` (or the pre-split `.authorized`) as readable;
/// `.writeOnly` is never enough for a pull because EventKit may return an empty store.
public enum EventKitRemindersAuthorizationStatus: String, Codable, CaseIterable, Sendable {
    case notDetermined
    case restricted
    case denied
    case authorized
    case writeOnly
    case fullAccess
    case unknown

    public var canRead: Bool {
        switch self {
        case .authorized, .fullAccess: return true
        case .notDetermined, .restricted, .denied, .writeOnly, .unknown: return false
        }
    }

    /// This adapter performs read/merge/write synchronization. Write-only access cannot
    /// safely update existing items or enumerate selected lists, so it is insufficient.
    public var canSynchronize: Bool { canRead && canWrite }

    private var canWrite: Bool {
        switch self {
        case .authorized, .writeOnly, .fullAccess: return true
        case .notDetermined, .restricted, .denied, .unknown: return false
        }
    }
}

/// A provider-native reminder list snapshot. EventKit does not expose creation or
/// modification dates for calendars, so the concrete store uses a stable epoch date
/// and derives the revision from the fields that EventKit does expose.
public struct EventKitReminderListSnapshot: Hashable, Sendable {
    public let id: String
    public var name: String
    public var colorHex: String?
    public var isDefault: Bool
    public var isReadOnly: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: String

    public init(
        id: String,
        name: String,
        colorHex: String? = nil,
        isDefault: Bool = false,
        isReadOnly: Bool = false,
        createdAt: Date = .init(timeIntervalSince1970: 0),
        updatedAt: Date = .init(timeIntervalSince1970: 0),
        revision: String? = nil
    ) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
        self.isDefault = isDefault
        self.isReadOnly = isReadOnly
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision ?? Self.makeRevision(id: id, name: name, colorHex: colorHex, isDefault: isDefault, isReadOnly: isReadOnly)
    }

    public static func makeRevision(id: String, name: String, colorHex: String?, isDefault: Bool, isReadOnly: Bool = false) -> String {
        EventKitRevision.hash([id, name, colorHex ?? "", isDefault ? "1" : "0", isReadOnly ? "1" : "0"])
    }
}

/// A provider-native reminder snapshot returned by an `EventKitRemindersStore`.
public struct EventKitReminderSnapshot: Hashable, Sendable {
    public let id: String
    public var listID: String
    public var title: String
    public var notes: String?
    public var isCompleted: Bool
    public var dueDate: Date?
    public var completedAt: Date?
    public var priority: TaskPriority
    public var createdAt: Date
    public var updatedAt: Date
    public var revision: String

    public init(
        id: String,
        listID: String,
        title: String,
        notes: String? = nil,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        completedAt: Date? = nil,
        priority: TaskPriority = .none,
        createdAt: Date,
        updatedAt: Date,
        revision: String? = nil
    ) {
        self.id = id
        self.listID = listID
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.priority = priority
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.revision = revision ?? Self.makeRevision(
            id: id,
            listID: listID,
            title: title,
            notes: notes,
            isCompleted: isCompleted,
            dueDate: dueDate,
            completedAt: completedAt,
            priority: priority,
            updatedAt: updatedAt
        )
    }

    public static func makeRevision(
        id: String,
        listID: String,
        title: String,
        notes: String?,
        isCompleted: Bool,
        dueDate: Date?,
        completedAt: Date?,
        priority: TaskPriority,
        updatedAt: Date
    ) -> String {
        EventKitRevision.hash([
            id,
            listID,
            title,
            notes ?? "",
            isCompleted ? "1" : "0",
            dueDate.map(EventKitRevision.dateString) ?? "",
            completedAt.map(EventKitRevision.dateString) ?? "",
            String(priority.rawValue),
            EventKitRevision.dateString(updatedAt)
        ])
    }
}

/// The fields writable through the reminders adapter. `id` is optional for creates;
/// an existing identifier is used for an update.
public struct EventKitReminderWrite: Hashable, Sendable {
    public let id: String?
    public let listID: String
    public let title: String
    public let notes: String?
    public let isCompleted: Bool
    public let dueDate: Date?
    public let completedAt: Date?
    public let priority: TaskPriority

    public init(
        id: String? = nil,
        listID: String,
        title: String,
        notes: String? = nil,
        isCompleted: Bool = false,
        dueDate: Date? = nil,
        completedAt: Date? = nil,
        priority: TaskPriority = .none
    ) {
        self.id = id
        self.listID = listID
        self.title = title
        self.notes = notes
        self.isCompleted = isCompleted
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.priority = priority
    }
}

public struct EventKitReminderListWrite: Hashable, Sendable {
    public let id: String?
    public let name: String
    public let colorHex: String?

    public init(id: String? = nil, name: String, colorHex: String? = nil) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }
}

/// A testable boundary around EventKit. Production uses `EventKitStore`; tests can
/// implement this protocol with an actor-backed fake without constructing EK objects.
public protocol EventKitRemindersStore: Sendable {
    func authorizationStatus() async -> EventKitRemindersAuthorizationStatus
    func requestFullAccess() async throws -> Bool

    func fetchLists() async throws -> [EventKitReminderListSnapshot]
    func fetchReminders(listIDs: Set<String>) async throws -> [EventKitReminderSnapshot]
    func fetchReminder(id: String) async throws -> EventKitReminderSnapshot?
    func fetchList(id: String) async throws -> EventKitReminderListSnapshot?

    func saveList(_ list: EventKitReminderListWrite) async throws -> EventKitReminderListSnapshot
    func deleteList(id: String) async throws
    func saveReminder(_ reminder: EventKitReminderWrite) async throws -> EventKitReminderSnapshot
    func deleteReminder(id: String) async throws
}

/// A source of EventKit store-change signals. EventKit notifications are deliberately
/// coarse: each signal means "refetch the selected lists", not "apply this one item".
public protocol EventKitStoreChangeSource: Sendable {
    func events() -> AsyncStream<Void>
}

public struct EventKitRevision {
    private init() {}

    fileprivate static func dateString(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }

    /// FNV-1a is deterministic, available on all Apple platforms, and sufficient for
    /// a provider revision token (it is not used as a security or integrity primitive).
    fileprivate static func hash(_ values: [String]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in values.joined(separator: "\u{1f}").utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x100000001b3
        }
        return String(hash, radix: 16)
    }
}
