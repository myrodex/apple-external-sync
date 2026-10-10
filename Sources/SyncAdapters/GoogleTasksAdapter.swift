import Foundation
import SyncDomain
import SyncContracts

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google Tasks adapter. Google exposes `updatedMin` and tombstones rather than a
/// durable delta token, so the opaque engine cursor stores the last scan watermark.
public struct GoogleTasksAdapter: ExternalSyncAdapter, FieldDiagnosticsProviding {
    public let account: SyncAccount
    public let capabilities: Set<AdapterCapability> = [
        .lists, .taskNotes, .dueDates, .incrementalPull, .conditionalWrites,
        .remoteDeletion, .providerRevision, .fieldDiagnostics
    ]
    public let fieldCapabilities: AdapterFieldCapabilities = AdapterFieldCapabilities(
        fields: [
            .listTitle: .native, .listColor: .unsupported, .listPosition: .unsupported,
            .taskTitle: .native, .taskNotes: .native, .taskList: .native,
            .taskCompletion: .native, .taskDueDate: .native, .taskCompletedAt: .native,
            .taskPriority: .unsupported, .taskPosition: .unsupported
        ]
    )

    private let baseURL: URL
    private let transport: any HTTPTransport
    private let accessToken: @Sendable () async throws -> String
    private let now: @Sendable () -> Date

    public init(
        account: SyncAccount,
        baseURL: URL = URL(string: "https://tasks.googleapis.com")!,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.account = account
        self.baseURL = baseURL
        self.transport = transport
        self.now = now
        self.accessToken = accessToken
    }

    public func pullChanges(since cursor: String?) async throws -> RemoteChanges {
        let token = try await accessToken()
        let watermark = now()
        let updatedMin = cursor.flatMap(ProviderDateCodec.parse)
        var lists: [RemoteList] = []
        var tasks: [RemoteTask] = []
        var diagnostics: [FieldLossDiagnostic] = []
        var listPageToken: String?

        repeat {
            var query = [URLQueryItem(name: "maxResults", value: "100")]
            if let listPageToken { query.append(URLQueryItem(name: "pageToken", value: listPageToken)) }
            if let updatedMin, let value = ProviderDateCodec.encode(updatedMin) {
                query.append(URLQueryItem(name: "updatedMin", value: value))
            }
            let page: GoogleTaskListPage = try await ProviderRequestSupport.executeJSON(
                GoogleTaskListPage.self,
                baseURL: baseURL,
                path: "/tasks/v1/users/@me/lists",
                method: "GET",
                token: token,
                query: query,
                transport: transport
            )
            for item in page.items {
                let list = RemoteList(
                    remoteID: item.id,
                    name: item.title,
                    isDeleted: item.deleted ?? false,
                    updatedAt: ProviderDateCodec.parse(item.updated),
                    revision: item.etag ?? item.updated
                )
                lists.append(list)
                diagnostics.append(contentsOf: ProviderFieldDiagnostics.forGoogle(list: list))
                if !list.isDeleted {
                    let fetched = try await fetchTasks(listID: item.id, updatedMin: updatedMin, token: token)
                    tasks.append(contentsOf: fetched.tasks)
                    diagnostics.append(contentsOf: fetched.diagnostics)
                }
            }
            listPageToken = page.nextPageToken
        } while listPageToken != nil

        return RemoteChanges(
            changes: lists.map(RemoteChange.list) + tasks.map(RemoteChange.task),
            nextCursor: ProviderDateCodec.encode(watermark),
            serverNow: watermark,
            isFullSnapshot: cursor == nil,
            diagnostics: diagnostics
        )
    }

    public func push(_ mutations: [RemoteMutation], cursor: String?) async throws -> PushResult {
        let token = try await accessToken()
        var accepted = 0
        var rejected: [RejectedMutation] = []
        var mappings: [RemoteIDMapping] = []
        var diagnostics: [FieldLossDiagnostic] = []

        for mutation in mutations {
            do {
                switch mutation {
                case .upsertList(let canonicalID, let list):
                    guard !list.isDeleted else {
                        throw SyncAdapterError.unsupported("Google Tasks list deletion is not supported by the provider API.")
                    }
                    let response = try await upsertList(list, token: token)
                    accepted += 1
                    mappings.append(RemoteIDMapping(canonicalListID: canonicalID, remoteID: response.id, revision: response.etag ?? response.updated))
                    diagnostics.append(contentsOf: ProviderFieldDiagnostics.forGoogle(list: list))
                case .deleteList:
                    throw SyncAdapterError.unsupported("Google Tasks list deletion is not supported by the provider API.")
                case .upsertTask(let canonicalID, let task):
                    guard let listID = task.remoteListID, !listID.isEmpty else {
                        throw SyncAdapterError.unsupported("A Google task must be mapped to a remote task list.")
                    }
                    let response = try await upsertTask(task, listID: listID, token: token)
                    accepted += 1
                    mappings.append(RemoteIDMapping(canonicalTaskID: canonicalID, remoteID: response.id, revision: response.etag ?? response.updated))
                    diagnostics.append(contentsOf: ProviderFieldDiagnostics.forGoogle(task: task))
                case .deleteTask(let canonicalID, let remoteID, let remoteListID, let revision):
                    guard let remoteListID, !remoteListID.isEmpty else {
                        throw SyncAdapterError.unsupported("Deleting a Google task requires its mapped list.")
                    }
                    try await deleteTask(remoteID: remoteID, listID: remoteListID, revision: revision, token: token)
                    accepted += 1
                    mappings.append(RemoteIDMapping(canonicalTaskID: canonicalID, remoteID: remoteID, revision: revision))
                }
            } catch {
                rejected.append(RejectedMutation(mutation: mutation, reason: error.localizedDescription, retryable: Self.isRetryable(error)))
            }
        }
        return PushResult(accepted: accepted, rejected: rejected, mappings: mappings, nextCursor: cursor, serverNow: now(), diagnostics: diagnostics)
    }

