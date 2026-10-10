import Foundation
import SyncDomain
import SyncContracts

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A declarative adapter for JSON REST APIs. Provider-specific code is limited to a
/// configuration of paths; transport, paging, conditional requests, and canonical
/// translation are shared by every integration.
public struct GenericRESTAdapter: ExternalSyncAdapter, FieldDiagnosticsProviding {
    public let account: SyncAccount
    public let capabilities: Set<AdapterCapability>
    public let fieldCapabilities: AdapterFieldCapabilities

    private let configuration: GenericRESTConfiguration
    private let transport: any HTTPTransport
    private let accessToken: @Sendable () async throws -> String
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        account: SyncAccount,
        configuration: GenericRESTConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.account = account
        self.configuration = configuration
        self.transport = transport
        self.accessToken = accessToken
        self.fieldCapabilities = configuration.fieldCapabilities
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
        var values: Set<AdapterCapability> = [.lists, .fieldDiagnostics]
        if configuration.fieldCapabilities.support(for: .taskNotes) != .unsupported { values.insert(.taskNotes) }
        if configuration.fieldCapabilities.support(for: .taskDueDate) != .unsupported { values.insert(.dueDates) }
        if configuration.fieldCapabilities.support(for: .taskPriority) != .unsupported { values.insert(.priorities) }
        if let changes = configuration.changes, changes.pagination.mode != .none { values.insert(.incrementalPull) }
        if configuration.listMutations.updatePath != nil || configuration.taskMutations.updatePath != nil { values.insert(.conditionalWrites) }
        if configuration.listMutations.deletePath != nil || configuration.taskMutations.deletePath != nil { values.insert(.remoteDeletion) }
        if configuration.lists.fields.revision != nil || configuration.tasks.fields.revision != nil { values.insert(.providerRevision) }
        self.capabilities = values
    }

    public func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        let token = try await accessToken()
        if let descriptor = configuration.changes {
            let page = try await fetchChanges(descriptor, since: cursor, token: token)
            return RemoteChanges(
                changes: page.lists.map(RemoteChange.list) + page.tasks.map(RemoteChange.task),
                nextCursor: page.nextCursor,
                serverNow: page.serverNow,
                isFullSnapshot: descriptor.fullSnapshot,
                diagnostics: page.diagnostics
            )
        }

        let lists = try await fetchCollection(configuration.lists, resourceType: .list, cursor: cursor, token: token)
        let tasks = try await fetchCollection(configuration.tasks, resourceType: .task, cursor: cursor, token: token)
        return RemoteChanges(
            changes: lists.values.compactMap { if case .list(let value) = $0 { RemoteChange.list(value) } else { nil } }
                + tasks.values.compactMap { if case .task(let value) = $0 { RemoteChange.task(value) } else { nil } },
            nextCursor: lists.nextCursor ?? tasks.nextCursor,
            serverNow: max(lists.serverNow, tasks.serverNow),
            isFullSnapshot: cursor == nil,
            diagnostics: lists.diagnostics + tasks.diagnostics
        )
    }

    public func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        guard !mutations.isEmpty else { return PushResult(accepted: 0, nextCursor: cursor, serverNow: Date()) }
        let token = try await accessToken()
        var accepted = 0
        var rejected: [RejectedMutation] = []
        var mappings: [RemoteIDMapping] = []
        var diagnostics: [FieldLossDiagnostic] = []

        for mutation in mutations {
            do {
                let result = try await pushOne(mutation, token: token)
                accepted += 1
                mappings.append(result.mapping)
                diagnostics.append(contentsOf: result.diagnostics)
            } catch {
                rejected.append(RejectedMutation(mutation: mutation, reason: error.localizedDescription, retryable: Self.isRetryable(error)))
            }
        }
        return PushResult(accepted: accepted, rejected: rejected, mappings: mappings, nextCursor: cursor, serverNow: Date(), diagnostics: diagnostics)
    }

    private struct CollectionPage {
        var root: RESTJSONValue
        var values: [RESTJSONValue]
        var nextCursor: String?
        var serverNow: Date
    }

    private struct CollectionResult<T> {
        var values: [T]
        var nextCursor: String?
        var serverNow: Date
        var diagnostics: [FieldLossDiagnostic]
    }

    private struct ChangePage {
        var lists: [RemoteList]
        var tasks: [RemoteTask]
        var nextCursor: String?
        var serverNow: Date
        var diagnostics: [FieldLossDiagnostic]
    }

    private func fetchCollection(
        _ descriptor: RESTCollectionDescriptor,
        resourceType: EntityType,
        cursor: String?,
        token: String
    ) async throws -> CollectionResult<RemoteEntity> {
        var pageCursor = cursor
        var pageNumber = 1
        var values: [RemoteEntity] = []
        var diagnostics: [FieldLossDiagnostic] = []
        var serverNow = Date()
        var seenLinks = Set<String>()
        var lastCursor: String?

        while true {
            guard pageNumber <= descriptor.pagination.maxPages else {
                throw SyncAdapterError.invalidResponse("Pagination exceeded maxPages (\(descriptor.pagination.maxPages)).")
            }
            let page = try await fetchPage(
                path: descriptor.path,
                pagination: descriptor.pagination,
                cursor: pageCursor,
                pageNumber: pageNumber,
                token: token,
                seenLinks: &seenLinks
            )
            serverNow = max(serverNow, page.serverNow)
            for value in page.values {
                switch resourceType {
                case .list:
                    let (entity, warnings) = try decodeList(value, fields: descriptor.fields)
                    values.append(.list(entity))
                    diagnostics.append(contentsOf: warnings)
                case .task:
                    let (entity, warnings) = try decodeTask(value, fields: descriptor.fields)
                    values.append(.task(entity))
                    diagnostics.append(contentsOf: warnings)
                }
            }
            lastCursor = page.nextCursor
            guard let next = page.nextCursor else { break }
            guard descriptor.pagination.mode != .none else { break }
            pageCursor = next
            pageNumber += 1
        }
        return CollectionResult(values: values, nextCursor: lastCursor, serverNow: serverNow, diagnostics: diagnostics)
    }

    private func fetchChanges(_ descriptor: RESTChangesDescriptor, since cursor: String?, token: String) async throws -> ChangePage {
        var pageCursor = cursor
        var pageNumber = 1
        var lists: [RemoteList] = []
        var tasks: [RemoteTask] = []
        var diagnostics: [FieldLossDiagnostic] = []
        var serverNow = Date()
        var nextCursor: String?
        var seenLinks = Set<String>()

        while true {
            guard pageNumber <= descriptor.pagination.maxPages else {
                throw SyncAdapterError.invalidResponse("Pagination exceeded maxPages (\(descriptor.pagination.maxPages)).")
            }
            let page = try await fetchPage(
                path: descriptor.path,
                pagination: descriptor.pagination,
                cursor: pageCursor,
                pageNumber: pageNumber,
                token: token,
                seenLinks: &seenLinks
            )
            serverNow = max(serverNow, page.serverNow)
            let listValues = page.root.value(at: descriptor.listItemsPath).flatMap { value -> [RESTJSONValue]? in
                guard case let .array(items) = value else { return nil }
                return items
            }
            let taskValues = page.root.value(at: descriptor.taskItemsPath).flatMap { value -> [RESTJSONValue]? in
                guard case let .array(items) = value else { return nil }
                return items
            }
            if let listValues, let taskValues {
                for value in listValues {
                    let (entity, warnings) = try decodeList(value, fields: .standard)
                    lists.append(entity); diagnostics.append(contentsOf: warnings)
                }
                for value in taskValues {
                    let (entity, warnings) = try decodeTask(value, fields: .standard)
                    tasks.append(entity); diagnostics.append(contentsOf: warnings)
                }
            } else {
                // A changes endpoint may return a mixed `items` collection. The optional
                // resource discriminator keeps this usable without provider-specific code.
                for value in page.values {
                    let kind = value.value(at: RESTJSONPath("resourceType"))?.string()
                        ?? value.value(at: RESTJSONPath("type"))?.string()
                    if kind == "list" {
                        let (entity, warnings) = try decodeList(value, fields: .standard)
                        lists.append(entity); diagnostics.append(contentsOf: warnings)
                    } else if kind == "task" {
                        let (entity, warnings) = try decodeTask(value, fields: .standard)
                        tasks.append(entity); diagnostics.append(contentsOf: warnings)
                    } else {
                        throw SyncAdapterError.invalidResponse("A changes item is missing resourceType/type.")
                    }
                }
            }
            nextCursor = page.nextCursor
            guard let next = page.nextCursor else { break }
            pageCursor = next
            pageNumber += 1
        }
        return ChangePage(lists: lists, tasks: tasks, nextCursor: nextCursor, serverNow: serverNow, diagnostics: diagnostics)
    }

    private func fetchPage(
        path: String,
        pagination: RESTPaginationDescriptor,
        cursor: String?,
        pageNumber: Int,
        token: String,
        seenLinks: inout Set<String>
    ) async throws -> CollectionPage {
        var query: [URLQueryItem] = []
        var requestPath = path
        switch pagination.mode {
        case .none:
            break
        case .cursor:
            if let cursor { query.append(URLQueryItem(name: pagination.cursorQueryName, value: cursor)) }
        case .page:
            query.append(URLQueryItem(name: pagination.pageQueryName, value: String(pageNumber)))
            if let pageSizeQueryName = pagination.pageSizeQueryName {
                query.append(URLQueryItem(name: pageSizeQueryName, value: String(pagination.pageSize)))
            }
        case .nextLink:
            if let cursor { requestPath = cursor }
        }
        if pagination.mode != .page, let pageSizeQueryName = pagination.pageSizeQueryName {
            query.append(URLQueryItem(name: pageSizeQueryName, value: String(pagination.pageSize)))
        }

        let response = try await request(path: requestPath, method: "GET", token: token, query: query)
        let root = try decodeJSON(from: response)
        let rawItems = root.value(at: pagination.itemsPath) ?? {
            if case .array = root { return root }
            return nil
        }()
        let values: [RESTJSONValue]
        if case let .array(array) = rawItems ?? .array([]) { values = array } else {
            throw SyncAdapterError.invalidResponse("The collection response did not contain an array at \(pagination.itemsPath).")
        }
        let nextCursor: String?
        switch pagination.mode {
        case .none: nextCursor = nil
        case .cursor, .page: nextCursor = pagination.nextCursorPath.flatMap { root.value(at: $0)?.string() }
        case .nextLink: nextCursor = pagination.nextLinkPath.flatMap { root.value(at: $0)?.string() }
        }
        if let nextCursor, pagination.mode == .nextLink {
            guard seenLinks.insert(nextCursor).inserted else { throw SyncAdapterError.invalidResponse("Pagination next link repeated.") }
        }
        let serverNow = pagination.nextCursorPath.flatMap { root.value(at: $0)?.date() }
            ?? root.value(at: RESTJSONPath("serverNow"))?.date()
            ?? Date()
        return CollectionPage(root: root, values: values, nextCursor: nextCursor, serverNow: serverNow)
    }

    private enum RemoteEntity { case list(RemoteList); case task(RemoteTask) }

    private func decodeList(_ raw: RESTJSONValue, fields: RESTFieldMap) throws -> (RemoteList, [FieldLossDiagnostic]) {
        guard let id = raw.value(at: fields.id)?.string(), !id.isEmpty else { throw SyncAdapterError.invalidResponse("A list item is missing its identifier.") }
        let list = RemoteList(
            remoteID: id,
            name: raw.value(at: fields.title)?.string() ?? "",
            colorHex: fields.color.flatMap { raw.value(at: $0)?.string() },
            position: fields.position.flatMap { raw.value(at: $0)?.string() },
            isDeleted: fields.deleted.flatMap { raw.value(at: $0)?.bool() } ?? false,
            updatedAt: fields.updatedAt.flatMap { raw.value(at: $0)?.date() },
            revision: fields.revision.flatMap { raw.value(at: $0)?.string() }
        )
        return (list, diagnostics(for: .list, id: id, values: raw, fields: fields))
    }

    private func decodeTask(_ raw: RESTJSONValue, fields: RESTFieldMap) throws -> (RemoteTask, [FieldLossDiagnostic]) {
        guard let id = raw.value(at: fields.id)?.string(), !id.isEmpty else { throw SyncAdapterError.invalidResponse("A task item is missing its identifier.") }
        let priority = fields.priority.flatMap { raw.value(at: $0) }.flatMap(Self.priority)
        let task = RemoteTask(
            remoteID: id,
            title: raw.value(at: fields.title)?.string() ?? "",
            notes: fields.notes.flatMap { raw.value(at: $0)?.string() },
            remoteListID: fields.listID.flatMap { raw.value(at: $0)?.string() },
            isCompleted: fields.completed.flatMap { raw.value(at: $0)?.bool() } ?? false,
            dueDate: fields.dueDate.flatMap { raw.value(at: $0)?.date() },
            completedAt: fields.completedAt.flatMap { raw.value(at: $0)?.date() },
            priority: priority ?? .none,
            isDeleted: fields.deleted.flatMap { raw.value(at: $0)?.bool() } ?? false,
            updatedAt: fields.updatedAt.flatMap { raw.value(at: $0)?.date() },
            revision: fields.revision.flatMap { raw.value(at: $0)?.string() }
        )
        return (task, diagnostics(for: .task, id: id, values: raw, fields: fields))
    }

    private func diagnostics(for type: EntityType, id: String, values: RESTJSONValue, fields: RESTFieldMap) -> [FieldLossDiagnostic] {
        let candidates: [(AdapterField, RESTJSONPath?, Bool)] = type == .list
            ? [(.listTitle, fields.title, true), (.listColor, fields.color, false), (.listPosition, fields.position, false)]
            : [(.taskTitle, fields.title, true), (.taskNotes, fields.notes, false), (.taskList, fields.listID, false), (.taskCompletion, fields.completed, false), (.taskDueDate, fields.dueDate, false), (.taskCompletedAt, fields.completedAt, false), (.taskPriority, fields.priority, false), (.taskPosition, fields.position, false)]
        return candidates.compactMap { field, path, required in
            guard let path, values.value(at: path) != nil else { return nil }
            let support = fieldCapabilities.support(for: field)
            guard support != .native else { return nil }
            return FieldLossDiagnostic(
                code: support == .transformed ? .fieldTransformed : .fieldLoss,
                field: field,
                resourceType: type.rawValue,
                resourceID: id,
                message: required ? "The provider transformed the required \(field.rawValue) field." : "The provider cannot preserve \(field.rawValue) exactly.",
                targetProvider: account.provider.rawValue
            )
        }
    }

    private struct PushOneResult { let mapping: RemoteIDMapping; let diagnostics: [FieldLossDiagnostic] }

    private func pushOne(_ mutation: RemoteMutation, token: String) async throws -> PushOneResult {
        switch mutation {
        case let .upsertList(canonicalID, list):
            let endpoint = configuration.listMutations
            let path = list.remoteID.isEmpty ? endpoint.createPath : endpoint.updatePath.map { substitute($0, id: list.remoteID) }
            guard let path else { throw SyncAdapterError.unsupported("Generic REST list writes are not configured.") }
            let body = try encodeObject(list: list, fields: configuration.lists.fields)
            let response = try await request(path: path, method: list.remoteID.isEmpty ? endpoint.createMethod : endpoint.updateMethod, token: token, body: body, revision: list.revision)
            let remoteID = decodeIdentifier(response.body) ?? list.remoteID
            let revision = decodeRevision(response.body) ?? response.headers["etag"] ?? list.revision
            let writtenValue = (try? decoder.decode(RESTJSONValue.self, from: body)) ?? .object([:])
            return PushOneResult(mapping: RemoteIDMapping(canonicalListID: canonicalID, remoteID: remoteID, revision: revision), diagnostics: diagnostics(for: .list, id: remoteID, values: writtenValue, fields: configuration.lists.fields))
        case let .deleteList(canonicalID, remoteID, revision):
            guard let path = configuration.listMutations.deletePath else { throw SyncAdapterError.unsupported("Generic REST list deletion is not configured.") }
            let response = try await request(path: substitute(path, id: remoteID), method: configuration.listMutations.deleteMethod, token: token, revision: revision)
            return PushOneResult(mapping: RemoteIDMapping(canonicalListID: canonicalID, remoteID: remoteID, revision: response.headers["etag"] ?? revision), diagnostics: [])
        case let .upsertTask(canonicalID, task):
            let endpoint = configuration.taskMutations
            let path = task.remoteID.isEmpty ? endpoint.createPath : endpoint.updatePath.map { substitute($0, id: task.remoteID) }
            guard let path else { throw SyncAdapterError.unsupported("Generic REST task writes are not configured.") }
            let body = try encodeObject(task: task, fields: configuration.tasks.fields)
            let response = try await request(path: path, method: task.remoteID.isEmpty ? endpoint.createMethod : endpoint.updateMethod, token: token, body: body, revision: task.revision)
            let remoteID = decodeIdentifier(response.body) ?? task.remoteID
            let revision = decodeRevision(response.body) ?? response.headers["etag"] ?? task.revision
            let writtenValue = (try? decoder.decode(RESTJSONValue.self, from: body)) ?? .object([:])
            return PushOneResult(mapping: RemoteIDMapping(canonicalTaskID: canonicalID, remoteID: remoteID, revision: revision), diagnostics: diagnostics(for: .task, id: remoteID, values: writtenValue, fields: configuration.tasks.fields))
        case let .deleteTask(canonicalID, remoteID, _, revision):
            guard let path = configuration.taskMutations.deletePath else { throw SyncAdapterError.unsupported("Generic REST task deletion is not configured.") }
            let response = try await request(path: substitute(path, id: remoteID), method: configuration.taskMutations.deleteMethod, token: token, revision: revision)
            return PushOneResult(mapping: RemoteIDMapping(canonicalTaskID: canonicalID, remoteID: remoteID, revision: response.headers["etag"] ?? revision), diagnostics: [])
        }
    }

    private func encodeObject(list: RemoteList, fields: RESTFieldMap) throws -> Data {
        var root = RESTJSONValue.object([:])
        root.set(.string(list.name), at: fields.title)
        if let path = fields.color { root.set(list.colorHex.map(RESTJSONValue.string) ?? .null, at: path) }
        if let path = fields.position { root.set(list.position.map(RESTJSONValue.string) ?? .null, at: path) }
        return try encoder.encode(root)
    }

    private func encodeObject(task: RemoteTask, fields: RESTFieldMap) throws -> Data {
        var root = RESTJSONValue.object([:])
        root.set(.string(task.title), at: fields.title)
        if let path = fields.notes { root.set(task.notes.map(RESTJSONValue.string) ?? .null, at: path) }
        if let path = fields.listID { root.set(task.remoteListID.map(RESTJSONValue.string) ?? .null, at: path) }
        if let path = fields.completed { root.set(.bool(task.isCompleted), at: path) }
        if let path = fields.dueDate { root.set(ProviderDateCodec.encode(task.dueDate).map(RESTJSONValue.string) ?? .null, at: path) }
        if let path = fields.completedAt { root.set(ProviderDateCodec.encode(task.completedAt).map(RESTJSONValue.string) ?? .null, at: path) }
        if let path = fields.priority { root.set(.string(Self.priorityString(task.priority)), at: path) }
        return try encoder.encode(root)
    }

    private func request(path: String, method: String, token: String, query: [URLQueryItem] = [], body: Data? = nil, revision: String? = nil) async throws -> HTTPResponse {
        var headers: [String: String] = [:]
        if let revision { headers["If-Match"] = revision }
        let request = try HTTPRequestBuilder.make(baseURL: configuration.baseURL, path: path, method: method, bearerToken: token, query: query, body: body, headers: headers)
        let response = try await transport.execute(request)
        if response.statusCode == 412 { throw SyncAdapterError.conditionalWriteFailed(remoteRevision: response.headers["etag"] ?? revision) }
        try HTTPRequestBuilder.checkSuccess(response)
        return response
    }

    private func decodeJSON(from response: HTTPResponse) throws -> RESTJSONValue {
        guard !response.body.isEmpty else { return .object([:]) }
        return try decoder.decode(RESTJSONValue.self, from: response.body)
    }

    private func decodeIdentifier(_ body: Data) -> String? {
        guard let value = try? decoder.decode(RESTJSONValue.self, from: body) else { return nil }
        return value.value(at: RESTJSONPath("id"))?.string()
    }

    private func decodeRevision(_ body: Data) -> String? {
        guard let value = try? decoder.decode(RESTJSONValue.self, from: body) else { return nil }
        return value.value(at: RESTJSONPath("revision"))?.string() ?? value.value(at: RESTJSONPath("etag"))?.string()
    }

    private func substitute(_ path: String, id: String) -> String {
        path.replacingOccurrences(of: "{id}", with: id).replacingOccurrences(of: ":id", with: id)
    }

    private static func priority(_ value: RESTJSONValue) -> TaskPriority? {
        if let number = value.integer() { return TaskPriority(rawValue: min(max(number, 0), 4)) }
        switch value.string()?.lowercased() {
        case "none", "normal", "default": return TaskPriority.none
        case "low": return .low
        case "medium", "normal-priority": return .medium
        case "high": return .high
        case "urgent": return .urgent
        default: return nil
        }
    }

    private static func priorityString(_ priority: TaskPriority) -> String {
        switch priority { case .none: return "none"; case .low: return "low"; case .medium: return "medium"; case .high: return "high"; case .urgent: return "urgent" }
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case SyncAdapterError.rateLimited = error { return true }
        if case SyncAdapterError.transport = error { return true }
        return false
    }
}
