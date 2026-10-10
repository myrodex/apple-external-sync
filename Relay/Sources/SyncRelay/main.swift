import Vapor

@main
struct SyncRelayMain {
    static func main() async throws {
        let environment = try Environment.detect()
        let app = try await Application.make(environment)
        do {
            try configure(app)
            try await app.execute()
        } catch {
            try? await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
