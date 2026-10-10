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

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.rawValue = try container.decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
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

    private enum CodingKeys: String, CodingKey {
        case mode, itemsPath, nextCursorPath, nextLinkPath, cursorQueryName, pageQueryName, pageSizeQueryName, pageSize, maxPages
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            mode: try container.decodeIfPresent(RESTPaginationMode.self, forKey: .mode) ?? .none,
            itemsPath: try container.decodeIfPresent(RESTJSONPath.self, forKey: .itemsPath) ?? "items",
            nextCursorPath: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .nextCursorPath) ?? "nextCursor",
            nextLinkPath: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .nextLinkPath) ?? "nextLink",
            cursorQueryName: try container.decodeIfPresent(String.self, forKey: .cursorQueryName) ?? "cursor",
            pageQueryName: try container.decodeIfPresent(String.self, forKey: .pageQueryName) ?? "page",
            pageSizeQueryName: try container.decodeIfPresent(String?.self, forKey: .pageSizeQueryName) ?? "limit",
            pageSize: try container.decodeIfPresent(Int.self, forKey: .pageSize) ?? 100,
            maxPages: try container.decodeIfPresent(Int.self, forKey: .maxPages) ?? 10_000
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        try container.encode(itemsPath, forKey: .itemsPath)
        try container.encodeIfPresent(nextCursorPath, forKey: .nextCursorPath)
        try container.encodeIfPresent(nextLinkPath, forKey: .nextLinkPath)
        try container.encode(cursorQueryName, forKey: .cursorQueryName)
        try container.encode(pageQueryName, forKey: .pageQueryName)
        try container.encodeIfPresent(pageSizeQueryName, forKey: .pageSizeQueryName)
        try container.encode(pageSize, forKey: .pageSize)
        try container.encode(maxPages, forKey: .maxPages)
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

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, listID, completed, dueDate, completedAt, priority, color, position, deleted, updatedAt, revision
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(RESTJSONPath.self, forKey: .id) ?? "id",
            title: try container.decodeIfPresent(RESTJSONPath.self, forKey: .title) ?? "title",
            notes: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .notes) ?? "notes",
            listID: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .listID) ?? "listId",
            completed: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .completed) ?? "completed",
            dueDate: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .dueDate) ?? "dueDate",
            completedAt: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .completedAt) ?? "completedAt",
            priority: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .priority) ?? "priority",
            color: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .color) ?? "color",
            position: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .position) ?? "position",
            deleted: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .deleted) ?? "deleted",
            updatedAt: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .updatedAt) ?? "updatedAt",
            revision: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .revision) ?? "revision"
        )
    }
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

    private enum CodingKeys: String, CodingKey { case path, fields, pagination }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            fields: try container.decodeIfPresent(RESTFieldMap.self, forKey: .fields) ?? .standard,
            pagination: try container.decodeIfPresent(RESTPaginationDescriptor.self, forKey: .pagination) ?? .none
        )
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

    private enum CodingKeys: String, CodingKey { case path, listItemsPath, taskItemsPath, pagination, serverNowPath, fullSnapshot }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            path: try container.decode(String.self, forKey: .path),
            listItemsPath: try container.decodeIfPresent(RESTJSONPath.self, forKey: .listItemsPath) ?? "lists",
            taskItemsPath: try container.decodeIfPresent(RESTJSONPath.self, forKey: .taskItemsPath) ?? "tasks",
            pagination: try container.decodeIfPresent(RESTPaginationDescriptor.self, forKey: .pagination) ?? .cursor,
            serverNowPath: try container.decodeIfPresent(RESTJSONPath?.self, forKey: .serverNowPath) ?? "serverNow",
            fullSnapshot: try container.decodeIfPresent(Bool.self, forKey: .fullSnapshot) ?? false
        )
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

    private enum CodingKeys: String, CodingKey { case createPath, updatePath, deletePath, createMethod, updateMethod, deleteMethod }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            createPath: try container.decodeIfPresent(String.self, forKey: .createPath),
            updatePath: try container.decodeIfPresent(String.self, forKey: .updatePath),
            deletePath: try container.decodeIfPresent(String.self, forKey: .deletePath),
            createMethod: try container.decodeIfPresent(String.self, forKey: .createMethod) ?? "POST",
            updateMethod: try container.decodeIfPresent(String.self, forKey: .updateMethod) ?? "PATCH",
            deleteMethod: try container.decodeIfPresent(String.self, forKey: .deleteMethod) ?? "DELETE"
        )
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

    private enum CodingKeys: String, CodingKey { case baseURL, lists, tasks, changes, listMutations, taskMutations, fieldCapabilities }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            baseURL: try container.decode(URL.self, forKey: .baseURL),
            lists: try container.decode(RESTCollectionDescriptor.self, forKey: .lists),
            tasks: try container.decode(RESTCollectionDescriptor.self, forKey: .tasks),
            changes: try container.decodeIfPresent(RESTChangesDescriptor.self, forKey: .changes),
            listMutations: try container.decodeIfPresent(RESTMutationEndpoint.self, forKey: .listMutations) ?? .none,
            taskMutations: try container.decodeIfPresent(RESTMutationEndpoint.self, forKey: .taskMutations) ?? .none,
            fieldCapabilities: try container.decodeIfPresent(AdapterFieldCapabilities.self, forKey: .fieldCapabilities) ?? .allNative
        )
    }
}

