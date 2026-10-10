import Foundation
import SyncContracts
import SyncDomain

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderDateCodec {
    public static func parse(_ string: String?) -> Date? {
        guard let string else { return nil }
        return ISO8601DateParser.parse(string)
    }

    public static func encode(_ date: Date?) -> String? {
        guard let date else { return nil }
        return date.formatted(.iso8601)
    }

    private enum ISO8601DateParser {
        static func parse(_ value: String) -> Date? {
            if let interval = TimeInterval(value) {
                return Date(timeIntervalSince1970: interval)
            }
            do {
                return try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value)
            } catch {
                return try? Date.ISO8601FormatStyle().parse(value)
            }
        }
    }
}


public enum ProviderRequestSupport {
    /// Provider base URLs are application configuration, but they still form the
    /// credential boundary for every adapter request. Reject non-HTTPS or credentialed
    /// origins before an access-token provider is invoked.
    public static func validateHTTPSBaseURL(_ baseURL: URL) throws {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw SyncAdapterError.unsafeProviderURL("the configured base URL must be an HTTPS origin without credentials, query, or fragment")
        }
    }

    /// Validates a provider-supplied continuation URL against the configured HTTPS
    /// origin. Relative links are resolved against the safe base URL; absolute links must
    /// remain HTTPS and same-origin.
    public static func validatedProviderURL(_ rawValue: String, baseURL: URL, context: String) throws -> URL {
        try validateHTTPSBaseURL(baseURL)
        guard let resolved = URL(string: rawValue, relativeTo: baseURL)?.absoluteURL,
              let components = URLComponents(url: resolved, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host != nil,
              components.user == nil,
              components.password == nil,
              sameOrigin(baseURL, resolved) else {
            throw SyncAdapterError.unsafeProviderURL("the \(context) link is not HTTPS and same-origin")
        }
        return resolved
    }

    public static func validateProviderURL(_ url: URL, baseURL: URL, context: String) throws {
        _ = try validatedProviderURL(url.absoluteString, baseURL: baseURL, context: context)
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false) else { return false }
        let leftPort = left.port ?? 443
        let rightPort = right.port ?? 443
        return left.scheme?.lowercased() == right.scheme?.lowercased()
            && left.host?.lowercased() == right.host?.lowercased()
            && leftPort == rightPort
    }

    public static func executeJSON<T: Decodable>(
        _ type: T.Type,
        baseURL: URL,
        path: String,
        method: String,
        token: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        transport: any HTTPTransport,
        decoder: JSONDecoder = JSONDecoder()
    ) async throws -> T {
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: path, method: method, bearerToken: token, query: query, body: body)
        let response = try await transport.execute(request)
        return try HTTPRequestBuilder.decodeOrThrow(type, from: response, decoder: decoder)
    }

    public static func execute(
        baseURL: URL,
        path: String,
        method: String,
        token: String,
        query: [URLQueryItem] = [],
        body: Data? = nil,
        transport: any HTTPTransport
    ) async throws {
        let request = try HTTPRequestBuilder.make(baseURL: baseURL, path: path, method: method, bearerToken: token, query: query, body: body)
        let response = try await transport.execute(request)
        try HTTPRequestBuilder.checkSuccess(response)
    }
}

public enum ProviderMutationSupport {
    public static func localID(for remoteID: String, prefix: String) -> SyncID {
        SyncID.deterministic(namespace: "\(prefix):\(remoteID)")
    }

    public static func remoteTask(
        id: String,
        title: String,
        notes: String?,
        listID: String?,
        completed: Bool,
        dueDate: Date?,
        completedAt: Date?,
        priority: TaskPriority,
        deleted: Bool,
        updatedAt: Date?,
        revision: String?
    ) -> RemoteTask {
        RemoteTask(
            remoteID: id,
            title: title,
            notes: notes,
            remoteListID: listID,
            isCompleted: completed,
            dueDate: dueDate,
            completedAt: completedAt,
            priority: priority,
            isDeleted: deleted,
            updatedAt: updatedAt,
            revision: revision
        )
    }
}

public extension FieldLossDiagnostic {
    static func providerField(
        _ field: AdapterField,
        resourceType: String,
        resourceID: String,
        message: String,
        transformed: Bool = false,
        targetProvider: SyncProvider
    ) -> FieldLossDiagnostic {
        FieldLossDiagnostic(
            code: transformed ? .fieldTransformed : .fieldLoss,
            field: field,
            resourceType: resourceType,
            resourceID: resourceID,
            message: message,
            targetProvider: targetProvider.rawValue
        )
    }
}

public enum ProviderFieldDiagnostics {
    public static func forGoogle(list: RemoteList) -> [FieldLossDiagnostic] {
        var values: [FieldLossDiagnostic] = []
        if list.colorHex != nil { values.append(.providerField(.listColor, resourceType: "list", resourceID: list.remoteID, message: "Google Tasks does not store list colors." , targetProvider: .googleTasks)) }
        if list.position != nil { values.append(.providerField(.listPosition, resourceType: "list", resourceID: list.remoteID, message: "Google Tasks does not preserve list ordering keys.", targetProvider: .googleTasks)) }
        return values
    }

    public static func forGoogle(task: RemoteTask) -> [FieldLossDiagnostic] {
        var values: [FieldLossDiagnostic] = []
        if task.priority != .none { values.append(.providerField(.taskPriority, resourceType: "task", resourceID: task.remoteID, message: "Google Tasks has no task priority field.", targetProvider: .googleTasks)) }
        return values
    }

    public static func forMicrosoft(list: RemoteList) -> [FieldLossDiagnostic] {
        var values: [FieldLossDiagnostic] = []
        if list.colorHex != nil { values.append(.providerField(.listColor, resourceType: "list", resourceID: list.remoteID, message: "Microsoft To Do does not expose list colors through Graph.", targetProvider: .microsoftGraph)) }
        if list.position != nil { values.append(.providerField(.listPosition, resourceType: "list", resourceID: list.remoteID, message: "Microsoft To Do does not expose canonical list position.", targetProvider: .microsoftGraph)) }
        return values
    }

    public static func forMicrosoft(task: RemoteTask) -> [FieldLossDiagnostic] {
        return []
    }
}
