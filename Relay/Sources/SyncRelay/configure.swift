import Vapor

/// Configures the stateless relay shell. Data routes remain unavailable until a real
/// account-authorized backend is implemented and injected; this scaffold has none.
public func configure(_ app: Application) throws {
    app.middleware.use(RequestIDMiddleware())
    try routes(app)
}
