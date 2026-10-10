import Foundation
import XCTest
@testable import SyncAdapters
@testable import SyncContracts
@testable import SyncDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class ExternalProviderAdaptersTests: XCTestCase {
    func testGooglePullPaginatesListsAndTasksAndUsesUpdatedWatermark() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let transport = MockHTTPTransport([
            .json("{\"items\":[{\"id\":\"l1\",\"title\":\"Work\",\"updated\":\"2023-11-14T22:13:20Z\",\"etag\":\"\\\"l1v1\\\"\"}],\"nextPageToken\":\"lists-2\"}"),
            .json("{\"items\":[{\"id\":\"t1\",\"title\":\"Ship\",\"notes\":\"docs\",\"status\":\"needsAction\",\"updated\":\"2023-11-14T22:13:20Z\",\"etag\":\"\\\"t1v1\\\"\"}],\"nextPageToken\":\"tasks-2\"}"),
            .json("{\"items\":[{\"id\":\"t2\",\"title\":\"Gone\",\"status\":\"needsAction\",\"deleted\":true,\"updated\":\"2023-11-14T22:13:21Z\"}]}"),
            .json("{\"items\":[{\"id\":\"l2\",\"title\":\"Home\",\"updated\":\"2023-11-14T22:13:20Z\"}]}"),
            .json("{\"items\":[{\"id\":\"t3\",\"title\":\"Clean\",\"status\":\"completed\",\"completed\":\"2023-11-14T22:13:20Z\"}]}"),
        ])
        let account = SyncAccount(provider: .googleTasks, accountID: "google-account")
        let adapter = GoogleTasksAdapter(account: account, baseURL: URL(string: "https://tasks.test")!, transport: transport, now: { now }, accessToken: { "access" })

        let result = try await adapter.pullChanges(since: "2023-11-14T22:00:00Z")
        XCTAssertFalse(result.isFullSnapshot)
        XCTAssertEqual(result.nextCursor, "2023-11-14T22:13:20Z")
        XCTAssertEqual(result.changes.count, 5)
        XCTAssertTrue(result.changes.contains { if case .task(let task) = $0 { return task.remoteID == "t2" && task.isDeleted }; return false })

        let requests = await transport.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests[0].url?.path, "/tasks/v1/users/@me/lists")
        XCTAssertTrue(requests[0].url?.query?.contains("updatedMin=2023-11-14T22:00:00Z") == true)
        XCTAssertEqual(requests[1].url?.query, "showCompleted=true&showDeleted=true&maxResults=100&updatedMin=2023-11-14T22:00:00Z")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer access")
    }

    func testGoogleRejectsUnsafePaginationLinkWithoutSendingBearerToAnotherOrigin() async throws {
        let transport = MockHTTPTransport([
            .json("{\"items\":[],\"nextLink\":\"https://evil.test/steal\"}")
        ])
        let adapter = GoogleTasksAdapter(
            account: SyncAccount(provider: .googleTasks, accountID: "google-account"),
            baseURL: URL(string: "https://tasks.test")!,
            transport: transport,
            accessToken: { "secret" }
        )

        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("Cross-origin Google pagination link must be rejected")
        } catch let error as SyncAdapterError {
            guard case .unsafeProviderURL = error else { return XCTFail("Expected typed unsafe URL error, got \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].url?.host, "tasks.test")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testGoogleRejectsHTTPPaginationTokenBeforeFollowingIt() async throws {
        let transport = MockHTTPTransport([
            .json("{\"items\":[],\"nextPageToken\":\"http://tasks.test/next\"}")
        ])
        let adapter = GoogleTasksAdapter(
            account: SyncAccount(provider: .googleTasks, accountID: "google-account"),
            baseURL: URL(string: "https://tasks.test")!,
            transport: transport,
            accessToken: { "secret" }
        )

        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("An HTTP-looking Google pagination token must be rejected")
        } catch let error as SyncAdapterError {
            guard case .unsafeProviderURL = error else { return XCTFail("Expected typed unsafe URL error, got \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testGooglePushCarriesConditionalRevisionAndFieldLossDiagnostics() async throws {
        let transport = MockHTTPTransport([.json("{\"id\":\"t1\",\"title\":\"Ship\",\"status\":\"needsAction\",\"updated\":\"2023-11-14T22:13:20Z\",\"etag\":\"\\\"t1v2\\\"\"}")])
        let account = SyncAccount(provider: .googleTasks, accountID: "google-account")
        let adapter = GoogleTasksAdapter(account: account, baseURL: URL(string: "https://tasks.test")!, transport: transport, accessToken: { "access" })
        let task = RemoteTask(remoteID: "t1", title: "Ship", remoteListID: "l1", priority: .urgent, revision: "\"t1v1\"")
        let result = try await adapter.push([.upsertTask(canonicalTaskID: SyncID(), task: task)], cursor: "cursor")
        XCTAssertEqual(result.accepted, 1)
        XCTAssertEqual(result.rejected.count, 0)
        XCTAssertTrue(result.diagnostics.contains { $0.code == .fieldLoss && $0.field == .taskPriority })
        let request = await transport.requests[0]
        XCTAssertEqual(request.value(forHTTPHeaderField: "If-Match"), "\"t1v1\"")
        XCTAssertEqual(request.httpMethod, "PATCH")
    }

    func testMicrosoftPullStoresOpaqueDeltaLinksAndReadsTaskDeltas() async throws {
        let transport = MockHTTPTransport([
            .json("{\"value\":[{\"id\":\"l1\",\"displayName\":\"Work\",\"@odata.etag\":\"W/\\\"l1\\\"\"},{\"id\":\"l2\",\"displayName\":\"Home\"}],\"@odata.deltaLink\":\"https://graph.test/lists-delta-2\"}"),
            .json("{\"value\":[{\"id\":\"t1\",\"title\":\"Ship\",\"status\":\"notStarted\",\"body\":{\"content\":\"<b>x</b>\",\"contentType\":\"html\"}}],\"@odata.deltaLink\":\"https://graph.test/l1-delta-2\"}"),
            .json("{\"value\":[{\"id\":\"t2\",\"title\":\"Clean\",\"status\":\"completed\"}],\"@odata.deltaLink\":\"https://graph.test/l2-delta-2\"}"),
        ])
        let account = SyncAccount(provider: .microsoftGraph, accountID: "ms-account")
        let adapter = MicrosoftGraphAdapter(account: account, baseURL: URL(string: "https://graph.test/v1.0")!, transport: transport, accessToken: { "access" })

        let result = try await adapter.pullChanges(since: nil)
        XCTAssertTrue(result.isFullSnapshot)
        XCTAssertEqual(result.changes.count, 4)
        XCTAssertTrue(result.diagnostics.contains { $0.field == .taskNotes && $0.code == .fieldTransformed })
        XCTAssertNotNil(result.nextCursor)
        let second = MockHTTPTransport([
            .json("{\"value\":[{\"id\":\"l1\",\"displayName\":\"Work 2\"}],\"@odata.deltaLink\":\"https://graph.test/lists-delta-3\"}"),
            .json("{\"value\":[],\"@odata.deltaLink\":\"https://graph.test/l1-delta-3\"}"),
            .json("{\"value\":[],\"@odata.deltaLink\":\"https://graph.test/l2-delta-3\"}"),
        ])
        let adapter2 = MicrosoftGraphAdapter(account: account, baseURL: URL(string: "https://graph.test/v1.0")!, transport: second, accessToken: { "access" })
        _ = try await adapter2.pullChanges(since: result.nextCursor)
        let requests = await second.requests
        XCTAssertEqual(requests[0].url?.absoluteString, "https://graph.test/lists-delta-2")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://graph.test/l1-delta-2")
        XCTAssertEqual(requests[2].url?.absoluteString, "https://graph.test/l2-delta-2")
    }


    func testGoogleAndMicrosoftRejectHTTPBaseURLsBeforeSendingBearerToken() async throws {
        let googleTransport = MockHTTPTransport([])
        let google = GoogleTasksAdapter(account: SyncAccount(provider: .googleTasks, accountID: "g"), baseURL: URL(string: "http://tasks.test")!, transport: googleTransport, accessToken: { "secret" })
        do {
            _ = try await google.pullChanges(since: nil)
            XCTFail("HTTP Google base URL must fail closed")
        } catch let error as SyncAdapterError {
            guard case .unsafeProviderURL = error else { return XCTFail("Expected typed unsafe URL error, got \(error)") }
        }
        let googleRequests = await googleTransport.requests
        XCTAssertTrue(googleRequests.isEmpty)

        let microsoftTransport = MockHTTPTransport([])
        let microsoft = MicrosoftGraphAdapter(account: SyncAccount(provider: .microsoftGraph, accountID: "m"), baseURL: URL(string: "http://graph.test/v1.0")!, transport: microsoftTransport, accessToken: { "secret" })
        do {
            _ = try await microsoft.pullChanges(since: nil)
            XCTFail("HTTP Graph base URL must fail closed")
        } catch let error as SyncAdapterError {
            guard case .unsafeProviderURL = error else { return XCTFail("Expected typed unsafe URL error, got \(error)") }
        }
        let microsoftRequests = await microsoftTransport.requests
        XCTAssertTrue(microsoftRequests.isEmpty)
    }

    func testMicrosoftRejectsCrossOriginDeltaLinkWithoutSendingBearerToken() async throws {
        let transport = MockHTTPTransport([
            .json("{\"value\":[],\"@odata.nextLink\":\"https://evil.test/steal\"}")
        ])
        let adapter = MicrosoftGraphAdapter(account: SyncAccount(provider: .microsoftGraph, accountID: "m"), baseURL: URL(string: "https://graph.test/v1.0")!, transport: transport, accessToken: { "secret" })
        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("Cross-origin Graph delta link must be rejected")
        } catch let error as SyncAdapterError {
            guard case .unsafeProviderURL = error else { return XCTFail("Expected typed unsafe URL error, got \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testMicrosoftRejectsHTTPPaginationLinkBeforeFollowingIt() async throws {
        let transport = MockHTTPTransport([
            .json("{\"value\":[],\"@odata.nextLink\":\"http://graph.test/v1.0/next\"}")
        ])
        let adapter = MicrosoftGraphAdapter(
            account: SyncAccount(provider: .microsoftGraph, accountID: "m"),
            baseURL: URL(string: "https://graph.test/v1.0")!,
            transport: transport,
            accessToken: { "secret" }
        )

        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("HTTP Graph pagination link must be rejected")
        } catch let error as SyncAdapterError {
            guard case .unsafeProviderURL = error else { return XCTFail("Expected typed unsafe URL error, got \(error)") }
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
    }

    func testGenericRESTDeclarativeMappingPaginatesAndReportsUnsupportedFields() async throws {
        let transport = MockHTTPTransport([
            .json("{\"items\":[{\"key\":\"l1\",\"name\":\"Work\",\"color\":\"#ff0000\"}],\"next\":\"l2\"}"),
            .json("{\"items\":[{\"key\":\"l2\",\"name\":\"Home\"}],\"next\":null}"),
            .json("{\"items\":[{\"key\":\"t1\",\"name\":\"Ship\",\"list\":\"l1\",\"done\":false,\"due\":\"2023-11-14T22:13:20Z\"}],\"next\":null}"),
        ])
        let fieldsList = RESTFieldMap(id: "key", title: "name", color: "color")
        let fieldsTask = RESTFieldMap(id: "key", title: "name", listID: "list", completed: "done", dueDate: "due")
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.test")!,
            lists: RESTCollectionDescriptor(path: "/lists", fields: fieldsList, pagination: RESTPaginationDescriptor(mode: .cursor, itemsPath: "items", nextCursorPath: "next", pageSizeQueryName: nil)),
            tasks: RESTCollectionDescriptor(path: "/tasks", fields: fieldsTask, pagination: .none),
            fieldCapabilities: AdapterFieldCapabilities(fields: [.listTitle: .native, .listColor: .unsupported, .taskTitle: .native, .taskList: .native, .taskCompletion: .native, .taskDueDate: .native])
        )
        let account = SyncAccount(provider: .genericREST, accountID: "rest-account")
        let adapter = GenericRESTAdapter(account: account, configuration: config, transport: transport, accessToken: { "access" })
        let result = try await adapter.pullChanges(since: nil)
        XCTAssertEqual(result.changes.count, 3)
        XCTAssertTrue(result.diagnostics.contains { $0.field == .listColor && $0.code == .fieldLoss })
        XCTAssertNil(result.nextCursor)
        let requests = await transport.requests
        XCTAssertEqual(requests[0].url?.query, nil)
        XCTAssertEqual(requests[1].url?.path, "/lists")
        XCTAssertEqual(requests[1].url?.query, "cursor=l2")
        XCTAssertEqual(requests[2].url?.path, "/tasks")
    }

    func testPKCEAuthorizationExchangeAndRefreshUseTokenStoreWithoutClientSecret() async throws {
        let transport = MockHTTPTransport([.json("{\"access_token\":\"new-access\",\"refresh_token\":\"refresh-2\",\"expires_in\":3600,\"token_type\":\"Bearer\"}")])
        let config = PKCEConfiguration(
            provider: .googleTasks,
            authorizationEndpoint: URL(string: "https://login.test/authorize")!,
            tokenEndpoint: URL(string: "https://login.test/token")!,
            clientID: "public-client",
            redirectURI: "myapp://oauth/callback",
            scopes: ["tasks.readonly"]
        )
        let client = PKCEOAuthClient(configuration: config, transport: transport, randomBytes: { Array(repeating: UInt8($0), count: $0) })
        let authorization = try client.beginAuthorization(state: "state")
        let query = URLComponents(url: authorization.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "state")
        XCTAssertEqual(query.first(where: { $0.name == "code_challenge_method" })?.value, "S256")
        let token = try await client.exchangeCode(callbackURL: URL(string: "myapp://oauth/callback?code=abc&state=state")!, expectedState: "state", codeVerifier: authorization.codeVerifier!)
        XCTAssertEqual(token.accessToken, "new-access")
        let request = await transport.requests[0]
        let body = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("code_verifier="))
        XCTAssertFalse(body.contains("client_secret"))
    }

    func testOAuthRefreshRejectsIdentityMismatchBeforePersistingRefreshedToken() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let account = SyncAccount(provider: .googleTasks, accountID: "expected")
        let old = OAuthToken(accessToken: "old", refreshToken: "refresh", expiresAt: now.addingTimeInterval(-10))
        let store = InMemoryOAuthTokenStore()
        try await store.save(old, for: account)
        let transport = MockHTTPTransport([.json("{\"access_token\":\"new\",\"expires_in\":3600}")])
        let client = PKCEOAuthClient(configuration: PKCEConfiguration(
            provider: .googleTasks,
            authorizationEndpoint: URL(string: "https://login.test/authorize")!,
            tokenEndpoint: URL(string: "https://login.test/token")!,
            clientID: "client",
            redirectURI: "myapp://oauth/callback",
            scopes: ["openid"]
        ), transport: transport, now: { now })
        let session = OAuthSession(account: account, store: store, client: client, now: { now }, refreshSkew: 0, accountIdentityResolver: { _ in "different" })
        do {
            _ = try await session.accessToken()
            XCTFail("Refresh must validate the provider identity before persisting the token")
        } catch let error as OAuthError {
            XCTAssertEqual(error, .accountIdentityMismatch(expected: "expected", actual: "different"))
        }
        let retained = try await store.token(for: account)
        XCTAssertNil(retained, "A refresh identity mismatch must purge the account slot rather than retain a potentially wrong token.")
    }

    func testGenericRESTChangesFeedUsesConfiguredFieldMappings() async throws {
        let transport = MockHTTPTransport([
            .json("{\"lists\":[{\"key\":\"l1\",\"name\":\"Work\"}],\"tasks\":[{\"key\":\"t1\",\"name\":\"Ship\",\"collection\":\"l1\"}],\"next\":null,\"server_time\":\"2023-11-14T22:13:20Z\"}")
        ])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.test")!,
            lists: RESTCollectionDescriptor(path: "/lists"),
            tasks: RESTCollectionDescriptor(path: "/tasks"),
            changes: RESTChangesDescriptor(
                path: "/changes",
                listFields: RESTFieldMap(id: "key", title: "name"),
                taskFields: RESTFieldMap(id: "key", title: "name", listID: "collection"),
                pagination: .none,
                serverNowPath: "server_time"
            )
        )
        let adapter = GenericRESTAdapter(
            account: SyncAccount(provider: .genericREST, accountID: "changes"),
            configuration: config,
            transport: transport,
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            accessToken: { "secret" }
        )
        let changes = try await adapter.pullChanges(since: "cursor")
        XCTAssertEqual(changes.changes.count, 2)
        XCTAssertEqual(changes.serverNow, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertTrue(changes.changes.contains { if case .list(let list) = $0 { return list.remoteID == "l1" && list.name == "Work" }; return false })
        XCTAssertTrue(changes.changes.contains { if case .task(let task) = $0 { return task.remoteID == "t1" && task.title == "Ship" && task.remoteListID == "l1" }; return false })
    }

    func testGenericRESTChangesFeedInheritsCollectionFieldMappingsWhenDescriptorUsesDefaults() async throws {
        let transport = MockHTTPTransport([
            .json("{\"lists\":[{\"key\":\"l1\",\"name\":\"Work\"}],\"tasks\":[{\"key\":\"t1\",\"name\":\"Ship\",\"collection\":\"l1\"}]}")
        ])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.test")!,
            lists: RESTCollectionDescriptor(path: "/lists", fields: RESTFieldMap(id: "key", title: "name")),
            tasks: RESTCollectionDescriptor(path: "/tasks", fields: RESTFieldMap(id: "key", title: "name", listID: "collection")),
            changes: RESTChangesDescriptor(path: "/changes", pagination: .none)
        )
        let adapter = GenericRESTAdapter(
            account: SyncAccount(provider: .genericREST, accountID: "changes-inherit"),
            configuration: config,
            transport: transport,
            accessToken: { "secret" }
        )

        let changes = try await adapter.pullChanges(since: nil)
        XCTAssertEqual(changes.changes.count, 2)
        XCTAssertTrue(changes.changes.contains { if case .list(let list) = $0 { return list.remoteID == "l1" && list.name == "Work" }; return false })
        XCTAssertTrue(changes.changes.contains { if case .task(let task) = $0 { return task.remoteID == "t1" && task.remoteListID == "l1" }; return false })
    }

    func testPendingOAuthAuthorizationStoreExpiresAndCleansState() async throws {
        let store = InMemoryOAuthPendingAuthorizationStore()
        let request = OAuthAuthorizationRequest(
            provider: .googleTasks,
            authorizationURL: URL(string: "https://accounts.test/authorize")!,
            state: "state",
            codeVerifier: "verifier"
        )
        let now = Date(timeIntervalSince1970: 10_000)
        try await store.save(PendingOAuthAuthorization(request: request, expiresAt: now.addingTimeInterval(60)))
        let active = try await store.load(at: now.addingTimeInterval(30))
        XCTAssertNotNil(active)
        let expired = try await store.load(at: now.addingTimeInterval(61))
        XCTAssertNil(expired)
        try await store.save(PendingOAuthAuthorization(request: request, expiresAt: now.addingTimeInterval(60)))
        try await store.remove()
        let removed = try await store.load(at: now)
        XCTAssertNil(removed)
    }

    func testGenericRESTRejectsCrossOriginPaginationBeforeSendingBearerToken() async throws {
        let transport = MockHTTPTransport([
            .json("{\"items\":[],\"nextLink\":\"https://evil.example.test/next\"}")
        ])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.example.test")!,
            lists: RESTCollectionDescriptor(path: "/lists", pagination: RESTPaginationDescriptor(mode: .nextLink, itemsPath: "items", nextCursorPath: nil, nextLinkPath: "nextLink", pageSizeQueryName: nil)),
            tasks: RESTCollectionDescriptor(path: "/tasks", pagination: .none)
        )
        let adapter = GenericRESTAdapter(account: SyncAccount(provider: .genericREST, accountID: "rest"), configuration: config, transport: transport, accessToken: { "secret" })
        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("Cross-origin pagination must be rejected")
        } catch let error as SyncAdapterError {
            XCTAssertTrue(error.localizedDescription.contains("cross-origin"), "actual error: \(error)")
        }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer secret")
    }

    func testGenericRESTRejectsAbsoluteConfiguredEndpointBeforeSendingBearerToken() async throws {
        let transport = MockHTTPTransport([])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.example.test")!,
            lists: RESTCollectionDescriptor(path: "https://rest.example.test/lists", pagination: .none),
            tasks: RESTCollectionDescriptor(path: "/tasks", pagination: .none)
        )
        let adapter = GenericRESTAdapter(
            account: SyncAccount(provider: .genericREST, accountID: "rest"),
            configuration: config,
            transport: transport,
            accessToken: { "secret" }
        )
        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("Absolute configured endpoints must be rejected")
        } catch let error as SyncAdapterError {
            XCTAssertTrue(error.localizedDescription.contains("relative and same-origin"), "actual error: \(error.localizedDescription)")
        }
        let requests = await transport.requests
        XCTAssertTrue(requests.isEmpty)
    }

    func testGenericRESTCreateRejectsSuccessfulResponseWithoutConfiguredRemoteID() async throws {
        let transport = MockHTTPTransport([
            .json("{}", status: 201)
        ])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.example.test")!,
            lists: RESTCollectionDescriptor(path: "/lists"),
            tasks: RESTCollectionDescriptor(path: "/tasks"),
            listMutations: RESTMutationEndpoint(createPath: "/lists")
        )
        let adapter = GenericRESTAdapter(
            account: SyncAccount(provider: .genericREST, accountID: "rest"),
            configuration: config,
            transport: transport,
            accessToken: { "secret" }
        )
        let mutation = RemoteMutation.upsertList(
            canonicalListID: SyncID.deterministic(namespace: "rest:create:list"),
            list: RemoteList(remoteID: "", name: "Created")
        )

        let result = try await adapter.push([mutation], cursor: nil)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.mappings, [])
        XCTAssertEqual(result.rejected.count, 1)
        XCTAssertTrue(result.rejected[0].reason.contains("remote identifier"))
    }

    func testPendingOAuthConfigurationCanBeExpiredAndRemoved() async throws {
        let store = InMemoryOAuthPendingAuthorizationStore()
        let request = OAuthAuthorizationRequest(provider: .microsoftGraph, authorizationURL: URL(string: "https://login.test")!, state: "s", codeVerifier: "v")
        let now = Date(timeIntervalSince1970: 20_000)
        try await store.save(PendingOAuthAuthorization(request: request, expiresAt: now.addingTimeInterval(5)))
        let active = try await store.load(at: now)
        XCTAssertNotNil(active)
        let expired = try await store.load(at: now.addingTimeInterval(6))
        XCTAssertNil(expired)
    }

}

private struct MockResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func json(_ value: String, status: Int = 200, headers: [String: String] = [:]) -> MockResponse {
        MockResponse(status: status, headers: headers, body: Data(value.utf8))
    }
}

private actor MockHTTPTransport: HTTPTransport {
    private var responses: [MockResponse]
    private(set) var requests: [URLRequest] = []

    init(_ responses: [MockResponse]) { self.responses = responses }

    func execute(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SyncAdapterError.transport("No mock response for \(request.url?.absoluteString ?? "nil")") }
        let response = responses.removeFirst()
        return HTTPResponse(statusCode: response.status, headers: response.headers, body: response.body)
    }
}
