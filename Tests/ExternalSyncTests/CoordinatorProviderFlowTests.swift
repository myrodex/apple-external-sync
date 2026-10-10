import Foundation
import XCTest
@testable import ExternalSync
@testable import SyncAdapters
@testable import SyncContracts
@testable import SyncDomain
@testable import SyncStore

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class CoordinatorProviderFlowTests: XCTestCase {
    func testProviderAccountIDsKeepTokensIsolatedWhenSwitchingAccounts() async throws {
        let store = InMemoryOAuthTokenStore()
        let transport = CoordinatorMockTransport(responses: [])
        let first = DeviceOAuthConnectionFactory.googleTasks(accountID: "google-subject-a", clientID: "client", redirectURI: "appleexternalsync://oauth/callback", tokenStore: store, transport: transport, baseURL: URL(string: "https://tasks.test")!)
        let second = DeviceOAuthConnectionFactory.googleTasks(accountID: "google-subject-b", clientID: "client", redirectURI: "appleexternalsync://oauth/callback", tokenStore: store, transport: transport, baseURL: URL(string: "https://tasks.test")!)
        try await store.save(OAuthToken(accessToken: "a", refreshToken: "ra"), for: first.account)
        XCTAssertEqual(first.account.accountID, "google-subject-a")
        XCTAssertEqual(second.account.accountID, "google-subject-b")
        let firstToken = try await store.token(for: first.account)
        let secondToken = try await store.token(for: second.account)
        XCTAssertEqual(firstToken?.accessToken, "a")
        XCTAssertNil(secondToken)
    }

    func testCoordinatorRoutesOAuthCallbackValidatesStateAndSupportsReconnect() async throws {
        let transport = CoordinatorMockTransport(responses: [
            .json("{\"access_token\":\"access-1\",\"refresh_token\":\"refresh-1\",\"expires_in\":3600}"),
            .json("{\"items\":[]}"),
            .json("{}"), // token revocation on disconnect
            .json("{\"access_token\":\"access-2\",\"refresh_token\":\"refresh-2\",\"expires_in\":3600}"),
            .json("{\"items\":[]}")
        ])
        let account = SyncAccount(provider: .googleTasks, accountID: "oauth-test")
        let tokenStore = InMemoryOAuthTokenStore()
        let factory = DeviceOAuthConnectionFactory.googleTasks(
            accountID: account.accountID,
            clientID: "public-client",
            redirectURI: "appleexternalsync://oauth/callback",
            tokenStore: tokenStore,
            transport: transport,
            baseURL: URL(string: "https://tasks.test")!
        )
        let suiteName = "CoordinatorProviderFlowTests.\(UUID().uuidString)"
        let defaults = try temporaryDefaults(suiteName: suiteName)
        let pendingStore = InMemoryOAuthPendingAuthorizationStore()
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        let coordinator = try ProductionSyncCoordinator(
            databaseURL: databaseURL,
            defaults: defaults,
            providerFactories: [.googleTasks: factory],
            pendingAuthorizationStore: pendingStore
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let firstRequest = try await coordinator.beginOAuthAuthorization(provider: .googleTasks)
        XCTAssertEqual(firstRequest.provider, .googleTasks)
        do {
            _ = try await coordinator.completeOAuthAuthorization(
                callbackURL: URL(string: "appleexternalsync://oauth/callback?code=abc&state=wrong")!
            )
            XCTFail("A callback with a mismatched OAuth state must fail")
        } catch {
            XCTAssertEqual(error as? OAuthError, .callbackStateMismatch)
        }

        let secondRequest = try await coordinator.beginOAuthAuthorization(provider: .googleTasks)
        // Simulate process relaunch: a new coordinator instance recovers the pending
        // state/code verifier from the shared secure store before exchanging the callback.
        let relaunchedCoordinator = try ProductionSyncCoordinator(
            databaseURL: databaseURL,
            defaults: defaults,
            providerFactories: [.googleTasks: factory],
            pendingAuthorizationStore: pendingStore
        )
        let connected = try await relaunchedCoordinator.completeOAuthAuthorization(
            callbackURL: URL(string: "appleexternalsync://oauth/callback?code=abc&state=\(secondRequestState(secondRequest))")!
        )
        XCTAssertEqual(connected.connection.provider, .googleTasks)
        XCTAssertEqual(connected.connection.status, .connected)
        let firstToken = try await tokenStore.token(for: account)
        XCTAssertNotNil(firstToken)

        _ = try await relaunchedCoordinator.disconnect()
        let disconnectedToken = try await tokenStore.token(for: account)
        XCTAssertNil(disconnectedToken)

        let thirdRequest = try await relaunchedCoordinator.beginOAuthAuthorization(provider: .googleTasks)
        let reconnected = try await relaunchedCoordinator.completeOAuthAuthorization(
            callbackURL: URL(string: "appleexternalsync://oauth/callback?code=def&state=\(secondRequestState(thirdRequest))")!
        )
        XCTAssertEqual(reconnected.connection.status, .connected)
        let secondToken = try await tokenStore.token(for: account)
        XCTAssertEqual(secondToken?.accessToken, "access-2")
    }

    func testCoordinatorRecoversPendingOAuthAcrossReinitialization() async throws {
        let transport = CoordinatorMockTransport(responses: [
            .json("{\"access_token\":\"access-recovered\",\"refresh_token\":\"refresh-recovered\",\"expires_in\":3600}"),
            .json("{\"items\":[]}")
        ])
        let account = SyncAccount(provider: .googleTasks, accountID: "recovery-test")
        let tokenStore = InMemoryOAuthTokenStore()
        let factory = DeviceOAuthConnectionFactory.googleTasks(
            accountID: account.accountID,
            clientID: "public-client",
            redirectURI: "appleexternalsync://oauth/callback",
            tokenStore: tokenStore,
            transport: transport,
            baseURL: URL(string: "https://tasks.test")!
        )
        let pendingStore = InMemoryOAuthPendingAuthorizationStore()
        let suiteName = "CoordinatorProviderFlowTests.\(UUID().uuidString)"
        let defaults = try temporaryDefaults(suiteName: suiteName)
        let firstDatabaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        let secondDatabaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: firstDatabaseURL)
            try? FileManager.default.removeItem(at: secondDatabaseURL)
        }

        let firstCoordinator = try ProductionSyncCoordinator(
            databaseURL: firstDatabaseURL,
            defaults: defaults,
            providerFactories: [.googleTasks: factory],
            pendingAuthorizationStore: pendingStore
        )
        let request = try await firstCoordinator.beginOAuthAuthorization(provider: .googleTasks)

        let relaunchedCoordinator = try ProductionSyncCoordinator(
            databaseURL: secondDatabaseURL,
            defaults: defaults,
            providerFactories: [.googleTasks: factory],
            pendingAuthorizationStore: pendingStore
        )
        let connected = try await relaunchedCoordinator.completeOAuthAuthorization(
            callbackURL: URL(string: "appleexternalsync://oauth/callback?code=recovered&state=\(secondRequestState(request))")!
        )

        XCTAssertEqual(connected.connection.provider, .googleTasks)
        XCTAssertEqual(connected.connection.status, .connected)
        let recoveredToken = try await tokenStore.token(for: account)
        XCTAssertEqual(recoveredToken?.accessToken, "access-recovered")
        let pendingAfterCompletion = try await pendingStore.load(at: Date())
        XCTAssertNil(pendingAfterCompletion)
    }

    func testDisconnectRemovesScopedSQLiteStateWithoutAffectingAnotherAccount() async throws {
        let transport = CoordinatorMockTransport(responses: [
            .json("{\"items\":[{\"id\":\"l1\",\"title\":\"Work\"}]}"),
            .json("{\"items\":[]}")
        ])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://privacy.test")!,
            lists: RESTCollectionDescriptor(path: "/lists", pagination: .none),
            tasks: RESTCollectionDescriptor(path: "/tasks", pagination: .none)
        )
        let account = SyncAccount(provider: .genericREST, accountID: "privacy-account")
        let other = SyncAccount(provider: .genericREST, accountID: "other-account")
        let factory = GenericRESTConnectionFactory(accountID: account.accountID, configuration: config, transport: transport, accessToken: { "token" })
        let suiteName = "CoordinatorProviderFlowTests.\(UUID().uuidString)"
        let defaults = try temporaryDefaults(suiteName: suiteName)
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        let store = try SQLiteLocalStore(url: databaseURL)
        let removedListID = SyncID.deterministic(namespace: "removed")
        let retainedListID = SyncID.deterministic(namespace: "retained")
        let seeded = SyncState(
            lists: [
                CanonicalList(id: removedListID, name: "Removed", createdAt: Date(), updatedAt: Date()),
                CanonicalList(id: retainedListID, name: "Retained", createdAt: Date(), updatedAt: Date())
            ],
            listMappings: [
                ListMapping(account: account, canonicalListID: removedListID, remoteListID: "r1", lastSeenAt: Date()),
                ListMapping(account: other, canonicalListID: retainedListID, remoteListID: "r2", lastSeenAt: Date())
            ],
            cursors: [SyncCursor(account: account, value: "cursor-a", updatedAt: Date()), SyncCursor(account: other, value: "cursor-b", updatedAt: Date())]
        )
        try await store.save(seeded)
        let coordinator = try ProductionSyncCoordinator(databaseURL: databaseURL, defaults: defaults, providerFactories: [.customREST: factory])
        _ = try await coordinator.connect(provider: .customREST)
        _ = try await coordinator.disconnect()
        let result = try await store.load()
        XCTAssertFalse(result.lists.contains { $0.id == removedListID })
        XCTAssertTrue(result.lists.contains { $0.id == retainedListID })
        XCTAssertFalse(result.listMappings.contains { $0.account == account })
        XCTAssertTrue(result.listMappings.contains { $0.account == other })
        XCTAssertNil(result.cursor(for: account))
        XCTAssertNotNil(result.cursor(for: other))
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: databaseURL)
    }

    func testGenericRESTConfigurationDecodesAppJSONWithDefaultedFieldsAndEndpoints() throws {
        let json = Data("""
        {
          "accountID": "device",
          "keychainService": "test.oauth",
          "configuration": {
            "baseURL": "https://rest.example.test",
            "lists": {
              "path": "/collections",
              "fields": { "id": "id", "title": "name" },
              "pagination": { "mode": "cursor", "itemsPath": "items", "nextCursorPath": "next" }
            },
            "tasks": {
              "path": "/items",
              "fields": { "id": "id", "title": "name", "listID": "collectionId" },
              "pagination": { "mode": "cursor", "itemsPath": "items", "nextCursorPath": "next" }
            },
            "listMutations": {
              "createPath": "/collections",
              "updatePath": "/collections/{id}",
              "deletePath": "/collections/{id}"
            },
            "taskMutations": {
              "createPath": "/items",
              "updatePath": "/items/{id}",
              "deletePath": "/items/{id}"
            },
            "changes": { "path": "/changes" }
          }
        }
        """.utf8)
        let settings = try GenericRESTConnectionSettings(jsonData: json)
        XCTAssertEqual(settings.configuration.baseURL.scheme, "https")
        XCTAssertEqual(settings.configuration.lists.fields.id.rawValue, "id")
        XCTAssertEqual(settings.configuration.lists.fields.notes?.rawValue, "notes")
        XCTAssertEqual(settings.configuration.lists.pagination.cursorQueryName, "cursor")
        XCTAssertEqual(settings.configuration.listMutations.updatePath, "/collections/{id}")
        XCTAssertEqual(settings.configuration.changes?.listItemsPath.rawValue, "lists")
    }

    func testGenericRESTConfigurationRejectsCrossOriginOrInsecureEndpoints() throws {
        let crossOrigin = Data("""
        {
          "accountID": "rest",
          "keychainService": "test.oauth",
          "configuration": {
            "baseURL": "https://rest.example.test",
            "lists": { "path": "https://evil.example.test/lists" },
            "tasks": { "path": "/tasks" }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try GenericRESTConnectionSettings(jsonData: crossOrigin)) { error in
            guard case .unsafeEndpointPath = error as? GenericRESTConfigurationError else {
                return XCTFail("Expected unsafe endpoint rejection, got \(error)")
            }
        }

        let insecure = Data("""
        {
          "accountID": "rest",
          "keychainService": "test.oauth",
          "configuration": {
            "baseURL": "http://rest.example.test",
            "lists": { "path": "/lists" },
            "tasks": { "path": "/tasks" }
          }
        }
        """.utf8)
        XCTAssertThrowsError(try GenericRESTConnectionSettings(jsonData: insecure)) { error in
            XCTAssertEqual(error as? GenericRESTConfigurationError, .insecureBaseURL)
        }
    }

    func testCoordinatorExecutesConfiguredGenericRESTMutationThroughEngine() async throws {
        let transport = CoordinatorMockTransport(responses: [
            .json("{\"items\":[{\"id\":\"l1\",\"title\":\"Work\",\"revision\":\"r1\"}]}"),
            .json("{\"items\":[]}"),
            .json("{\"items\":[{\"id\":\"l1\",\"title\":\"Work\",\"revision\":\"r1\"}]}"),
            .json("{\"items\":[]}"),
            .json("{\"items\":[{\"id\":\"l1\",\"title\":\"Work\",\"revision\":\"r1\"}]}"),
            .json("{\"items\":[]}"),
            .json("{\"id\":\"l1\",\"revision\":\"r2\"}")
        ])
        let config = GenericRESTConfiguration(
            baseURL: URL(string: "https://rest.test")!,
            lists: RESTCollectionDescriptor(path: "/collections", fields: RESTFieldMap(id: "id", title: "title", revision: "revision"), pagination: .none),
            tasks: RESTCollectionDescriptor(path: "/items", pagination: .none),
            listMutations: RESTMutationEndpoint(createPath: "/collections", updatePath: "/collections/{id}", deletePath: "/collections/{id}"),
            taskMutations: RESTMutationEndpoint(createPath: "/items", updatePath: "/items/{id}", deletePath: "/items/{id}")
        )
        let settingsJSON = try JSONEncoder().encode(GenericRESTConnectionSettings(
            accountID: "rest-test",
            keychainService: "test.service",
            configuration: config
        ))
        let decodedSettings = try GenericRESTConnectionSettings(jsonData: settingsJSON)
        XCTAssertEqual(decodedSettings.configuration.listMutations.updatePath, "/collections/{id}")
        let factory = GenericRESTConnectionFactory(
            accountID: decodedSettings.accountID,
            configuration: decodedSettings.configuration,
            transport: transport,
            accessToken: { "rest-token" }
        )
        let suiteName = "CoordinatorProviderFlowTests.\(UUID().uuidString)"
        let defaults = try temporaryDefaults(suiteName: suiteName)
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        let coordinator = try ProductionSyncCoordinator(
            databaseURL: databaseURL,
            defaults: defaults,
            providerFactories: [.customREST: factory]
        )
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: databaseURL)
        }

        let connected = try await coordinator.connect(provider: .customREST)
        XCTAssertEqual(connected.availableLists.map(\.id), ["l1"])
        _ = try await coordinator.updateListSelection(["l1"])
        let initial = try await coordinator.syncNow()
        XCTAssertEqual(initial.lastSync?.status, .succeeded)

        let canonicalID = SyncID.deterministic(namespace: "genericREST:rest-test:list:l1")
        _ = try await coordinator.applyLocalChange(.upsertList(CanonicalList(
            id: canonicalID,
            name: "Renamed",
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )))
        let updated = try await coordinator.syncNow()
        XCTAssertEqual(updated.lastSync?.status, .succeeded)

        let requests = await transport.requests
        XCTAssertEqual(requests.last?.httpMethod, "PATCH")
        XCTAssertEqual(requests.last?.url?.path, "/collections/l1")
        XCTAssertEqual(requests.last?.value(forHTTPHeaderField: "Authorization"), "Bearer rest-token")
        let body = String(data: requests.last?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("Renamed"))
    }

    private func temporaryDefaults(suiteName: String) throws -> UserDefaults {
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw TestError.defaultsUnavailable }
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func secondRequestState(_ request: SyncOAuthAuthorization) -> String {
        // OAuthAuthorizationRequest intentionally exposes state; SyncOAuthAuthorization
        // only carries the user-facing URL, so derive it from the URL for this test.
        URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value ?? ""
    }

    private enum TestError: Error { case defaultsUnavailable }
}

private struct CoordinatorMockResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json(_ string: String, statusCode: Int = 200, headers: [String: String] = [:]) -> CoordinatorMockResponse {
        CoordinatorMockResponse(statusCode: statusCode, headers: headers, body: Data(string.utf8))
    }
}

private actor CoordinatorMockTransport: HTTPTransport {
    private var responses: [CoordinatorMockResponse]
    private(set) var requests: [URLRequest] = []

    init(responses: [CoordinatorMockResponse]) { self.responses = responses }

    func execute(_ request: URLRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw SyncAdapterError.transport("No mock response for \(request.url?.absoluteString ?? "nil")") }
        let response = responses.removeFirst()
        return HTTPResponse(statusCode: response.statusCode, headers: response.headers, body: response.body)
    }
}
