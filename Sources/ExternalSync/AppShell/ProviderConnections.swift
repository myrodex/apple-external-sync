import Foundation
import SyncAdapters
import SyncAppSupport
import SyncContracts
import SyncDomain

/// The result of provider authentication plus an initial list discovery pass. The app
/// shell consumes only this normalized value; provider adapters remain owned by the
/// shared sync runtime.
public struct SyncProviderConnection: Sendable {
    public let account: SyncAccount
    public let displayName: String?
    public let adapter: any ExternalSyncAdapter
    public let lists: [RemoteList]
    public let fieldCapabilities: AdapterFieldCapabilities
    public let diagnostics: [FieldLossDiagnostic]

    public init(
        account: SyncAccount,
        displayName: String? = nil,
        adapter: any ExternalSyncAdapter,
        lists: [RemoteList],
        fieldCapabilities: AdapterFieldCapabilities = .allNative,
        diagnostics: [FieldLossDiagnostic] = []
    ) {
        self.account = account
        self.displayName = displayName
        self.adapter = adapter
        self.lists = lists
        self.fieldCapabilities = fieldCapabilities
        self.diagnostics = diagnostics
    }
}

/// Composition contract for account providers. OAuth state/code-verifier values stay
/// inside the factory and are never persisted in the canonical sync database.
public protocol SyncProviderConnectionFactory: Sendable {
    var choice: SyncProviderChoice { get }
    var account: SyncAccount { get }
    func connect() async throws -> SyncProviderConnection
    func beginOAuthAuthorization() throws -> OAuthAuthorizationRequest
    func completeOAuthAuthorization(callbackURL: URL, request: OAuthAuthorizationRequest) async throws -> SyncProviderConnection
    func disconnect() async throws
}

/// A device-only OAuth/PKCE factory. It does not contain a client secret, presents no
/// UI, and stores refresh tokens only through the injected secure token store.
public struct DeviceOAuthConnectionFactory: SyncProviderConnectionFactory {
    public typealias AdapterBuilder = @Sendable (@escaping @Sendable () async throws -> String) throws -> any ExternalSyncAdapter
    public typealias AccountIdentityResolver = @Sendable (OAuthToken) async throws -> String

    public let choice: SyncProviderChoice
    public let account: SyncAccount
    public let displayName: String?
    public let client: PKCEOAuthClient
    public let tokenStore: any OAuthTokenStore
    public let makeAdapter: AdapterBuilder
    public let accountIdentityResolver: AccountIdentityResolver

    public init(
        choice: SyncProviderChoice,
        account: SyncAccount,
        displayName: String? = nil,
        client: PKCEOAuthClient,
        tokenStore: any OAuthTokenStore,
        accountIdentityResolver: @escaping AccountIdentityResolver,
        makeAdapter: @escaping AdapterBuilder
    ) {
        self.choice = choice
        self.account = account
        self.displayName = displayName
        self.client = client
        self.tokenStore = tokenStore
        self.accountIdentityResolver = accountIdentityResolver
        self.makeAdapter = makeAdapter
    }

    public func beginOAuthAuthorization() throws -> OAuthAuthorizationRequest {
        try client.beginAuthorization()
    }

    public func completeOAuthAuthorization(callbackURL: URL, request: OAuthAuthorizationRequest) async throws -> SyncProviderConnection {
        guard request.provider == account.provider else { throw OAuthError.callbackStateMismatch }
        guard let verifier = request.codeVerifier else { throw OAuthError.callbackMissingCode }
        let token = try await client.exchangeCode(callbackURL: callbackURL, expectedState: request.state, codeVerifier: verifier)
        try await validateAuthenticatedIdentity(token)
        try await tokenStore.save(token, for: account)
        do { return try await discover() }
        catch {
            try? await tokenStore.removeToken(for: account)
            throw error
        }
    }

    /// Reuses an existing keychain token without launching a browser. If no token is
    /// present the caller should begin the explicit authorization flow instead.
    public func connect() async throws -> SyncProviderConnection {
        guard let token = try await tokenStore.token(for: account) else { throw SyncAdapterError.authenticationRequired }
        try await validateAuthenticatedIdentity(token)
        return try await discover()
    }

