import Foundation
import SyncContracts

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct HTTPResponse: Sendable {
    public let statusCode: Int
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }
}

public protocol HTTPTransport: Sendable {
    func execute(_ request: URLRequest) async throws -> HTTPResponse
}

public struct URLSessionHTTPTransport: HTTPTransport {
    public let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func execute(_ request: URLRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw SyncAdapterError.invalidResponse("The response was not HTTP.")
            }
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headers[String(describing: key).lowercased()] = String(describing: value)
            }
            return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
        } catch let error as SyncAdapterError {
            throw error
        } catch {
            throw SyncAdapterError.transport(error.localizedDescription)
        }
    }
}

public struct StaticBearerTokenProvider: Sendable {
    public let token: String
    public init(token: String) { self.token = token }
    public func accessToken() async throws -> String { token }
}

public enum HTTPRequestBuilder {
    public static func make(
        baseURL: URL,
        path: String,
        method: String,
        bearerToken: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        headers: [String: String] = [:]
    ) throws -> URLRequest {
        let url: URL
        if let absolute = URL(string: path), absolute.scheme != nil {
            guard var components = URLComponents(url: absolute, resolvingAgainstBaseURL: false) else {
                throw SyncAdapterError.unavailable("Invalid provider URL.")
            }
            if !query.isEmpty { components.queryItems = (components.queryItems ?? []) + query }
            guard let resolved = components.url else { throw SyncAdapterError.unavailable("Invalid provider URL.") }
            url = resolved
        } else {
            guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                throw SyncAdapterError.unavailable("Invalid provider URL.")
            }
            let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let relativePath = path.split(separator: "/", omittingEmptySubsequences: true)
                .map { Self.encodePathSegment(String($0)) }
                .joined(separator: "/")
            components.percentEncodedPath = [basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/").isEmpty
                ? "/"
                : "/" + [basePath, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
            components.queryItems = query.isEmpty ? nil : query
            guard let resolved = components.url else { throw SyncAdapterError.unavailable("Invalid provider URL.") }
            url = resolved
        }
        return make(url: url, method: method, bearerToken: bearerToken, body: body, headers: headers)
    }

    private static func encodePathSegment(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    public static func make(
        url: URL,
        method: String,
        bearerToken: String? = nil,
        body: Data? = nil,
        headers: [String: String] = [:]
    ) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let bearerToken { request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization") }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body
        return request
    }

    public static func decodeOrThrow<T: Decodable>(_ type: T.Type, from response: HTTPResponse, decoder: JSONDecoder = JSONDecoder()) throws -> T {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw SyncAdapterError.authenticationRequired }
            if response.statusCode == 412 { throw SyncAdapterError.conditionalWriteFailed(remoteRevision: response.headers["etag"]) }
            if response.statusCode == 429 {
                let retry = response.headers["retry-after"].flatMap(TimeInterval.init)
                throw SyncAdapterError.rateLimited(retryAfter: retry)
            }
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw SyncAdapterError.invalidResponse("HTTP \(response.statusCode): \(body.prefix(500))")
        }
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw SyncAdapterError.invalidResponse(error.localizedDescription)
        }
    }

    public static func checkSuccess(_ response: HTTPResponse) throws {
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 || response.statusCode == 403 { throw SyncAdapterError.authenticationRequired }
            if response.statusCode == 412 { throw SyncAdapterError.conditionalWriteFailed(remoteRevision: response.headers["etag"]) }
            if response.statusCode == 429 {
                let retry = response.headers["retry-after"].flatMap(TimeInterval.init)
                throw SyncAdapterError.rateLimited(retryAfter: retry)
            }
            let body = String(data: response.body, encoding: .utf8) ?? ""
            throw SyncAdapterError.invalidResponse("HTTP \(response.statusCode): \(body.prefix(500))")
        }
    }
}
