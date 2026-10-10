import Foundation
import Vapor

private struct HealthPayload: Encodable {
    let status: String
    let service: String
}

private struct ProblemPayload: Encodable {
    let type: String
    let title: String
    let status: Int
    let code: String
    let detail: String
    let requestId: String
}

private struct RequestIDKey: StorageKey {
    typealias Value = String
}

struct RequestIDMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        let requestID = Self.validated(request.headers.first(name: "X-Request-Id"))
        request.storage[RequestIDKey.self] = requestID

        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: "X-Request-Id", value: requestID)
        return response
    }

    private static func validated(_ candidate: String?) -> String {
        guard let candidate,
              !candidate.isEmpty,
              candidate.utf8.count <= 128,
              candidate.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) ||
                  (97...122).contains($0) || "._:-".utf8.contains($0)
              }) else {
            return UUID().uuidString.lowercased()
        }
        return candidate
    }
}

func routes(_ app: Application) throws {
    app.get("healthz") { request async throws -> Response in
        try jsonResponse(
            HealthPayload(status: "ok", service: "sync-relay"),
            status: .ok,
            requestID: request.storage[RequestIDKey.self]
        )
    }

    app.get("readyz") { request async throws -> Response in
        try notConfigured(
            requestID: request.storage[RequestIDKey.self],
            detail: "The stateless relay scaffold has no sync backend. Configure a durable, account-authorized backend before serving data."
        )
    }

    app.get("v1", "capabilities") { request async throws -> Response in
        try notConfigured(
            requestID: request.storage[RequestIDKey.self],
            detail: "Capabilities are backend-owned. The relay does not invent provider support or persistence semantics."
        )
    }
}

private func notConfigured(requestID: String?, detail: String) throws -> Response {
    try jsonResponse(
        ProblemPayload(
            type: "https://myrodex.dev/problems/not-configured",
            title: "Relay backend is not configured",
            status: Int(HTTPStatus.serviceUnavailable.code),
            code: "not_configured",
            detail: detail,
            requestId: requestID ?? ""
        ),
        status: .serviceUnavailable,
        requestID: requestID,
        problem: true
    )
}

private func jsonResponse<T: Encodable>(
    _ payload: T,
    status: HTTPStatus,
    requestID: String?,
    problem: Bool = false
) throws -> Response {
    let response = Response(status: status)
    let contentType = problem ? "application/problem+json; charset=utf-8" : "application/json; charset=utf-8"
    response.headers.replaceOrAdd(name: "Content-Type", value: contentType)
    if let requestID {
        response.headers.replaceOrAdd(name: "X-Request-Id", value: requestID)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    response.body = .init(data: try encoder.encode(payload))
    return response
}