    private func validateAuthenticatedIdentity(_ token: OAuthToken) async throws {
        let actual = try await accountIdentityResolver(token)
        guard actual == account.accountID else {
            throw OAuthError.accountIdentityMismatch(expected: account.accountID, actual: actual)
        }
    }

    public func disconnect() async throws {
        if let token = try await tokenStore.token(for: account) {
            if client.configuration.revocationEndpoint != nil { try? await client.revoke(token) }
            try await tokenStore.removeToken(for: account)
        }
    }

    private func discover() async throws -> SyncProviderConnection {
        let session = OAuthSession(account: account, store: tokenStore, client: client)
        let adapter = try makeAdapter(session.accessTokenProvider)
        let pulled = try await adapter.pullChanges(since: nil)
        return SyncProviderConnection(
            account: account,
            displayName: displayName,
            adapter: adapter,
            lists: pulled.changes.compactMap { if case .list(let list) = $0 { return list }; return nil },
            fieldCapabilities: (adapter as? any FieldDiagnosticsProviding)?.fieldCapabilities ?? .allNative,
            diagnostics: pulled.diagnostics
        )
    }

    public static func googleTasks(
        accountID: String,
        clientID: String,
        redirectURI: String,
        tokenStore: any OAuthTokenStore = KeychainOAuthTokenStore(),
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        baseURL: URL = URL(string: "https://tasks.googleapis.com")!
    ) -> DeviceOAuthConnectionFactory {
        let account = SyncAccount(provider: .googleTasks, accountID: accountID)
        let configuration = PKCEConfiguration(
            provider: .googleTasks,
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            revocationEndpoint: URL(string: "https://oauth2.googleapis.com/revoke")!,
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: ["openid", "https://www.googleapis.com/auth/tasks"]
        )
        let client = PKCEOAuthClient(configuration: configuration, transport: transport)
        return DeviceOAuthConnectionFactory(choice: .googleTasks, account: account, displayName: "Google Tasks", client: client, tokenStore: tokenStore, accountIdentityResolver: { token in
            try await Self.fetchProviderIdentity(endpoint: URL(string: "https://openidconnect.googleapis.com/v1/userinfo")!, token: token, transport: transport, keys: ["sub"])
        }) { accessToken in
            GoogleTasksAdapter(account: account, baseURL: baseURL, transport: transport, accessToken: accessToken)
        }
    }

    public static func microsoftToDo(
        accountID: String,
        clientID: String,
        redirectURI: String,
        tokenStore: any OAuthTokenStore = KeychainOAuthTokenStore(),
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        baseURL: URL = URL(string: "https://graph.microsoft.com/v1.0")!,
        tenant: String = "common"
    ) -> DeviceOAuthConnectionFactory {
        let account = SyncAccount(provider: .microsoftGraph, accountID: accountID)
        let configuration = PKCEConfiguration(
            provider: .microsoftGraph,
            authorizationEndpoint: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/\(tenant)/oauth2/v2.0/token")!,
            clientID: clientID,
            redirectURI: redirectURI,
            scopes: ["User.Read", "Tasks.ReadWrite", "offline_access"]
        )
        let client = PKCEOAuthClient(configuration: configuration, transport: transport)
        return DeviceOAuthConnectionFactory(choice: .microsoftToDo, account: account, displayName: "Microsoft To Do", client: client, tokenStore: tokenStore, accountIdentityResolver: { token in
            try await Self.fetchProviderIdentity(endpoint: URL(string: "https://graph.microsoft.com/v1.0/me")!, token: token, transport: transport, keys: ["id", "userPrincipalName"])
        }) { accessToken in
            MicrosoftGraphAdapter(account: account, baseURL: baseURL, transport: transport, accessToken: accessToken)
        }
    }

    private static func fetchProviderIdentity(
        endpoint: URL,
        token: OAuthToken,
        transport: any HTTPTransport,
        keys: [String]
    ) async throws -> String {
        let request = HTTPRequestBuilder.make(url: endpoint, method: "GET", bearerToken: token.accessToken)
        let response = try await transport.execute(request)
        try HTTPRequestBuilder.checkSuccess(response)
        guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
            throw SyncAdapterError.invalidResponse("Provider identity response was not an object.")
        }
        for key in keys {
            if let value = object[key] as? String, !value.isEmpty { return value }
        }
        throw SyncAdapterError.invalidResponse("Provider identity response did not contain a stable account identifier.")
    }
}

