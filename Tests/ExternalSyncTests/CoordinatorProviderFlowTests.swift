import Foundation
import XCTest
@testable import ExternalSync
@testable import SyncAdapters
@testable import SyncContracts
@testable import SyncDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@MainActor
final class CoordinatorProviderFlowTests: XCTestCase {
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
        let databaseURL = FileManager.default.temporaryDirectory.appendingPathComponent("sync-\(UUID().uuidString).sqlite")
        let coordinator = try ProductionSyncCoordinator(
            databaseURL: databaseURL,
            defaults: defaults,
            providerFactories: [.googleTasks: factory]
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
        let connected = try await coordinator.completeOAuthAuthorization(
            callbackURL: URL(string: "appleexternalsync://oauth/callback?code=abc&state=\(secondRequestState(secondRequest))")!
        )
        XCTAssertEqual(connected.connection.provider, .googleTasks)
        XCTAssertEqual(connected.connection.status, .connected)
        let firstToken = try await tokenStore.token(for: account)
        XCTAssertNotNil(firstToken)

        _ = try await coordinator.disconnect()
        let disconnectedToken = try await tokenStore.token(for: account)
        XCTAssertNil(disconnectedToken)

        let thirdRequest = try await coordinator.beginOAuthAuthorization(provider: .googleTasks)
        let reconnected = try await coordinator.completeOAuthAuthorization(
            callbackURL: URL(string: "appleexternalsync://oauth/callback?code=def&state=\(secondRequestState(thirdRequest))")!
        )
        XCTAssertEqual(reconnected.connection.status, .connected)
        let secondToken = try await tokenStore.token(for: account)
        XCTAssertEqual(secondToken?.accessToken, "access-2")
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
            }
          }
        }
        """.utf8)
        let settings = try GenericRESTConnectionSettings(jsonData: json)
        XCTAssertEqual(settings.configuration.baseURL.scheme, "https")
        XCTAssertEqual(settings.configuration.lists.fields.id.rawValue, "id")
        XCTAssertEqual(settings.configuration.lists.fields.notes?.rawValue, "notes")
        XCTAssertEqual(settings.configuration.lists.pagination.cursorQueryName, "cursor")
        XCTAssertEqual(settings.configuration.listMutations.updatePath, "/collections/{id}")
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
