import Foundation
import SyncContracts

/// JSON path used by the declarative REST adapter. Paths are dot-separated object
/// members; an empty path refers to the response root. Array indexing is intentionally
/// not supported so provider schemas stay simple and deterministic.
public struct RESTJSONPath: RawRepresentable, Codable, Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ value: String) { self.rawValue = value }
    public init(stringLiteral value: StringLiteralType) { self.rawValue = value }
    public var description: String { rawValue }
    var components: [String] { rawValue.split(separator: ".", omittingEmptySubsequences: true).map(String.init) }
}

public enum RESTPaginationMode: String, Codable, Hashable, Sendable {
    case none
    case cursor
    case nextLink
    case page
}

/// Declarative pagination metadata. `itemsPath` and token paths are relative to each
/// response page. A next-link value is treated as an opaque URL and never reconstructed.
public struct RESTPaginationDescriptor: Codable, Hashable, Sendable {
    public let mode: RESTPaginationMode
    public let itemsPath: RESTJSONPath
    public let nextCursorPath: RESTJSONPath?
    public let nextLinkPath: RESTJSONPath?
    public let cursorQueryName: String
    public let pageQueryName: String
    public let pageSizeQueryName: String?
    public let pageSize: Int
    public let maxPages: Int

    public init(
        mode: RESTPaginationMode = .none,
        itemsPath: RESTJSONPath = "items",
        nextCursorPath: RESTJSONPath? = "nextCursor",
        nextLinkPath: RESTJSONPath? = "nextLink",
        cursorQueryName: String = "cursor",
        pageQueryName: String = "page",
        pageSizeQueryName: String? = "limit",
        pageSize: Int = 100,
        maxPages: Int = 10_000
    ) {
        self.mode = mode
        self.itemsPath = itemsPath
        self.nextCursorPath = nextCursorPath
        self.nextLinkPath = nextLinkPath
        self.cursorQueryName = cursorQueryName
        self.pageQueryName = pageQueryName
        self.pageSizeQueryName = pageSizeQueryName
        self.pageSize = max(1, pageSize)
        self.maxPages = max(1, maxPages)
    }

    public static let none = RESTPaginationDescriptor(mode: .none, itemsPath: "items", nextCursorPath: nil, nextLinkPath: nil)
    public static let cursor = RESTPaginationDescriptor(mode: .cursor)
    public static let nextLink = RESTPaginationDescriptor(mode: .nextLink, nextCursorPath: nil)
    public static let page = RESTPaginationDescriptor(mode: .page)
}

public struct RESTFieldMap: Codable, Hashable, Sendable {
    public let id: RESTJSONPath
    public let title: RESTJSONPath
    public let notes: RESTJSONPath?
    public let listID: RESTJSONPath?
    public let completed: RESTJSONPath?
    public let dueDate: RESTJSONPath?
    public let completedAt: RESTJSONPath?
    public let priority: RESTJSONPath?
    public let color: RESTJSONPath?
    public let position: RESTJSONPath?
    public let deleted: RESTJSONPath?
    public let updatedAt: RESTJSONPath?
    public let revision: RESTJSONPath?

    public init(
        id: RESTJSONPath = "id",
        title: RESTJSONPath = "title",
        notes: RESTJSONPath? = "notes",
        listID: RESTJSONPath? = "listId",
        completed: RESTJSONPath? = "completed",
        dueDate: RESTJSONPath? = "dueDate",
        completedAt: RESTJSONPath? = "completedAt",
        priority: RESTJSONPath? = "priority",
        color: RESTJSONPath? = "color",
        position: RESTJSONPath? = "position",
        deleted: RESTJSONPath? = "deleted",
        updatedAt: RESTJSONPath? = "updatedAt",
        revision: RESTJSONPath? = "revision"
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.listID = listID
        self.completed = completed
        self.dueDate = dueDate
        self.completedAt = completedAt
        self.priority = priority
        self.color = color
        self.position = position
        self.deleted = deleted
        self.updatedAt = updatedAt
        self.revision = revision
    }

    public static let standard = RESTFieldMap()
}

public struct RESTCollectionDescriptor: Codable, Hashable, Sendable {
    public let path: String
    public let fields: RESTFieldMap
    public let pagination: RESTPaginationDescriptor

    public init(path: String, fields: RESTFieldMap = .standard, pagination: RESTPaginationDescriptor = .none) {
        self.path = path
        self.fields = fields
        self.pagination = pagination
    }
}

public struct RESTChangesDescriptor: Codable, Hashable, Sendable {
    public let path: String
    public let listItemsPath: RESTJSONPath
    public let taskItemsPath: RESTJSONPath
    public let pagination: RESTPaginationDescriptor
    public let serverNowPath: RESTJSONPath?
    public let fullSnapshot: Bool

    public init(
        path: String,
        listItemsPath: RESTJSONPath = "lists",
        taskItemsPath: RESTJSONPath = "tasks",
        pagination: RESTPaginationDescriptor = .cursor,
        serverNowPath: RESTJSONPath? = "serverNow",
        fullSnapshot: Bool = false
    ) {
        self.path = path
        self.listItemsPath = listItemsPath
        self.taskItemsPath = taskItemsPath
        self.pagination = pagination
        self.serverNowPath = serverNowPath
        self.fullSnapshot = fullSnapshot
    }
}

public struct RESTMutationEndpoint: Codable, Hashable, Sendable {
    public let createPath: String?
    public let updatePath: String?
    public let deletePath: String?
    public let createMethod: String
    public let updateMethod: String
    public let deleteMethod: String

    public init(
        createPath: String? = nil,
        updatePath: String? = nil,
        deletePath: String? = nil,
        createMethod: String = "POST",
        updateMethod: String = "PATCH",
        deleteMethod: String = "DELETE"
    ) {
        self.createPath = createPath
        self.updatePath = updatePath
        self.deletePath = deletePath
        self.createMethod = createMethod
        self.updateMethod = updateMethod
        self.deleteMethod = deleteMethod
    }

    public static let none = RESTMutationEndpoint()
}

public struct GenericRESTConfiguration: Codable, Hashable, Sendable {
    public let baseURL: URL
    public let lists: RESTCollectionDescriptor
    public let tasks: RESTCollectionDescriptor
    public let changes: RESTChangesDescriptor?
    public let listMutations: RESTMutationEndpoint
    public let taskMutations: RESTMutationEndpoint
    public let fieldCapabilities: AdapterFieldCapabilities

    public init(
        baseURL: URL,
        lists: RESTCollectionDescriptor,
        tasks: RESTCollectionDescriptor,
        changes: RESTChangesDescriptor? = nil,
        listMutations: RESTMutationEndpoint = .none,
        taskMutations: RESTMutationEndpoint = .none,
        fieldCapabilities: AdapterFieldCapabilities = .allNative
    ) {
        self.baseURL = baseURL
        self.lists = lists
        self.tasks = tasks
        self.changes = changes
        self.listMutations = listMutations
        self.taskMutations = taskMutations
        self.fieldCapabilities = fieldCapabilities
    }
}

public extension AdapterFieldCapabilities {
    static let allNative = AdapterFieldCapabilities(fields: Dictionary(uniqueKeysWithValues: AdapterField.allCases.map { ($0, .native) }))
}
