import Foundation
import SyncAdapters
import SyncContracts
import SyncDomain
import SyncEngine
import SyncStore

/// Composition boundary for platform applications. The app owns provider login and
/// injects a device-local adapter; the sync algorithm and persistence remain shared.
public struct SyncRuntimeConfiguration: Sendable {
    public let databaseURL: URL?
    public let engine: SyncEngineConfiguration

    public init(databaseURL: URL? = nil, engine: SyncEngineConfiguration = SyncEngineConfiguration()) {
        self.databaseURL = databaseURL
        self.engine = engine
    }
}

public enum SyncRuntimeError: Error, LocalizedError, Sendable {
    case missingDatabase

    public var errorDescription: String? {
        switch self {
        case .missingDatabase: return "A durable SQLite database URL is required for a production runtime."
        }
    }
}

/// Creates an engine from injected account/provider components. There is no hidden
/// provider singleton, network login, or in-memory production fallback.
public enum SyncRuntime {
    public static func makeEngine(
        account: SyncAccount,
        adapter: any ExternalSyncAdapter,
        configuration: SyncRuntimeConfiguration,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) throws -> SyncEngine {
        guard let databaseURL = configuration.databaseURL else { throw SyncRuntimeError.missingDatabase }
        let store = try SQLiteLocalStore(url: databaseURL)
        return SyncEngine(account: account, adapter: adapter, stateStore: store, configuration: configuration.engine, now: clock)
    }

    public static func makeInMemoryEngine(
        account: SyncAccount,
        adapter: any ExternalSyncAdapter,
        configuration: SyncRuntimeConfiguration = SyncRuntimeConfiguration(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) -> SyncEngine {
        SyncEngine(account: account, adapter: adapter, stateStore: InMemorySyncStateStore(), configuration: configuration.engine, now: clock)
    }
}