public extension AdapterFieldCapabilities {
    static let allNative = AdapterFieldCapabilities(fields: Dictionary(uniqueKeysWithValues: AdapterField.allCases.map { ($0, .native) }))
}

public enum GenericRESTConfigurationError: Error, LocalizedError, Equatable, Sendable {
    case invalidJSON(String)
    case insecureBaseURL
    case missingEndpointPath(String)
    case unsafeEndpointPath(String)
    case unsupportedHTTPMethod(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let message): return "Invalid generic REST configuration: \(message)"
        case .insecureBaseURL: return "Generic REST integrations must use an HTTPS base URL."
        case .missingEndpointPath(let endpoint): return "Generic REST endpoint path is missing: \(endpoint)."
        case .unsafeEndpointPath(let path): return "Generic REST endpoint path must be relative and same-origin: \(path)."
        case .unsupportedHTTPMethod(let method): return "Unsupported generic REST mutation method: \(method)."
        }
    }
}

public extension GenericRESTConfiguration {
    /// Decodes a complete declarative provider configuration and validates the safety
    /// invariants required by the app runtime. Tokens are intentionally not part of this
    /// payload; they are loaded from Keychain by the app connection factory.
    init(jsonData: Data, requireHTTPS: Bool = true) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: jsonData)
        } catch {
            throw GenericRESTConfigurationError.invalidJSON(error.localizedDescription)
        }
        try validate(requireHTTPS: requireHTTPS)
    }

    func validate(requireHTTPS: Bool = true) throws {
        guard let baseComponents = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              baseComponents.host != nil else {
            throw GenericRESTConfigurationError.invalidJSON("baseURL must include a host.")
        }
        guard baseComponents.user == nil, baseComponents.password == nil else {
            throw GenericRESTConfigurationError.invalidJSON("baseURL must not contain credentials.")
        }
        if requireHTTPS && baseURL.scheme?.lowercased() != "https" {
            throw GenericRESTConfigurationError.insecureBaseURL
        }
        try validateCollection(lists, label: "lists")
        try validateCollection(tasks, label: "tasks")
        try validateMutation(listMutations, label: "listMutations")
        try validateMutation(taskMutations, label: "taskMutations")
        if let changes { try validatePath(changes.path, label: "changes") }
    }

    private func validateCollection(_ collection: RESTCollectionDescriptor, label: String) throws {
        try validatePath(collection.path, label: label)
    }

    private func validatePath(_ path: String, label: String) throws {
        guard !path.isEmpty else { throw GenericRESTConfigurationError.missingEndpointPath(label) }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        let containsControlCharacter = path.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        guard URL(string: path)?.scheme == nil,
              !path.hasPrefix("//"),
              !path.contains("//"),
              !path.contains("\\"),
              !path.contains("?"),
              !path.contains("#"),
              !segments.contains(where: { $0 == "." || $0 == ".." }),
              !containsControlCharacter else {
            throw GenericRESTConfigurationError.unsafeEndpointPath(path)
        }
    }

    private func validateMutation(_ endpoint: RESTMutationEndpoint, label: String) throws {
        let methods = [endpoint.createMethod, endpoint.updateMethod, endpoint.deleteMethod]
        for method in methods where !["POST", "PUT", "PATCH", "DELETE"].contains(method.uppercased()) {
            throw GenericRESTConfigurationError.unsupportedHTTPMethod(method)
        }
        if let createPath = endpoint.createPath { try validatePath(createPath, label: "\(label).createPath") }
        if let updatePath = endpoint.updatePath { try validatePath(updatePath, label: "\(label).updatePath") }
        if let deletePath = endpoint.deletePath { try validatePath(deletePath, label: "\(label).deletePath") }
        if endpoint.createPath == nil && endpoint.updatePath == nil && endpoint.deletePath == nil { return }
    }
}