    private struct FetchedTasks {
        let tasks: [RemoteTask]
        let diagnostics: [FieldLossDiagnostic]
    }

    private func fetchTasks(listID: String, updatedMin: Date?, token: String) async throws -> FetchedTasks {
        var result: [RemoteTask] = []
        var diagnostics: [FieldLossDiagnostic] = []
        var pageToken: String?
        repeat {
            var query = [
                URLQueryItem(name: "showCompleted", value: "true"),
                URLQueryItem(name: "showDeleted", value: "true"),
                URLQueryItem(name: "maxResults", value: "100")
            ]
            if let pageToken { query.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            if let updatedMin, let value = ProviderDateCodec.encode(updatedMin) {
                query.append(URLQueryItem(name: "updatedMin", value: value))
            }
            let page: GoogleTaskPage = try await ProviderRequestSupport.executeJSON(
                GoogleTaskPage.self,
                baseURL: baseURL,
                path: "/tasks/v1/lists/\(listID)/tasks",
                method: "GET",
                token: token,
                query: query,
                transport: transport
            )
            for item in page.items {
                let task = ProviderMutationSupport.remoteTask(
                    id: item.id,
                    title: item.title ?? "",
                    notes: item.notes,
                    listID: listID,
                    completed: item.status == "completed",
                    dueDate: ProviderDateCodec.parse(item.due),
                    completedAt: ProviderDateCodec.parse(item.completed),
                    priority: .none,
                    deleted: item.deleted ?? false,
                    updatedAt: ProviderDateCodec.parse(item.updated),
                    revision: item.etag ?? item.updated
                )
                result.append(task)
                diagnostics.append(contentsOf: ProviderFieldDiagnostics.forGoogle(task: task))
            }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return FetchedTasks(tasks: result, diagnostics: diagnostics)
    }

    private func upsertList(_ list: RemoteList, token: String) async throws -> GoogleTaskList {
        let body = try JSONEncoder().encode(GoogleTaskListWrite(title: list.name))
        let path = list.remoteID.isEmpty
            ? "/tasks/v1/users/@me/lists"
            : "/tasks/v1/users/@me/lists/\(list.remoteID)"
        let method = list.remoteID.isEmpty ? "POST" : "PATCH"
        return try await executeJSON(GoogleTaskList.self, path: path, method: method, token: token, body: body, revision: list.revision)
    }

    private func upsertTask(_ task: RemoteTask, listID: String, token: String) async throws -> GoogleTask {
        let payload = GoogleTaskWrite(
            title: task.title,
            notes: task.notes,
            due: ProviderDateCodec.encode(task.dueDate),
            status: task.isCompleted ? "completed" : "needsAction"
        )
        let body = try JSONEncoder().encode(payload)
        let path = task.remoteID.isEmpty
            ? "/tasks/v1/lists/\(listID)/tasks"
            : "/tasks/v1/lists/\(listID)/tasks/\(task.remoteID)"
        let method = task.remoteID.isEmpty ? "POST" : "PATCH"
        return try await executeJSON(GoogleTask.self, path: path, method: method, token: token, body: body, revision: task.revision)
    }

    private func deleteTask(remoteID: String, listID: String, revision: String?, token: String) async throws {
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: "/tasks/v1/lists/\(listID)/tasks/\(remoteID)", method: "DELETE", bearerToken: token, headers: revision.map { ["If-Match": $0] } ?? [:])
        try HTTPRequestBuilder.checkSuccess(try await transport.execute(request))
    }

    private func executeJSON<T: Decodable>(_ type: T.Type, path: String, method: String, token: String, body: Data?, revision: String?) async throws -> T {
        let headers = revision.map { ["If-Match": $0] } ?? [:]
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: path, method: method, bearerToken: token, body: body, headers: headers)
        return try HTTPRequestBuilder.decodeOrThrow(type, from: try await transport.execute(request))
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if case SyncAdapterError.rateLimited = error { return true }
        if case SyncAdapterError.transport = error { return true }
        return false
    }
}

private struct GoogleTaskListPage: Codable { let items: [GoogleTaskList]; let nextPageToken: String? }
private struct GoogleTaskPage: Codable { let items: [GoogleTask]; let nextPageToken: String? }
private struct GoogleTaskList: Codable { let id: String; let title: String; let updated: String?; let deleted: Bool?; let etag: String? }
private struct GoogleTaskListWrite: Codable { let title: String }
private struct GoogleTask: Codable { let id: String; let title: String?; let notes: String?; let status: String?; let due: String?; let completed: String?; let updated: String?; let deleted: Bool?; let etag: String? }
private struct GoogleTaskWrite: Codable { let title: String; let notes: String?; let due: String?; let status: String }