/// App-owned generic REST credentials/configuration. The JSON form contains no
/// bearer token; the token is resolved from the Keychain service/access-group below.
public struct GenericRESTConnectionSettings: Codable, Hashable, Sendable {
    public let accountID: String
    public let keychainService: String
    public let keychainAccessGroup: String?
    public let configuration: GenericRESTConfiguration

    public init(
        accountID: String,
        keychainService: String = "dev.myrodex.external-sync.oauth",
        keychainAccessGroup: String? = nil,
        configuration: GenericRESTConfiguration
    ) {
        self.accountID = accountID
        self.keychainService = keychainService
        self.keychainAccessGroup = keychainAccessGroup
        self.configuration = configuration
    }

    public init(jsonData: Data, requireHTTPS: Bool = true) throws {
        do {
            self = try JSONDecoder().decode(Self.self, from: jsonData)
        } catch {
            throw GenericRESTConfigurationError.invalidJSON(error.localizedDescription)
        }
        guard !accountID.isEmpty, !keychainService.isEmpty else {
            throw GenericRESTConfigurationError.invalidJSON("accountID and keychainService are required.")
        }
        try configuration.validate(requireHTTPS: requireHTTPS)
    }
}

/// Generic REST connection for a pre-provisioned, refresh-aware bearer-token closure.
/// OAuth-capable custom services can use DeviceOAuthConnectionFactory with a
/// GenericRESTAdapter as its adapter builder.
public struct GenericRESTConnectionFactory: SyncProviderConnectionFactory {
    public let choice: SyncProviderChoice = .customREST
    public let account: SyncAccount
    public let displayName: String?
    public let configuration: GenericRESTConfiguration
    private let tokenProvider: @Sendable () async throws -> String
    private let transport: any HTTPTransport
    private let tokenStore: (any OAuthTokenStore)?

    public init(
        accountID: String,
        displayName: String? = "Custom REST service",
        configuration: GenericRESTConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        tokenStore: (any OAuthTokenStore)? = nil,
        accessToken: @escaping @Sendable () async throws -> String
    ) {
        self.account = SyncAccount(provider: .genericREST, accountID: accountID)
        self.displayName = displayName
        self.configuration = configuration
        self.transport = transport
        self.tokenStore = tokenStore
        self.tokenProvider = accessToken
    }

    public init(
        settings: GenericRESTConnectionSettings,
        transport: any HTTPTransport = URLSessionHTTPTransport()
    ) {
        let tokenStore = KeychainOAuthTokenStore(service: settings.keychainService, accessGroup: settings.keychainAccessGroup)
        self.init(accountID: settings.accountID, configuration: settings.configuration, transport: transport, tokenStore: tokenStore) {
            guard let token = try await tokenStore.token(for: SyncAccount(provider: .genericREST, accountID: settings.accountID)) else {
                throw SyncAdapterError.authenticationRequired
            }
            return token.accessToken
        }
    }

    public func beginOAuthAuthorization() throws -> OAuthAuthorizationRequest {
        throw SyncAppCoordinatorError.oauthNotConfigured(.customREST)
    }

    public func completeOAuthAuthorization(callbackURL: URL, request: OAuthAuthorizationRequest) async throws -> SyncProviderConnection {
        throw SyncAppCoordinatorError.oauthCallbackInvalid
    }

    public func connect() async throws -> SyncProviderConnection {
        let adapter = GenericRESTAdapter(account: account, configuration: configuration, transport: transport, accessToken: tokenProvider)
        let pulled = try await adapter.pullChanges(since: nil)
        return SyncProviderConnection(
            account: account,
            displayName: displayName,
            adapter: adapter,
            lists: pulled.changes.compactMap { if case .list(let list) = $0 { return list }; return nil },
            fieldCapabilities: adapter.fieldCapabilities,
            diagnostics: pulled.diagnostics
        )
    }

    public func disconnect() async throws {
        try await tokenStore?.removeToken(for: account)
    }
}
