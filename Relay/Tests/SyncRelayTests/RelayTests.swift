import Vapor
import VaporTesting
import Testing
@testable import SyncRelay

@Suite("Sync relay")
struct RelayTests {
    private func withApp(_ body: (Application) async throws -> Void) async throws {
        let app = try await Application.make(.testing)
        do {
            try configure(app)
            try await body(app)
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }

    @Test("health is live and returns the same bounded correlation ID in body headers are absent")
    func healthWithoutClientRequestID() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "healthz", afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Request-Id")?.isEmpty == false)
                #expect(response.headers.first(name: "Content-Type") == "application/json; charset=utf-8")
                #expect(response.body.string.contains("\"status\":\"ok\""))
            })
        }
    }

    @Test("health echoes a valid caller correlation ID")
    func healthWithClientRequestID() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "healthz", headers: ["X-Request-Id": "req-test_1:2"], afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Request-Id") == "req-test_1:2")
            })
        }
    }

    @Test("health replaces invalid correlation IDs")
    func healthWithInvalidRequestID() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "healthz", headers: ["X-Request-Id": "<script>secret"], afterResponse: { response async throws in
                #expect(response.status == .ok)
                #expect(response.headers.first(name: "X-Request-Id") != "<script>secret")
                #expect(response.headers.first(name: "X-Request-Id")?.utf8.count ?? 129 <= 128)
            })
        }
    }

    @Test("readiness refuses to claim a backend that has not been implemented")
    func readiness() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "readyz", headers: ["X-Request-Id": "req-ready"], afterResponse: { response async throws in
                #expect(response.status == .serviceUnavailable)
                #expect(response.headers.first(name: "X-Request-Id") == "req-ready")
                #expect(response.headers.first(name: "Content-Type") == "application/problem+json; charset=utf-8")
                #expect(response.body.string.contains("\"code\":\"not_configured\""))
                #expect(response.body.string.contains("\"requestId\":\"req-ready\""))
            })
        }
    }

    @Test("capabilities does not invent provider support")
    func capabilitiesWithoutBackend() async throws {
        try await withApp { app in
            try await app.testing().test(.GET, "v1/capabilities", afterResponse: { response async throws in
                #expect(response.status == .serviceUnavailable)
                #expect(response.body.string.contains("\"code\":\"not_configured\""))
            })
        }
    }
}
