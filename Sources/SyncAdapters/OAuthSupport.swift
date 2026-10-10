import Foundation
import SyncContracts
import SyncDomain

#if canImport(CryptoKit)
import CryptoKit
#endif

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A bearer token and its refresh metadata. The token store owns this value; adapters
/// only ever receive the short-lived access-token string.
public struct OAuthToken: Codable, Hashable, Sendable {
    public let accessToken: String
    public let tokenType: String
    public let refreshToken: String?
    public let expiresAt: Date?
    public let scopes: [String]

    public init(
        accessToken: String,
        tokenType: String = "Bearer",
        refreshToken: String? = nil,
        expiresAt: Date? = nil,
        scopes: [String] = []
    ) {
        self.accessToken = accessToken
        self.tokenType = tokenType
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
    }

    public func isUsable(at date: Date = Date(), refreshSkew: TimeInterval = 60) -> Bool {
        guard !accessToken.isEmpty else { return false }
        guard let expiresAt else { return true }
        return expiresAt.timeIntervalSince(date) > refreshSkew
    }
}

/// Durable token storage is deliberately abstract. Production applications can back
/// this protocol with Keychain/secure enclave storage while tests use the actor below.
public protocol OAuthTokenStore: Sendable {
    func token(for account: SyncAccount) async throws -> OAuthToken?
    func save(_ token: OAuthToken, for account: SyncAccount) async throws
    func removeToken(for account: SyncAccount) async throws
}

public actor InMemoryOAuthTokenStore: OAuthTokenStore {
    private var values: [SyncAccount: OAuthToken] = [:]

    public init() {}

    public func token(for account: SyncAccount) async throws -> OAuthToken? { values[account] }

    public func save(_ token: OAuthToken, for account: SyncAccount) async throws {
        values[account] = token
    }

    public func removeToken(for account: SyncAccount) async throws {
        values.removeValue(forKey: account)
    }
}

public enum OAuthError: Error, LocalizedError, Equatable, Sendable {
    case invalidAuthorizationURL
    case callbackMissingCode
    case callbackStateMismatch
    case callbackProviderError(String)
    case missingRefreshToken
    case invalidTokenResponse(String)
    case revocationUnavailable
    case pkceUnavailable
    case tokenStorage(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAuthorizationURL: return "The OAuth authorization URL is invalid."
        case .callbackMissingCode: return "The OAuth callback did not contain an authorization code."
        case .callbackStateMismatch: return "The OAuth callback state did not match the pending request."
        case .callbackProviderError(let value): return "The OAuth provider rejected the callback: \(value)."
        case .missingRefreshToken: return "The OAuth token does not contain a refresh token."
        case .invalidTokenResponse(let value): return "The OAuth token response was invalid: \(value)."
        case .revocationUnavailable: return "This OAuth provider does not expose token revocation."
        case .pkceUnavailable: return "PKCE S256 is unavailable on this platform."
        case .tokenStorage(let value): return "The OAuth token store failed: \(value)."
        }
    }
}

public struct PKCEConfiguration: Hashable, Sendable {
    public let provider: SyncProvider
    public let authorizationEndpoint: URL
    public let tokenEndpoint: URL
    public let revocationEndpoint: URL?
    public let clientID: String
    public let redirectURI: String
    public let scopes: [String]

    public init(
        provider: SyncProvider,
        authorizationEndpoint: URL,
        tokenEndpoint: URL,
        revocationEndpoint: URL? = nil,
        clientID: String,
        redirectURI: String,
        scopes: [String]
    ) {
        self.provider = provider
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.revocationEndpoint = revocationEndpoint
        self.clientID = clientID
        self.redirectURI = redirectURI
        self.scopes = scopes
    }
}

/// Minimal OAuth 2.0 Authorization Code + PKCE client. It has no client secret and is
/// therefore safe to use from a device-only application. Network I/O remains injected
/// through HTTPTransport for deterministic tests.
public struct PKCEOAuthClient: Sendable {
    public let configuration: PKCEConfiguration
    private let transport: any HTTPTransport
    private let randomBytes: @Sendable (Int) -> [UInt8]
    private let now: @Sendable () -> Date

    public init(
        configuration: PKCEConfiguration,
        transport: any HTTPTransport = URLSessionHTTPTransport(),
        now: @escaping @Sendable () -> Date = Date.init,
        randomBytes: @escaping @Sendable (Int) -> [UInt8] = PKCEOAuthClient.secureRandomBytes
    ) {
        self.configuration = configuration
        self.transport = transport
        self.now = now
        self.randomBytes = randomBytes
    }

    public func beginAuthorization(state: String? = nil) throws -> OAuthAuthorizationRequest {
        let state = state ?? Self.base64URL(randomBytes(32))
        let verifier = Self.base64URL(randomBytes(32))
        guard var components = URLComponents(url: configuration.authorizationEndpoint, resolvingAgainstBaseURL: false) else {
            throw OAuthError.invalidAuthorizationURL
        }
        var query = components.queryItems ?? []
        query += [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: configuration.clientID),
            URLQueryItem(name: "redirect_uri", value: configuration.redirectURI),
            URLQueryItem(name: "scope", value: configuration.scopes.joined(separator: " ")),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: try Self.codeChallenge(for: verifier)),
            URLQueryItem(name: "code_challenge_method", value: "S256")
        ]
        components.queryItems = query
        guard let url = components.url else { throw OAuthError.invalidAuthorizationURL }
        return OAuthAuthorizationRequest(
            provider: configuration.provider,
            authorizationURL: url,
            state: state,
            codeVerifier: verifier
        )
    }

    public func exchangeCode(
        callbackURL: URL,
        expectedState: String,
        codeVerifier: String
    ) async throws -> OAuthToken {
        guard Self.matchesRedirect(callbackURL, configuredURI: configuration.redirectURI) else {
            throw OAuthError.callbackStateMismatch
        }
        let query = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if let providerError = query.first(where: { $0.name == "error" })?.value {
            throw OAuthError.callbackProviderError(providerError)
        }
        guard query.first(where: { $0.name == "state" })?.value == expectedState else {
            throw OAuthError.callbackStateMismatch
        }
        guard let code = query.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
            throw OAuthError.callbackMissingCode
        }
        let form = [
            "grant_type": "authorization_code",
            "code": code,
            "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI,
            "code_verifier": codeVerifier
        ]
        return try await requestToken(form: form)
    }

    public func refresh(_ token: OAuthToken) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw OAuthError.missingRefreshToken
        }
        let refreshed = try await requestToken(form: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": configuration.clientID
        ])
        // Providers are allowed to omit refresh_token on rotation responses. Retain the
        // previous value unless a new one was explicitly returned.
        return OAuthToken(
            accessToken: refreshed.accessToken,
            tokenType: refreshed.tokenType,
            refreshToken: refreshed.refreshToken ?? refreshToken,
            expiresAt: refreshed.expiresAt,
            scopes: refreshed.scopes.isEmpty ? token.scopes : refreshed.scopes
        )
    }

    public func revoke(_ token: OAuthToken) async throws {
        guard let endpoint = configuration.revocationEndpoint else { throw OAuthError.revocationUnavailable }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formData([
            "token": token.refreshToken ?? token.accessToken,
            "client_id": configuration.clientID,
            "token_type_hint": token.refreshToken == nil ? "access_token" : "refresh_token"
        ])
        let response = try await transport.execute(request)
        try HTTPRequestBuilder.checkSuccess(response)
    }

    private func requestToken(form: [String: String]) async throws -> OAuthToken {
        var request = URLRequest(url: configuration.tokenEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Self.formData(form)
        let response = try await transport.execute(request)
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 {
                throw SyncAdapterError.authenticationRequired
            }
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw OAuthError.invalidTokenResponse("HTTP \(response.statusCode): \(body.prefix(500))")
        }
        do {
            let decoder = JSONDecoder()
            let payload = try decoder.decode(TokenPayload.self, from: response.body)
            guard !payload.accessToken.isEmpty else { throw OAuthError.invalidTokenResponse("access_token is empty") }
            return OAuthToken(
                accessToken: payload.accessToken,
                tokenType: payload.tokenType ?? "Bearer",
                refreshToken: payload.refreshToken,
                expiresAt: payload.expiresIn.map { now().addingTimeInterval(TimeInterval($0)) },
                scopes: payload.scope?.split(separator: " ").map { String($0) } ?? []
            )
        } catch let error as OAuthError {
            throw error
        } catch {
            throw OAuthError.invalidTokenResponse(error.localizedDescription)
        }
    }

    private struct TokenPayload: Decodable {
        let accessToken: String
        let tokenType: String?
        let refreshToken: String?
        let expiresIn: Int?
        let scope: String?

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case tokenType = "token_type"
            case refreshToken = "refresh_token"
            case expiresIn = "expires_in"
            case scope
        }
    }

    private static func formData(_ values: [String: String]) -> Data {
        values
            .sorted { $0.key < $1.key }
            .map { "\(formEscape($0.key))=\(formEscape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private static func formEscape(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func secureRandomBytes(_ count: Int) -> [UInt8] {
        var generator = SystemRandomNumberGenerator()
        return (0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    }

    fileprivate static func base64URL(_ bytes: [UInt8]) -> String {
        Data(bytes)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func matchesRedirect(_ callbackURL: URL, configuredURI: String) -> Bool {
        guard let expected = URLComponents(string: configuredURI),
              let callback = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else { return false }
        return expected.scheme?.lowercased() == callback.scheme?.lowercased()
            && expected.host?.lowercased() == callback.host?.lowercased()
            && expected.port == callback.port
            && expected.path == callback.path
    }

    fileprivate static func codeChallenge(for verifier: String) throws -> String {
#if canImport(CryptoKit)
        return base64URL(Array(SHA256.hash(data: Data(verifier.utf8))))
#else
        throw OAuthError.pkceUnavailable
#endif
    }
}

/// Refreshes an access token on demand and persists the refreshed value. This actor is
/// the adapter-facing token provider and is safe to share across concurrent sync calls.
public actor OAuthSession {
    public let account: SyncAccount
    private let store: any OAuthTokenStore
    private let client: PKCEOAuthClient
    private let now: @Sendable () -> Date
    private let refreshSkew: TimeInterval
    private var refreshTask: Task<OAuthToken, Error>?

    public init(
        account: SyncAccount,
        store: any OAuthTokenStore,
        client: PKCEOAuthClient,
        now: @escaping @Sendable () -> Date = Date.init,
        refreshSkew: TimeInterval = 60
    ) {
        self.account = account
        self.store = store
        self.client = client
        self.now = now
        self.refreshSkew = refreshSkew
        self.refreshTask = nil
    }

    public func accessToken() async throws -> String {
        guard let token = try await store.token(for: account) else {
            throw SyncAdapterError.authenticationRequired
        }
        if token.isUsable(at: now(), refreshSkew: refreshSkew) { return token.accessToken }
        let task: Task<OAuthToken, Error>
        if let refreshTask {
            task = refreshTask
        } else {
            task = Task { try await client.refresh(token) }
            refreshTask = task
        }
        do {
            let refreshed = try await task.value
            try await store.save(refreshed, for: account)
            refreshTask = nil
            return refreshed.accessToken
        } catch {
            refreshTask = nil
            throw error
        }
    }

    public func save(_ token: OAuthToken) async throws {
        try await store.save(token, for: account)
    }

    public func revoke() async throws {
        guard let token = try await store.token(for: account) else { return }
        try await client.revoke(token)
        try await store.removeToken(for: account)
    }
}

public extension OAuthSession {
    /// Closure form accepted by existing adapter initializers.
    nonisolated var accessTokenProvider: @Sendable () async throws -> String {
        { [self] in try await self.accessToken() }
    }
}
