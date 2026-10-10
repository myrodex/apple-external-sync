import Foundation
import SyncAdapters
import SyncAppSupport
import SyncContracts
import SyncDomain
import SyncEngine
import SyncStore

#if canImport(EventKit)
@preconcurrency import EventKit
#endif

/// Device coordinator used by the application targets. Apple Reminders is fully
/// wired through EventKit; OAuth providers are surfaced in the same connection UI
/// and fail explicitly until the app target supplies public client configuration.
#if canImport(EventKit)
@MainActor
public final class ProductionSyncCoordinator: SyncAppCoordinator, SyncAppLifecycleHandling, @unchecked Sendable {
    private let stateStore: SQLiteLocalStore
    private let eventStore: EventKitStore
    private let changeSource: EventKitStoreChangeNotifications
    private let listMapping: InMemoryEventKitListMapping
    private var snapshot = SyncAppSnapshot()
    private var account: SyncAccount?
    private var selectedListIDs: Set<String> = []
    private var changeTask: Task<Void, Never>?
    private let defaults: UserDefaults
    private let providerFactories: [SyncProviderChoice: any SyncProviderConnectionFactory]
    private let selectedScope: SelectedListScope
    private var activeProviderFactory: (any SyncProviderConnectionFactory)?
    private var activeAdapter: (any ExternalSyncAdapter)?

    public init(
        databaseURL: URL? = nil,
        defaults: UserDefaults = .standard,
        providerFactories: [SyncProviderChoice: any SyncProviderConnectionFactory] = [:]
    ) throws {
        let resolvedURL = try databaseURL ?? Self.prepareDefaultDatabaseURL()
        self.stateStore = try SQLiteLocalStore(url: resolvedURL)
        self.eventStore = EventKitStore()
        self.changeSource = EventKitStoreChangeNotifications(eventStore: eventStore.eventStore)
        self.listMapping = InMemoryEventKitListMapping()
        self.defaults = defaults
        self.providerFactories = providerFactories.isEmpty ? Self.defaultProviderFactories() : providerFactories
        self.selectedListIDs = Set(defaults.stringArray(forKey: "selected-list-ids") ?? [])
        self.selectedScope = SelectedListScope(selectedRemoteListIDs: self.selectedListIDs)
    }

    deinit { changeTask?.cancel() }

    public func loadSnapshot() async throws -> SyncAppSnapshot {
        let provider = defaults.string(forKey: "provider").flatMap(SyncProviderChoice.init(rawValue:))
        if provider == .appleReminders {
            account = SyncAccount(provider: .eventKit, accountID: "device")
        }
        let permission = await eventStore.authorizationStatus()
        let lists = permission.canRead ? try await availableLists() : []
        selectedListIDs = selectedListIDs.intersection(Set(lists.map(\.id)))
        defaults.set(Array(selectedListIDs).sorted(), forKey: "selected-list-ids")
        await selectedScope.set(selectedListIDs)
        let state = try await stateStore.load()
        snapshot = SyncAppSnapshot(
            connection: connection(for: provider, permission: permission),
            permissions: [
                SyncPermission(kind: .reminders, status: permissionStatus(permission), explanation: "Read and update only the reminder lists you explicitly select."),
                SyncPermission(kind: .notifications, explanation: "Optional alerts for conflicts and failed background sync.")
            ],
            availableLists: lists,
            selectedListIDs: selectedListIDs,
            conflicts: conflictSummaries(state),
            lastError: nil
        )
        if let provider, provider != .appleReminders, let factory = providerFactories[provider] {
            do {
                let connection = try await factory.connect()
                let activated = try await activate(connection, provider: provider, factory: factory)
                snapshot.lastError = nil
                return activated
            } catch {
                snapshot.connection = SyncConnectionState(provider: provider, status: Self.connectionStatus(for: error), detail: error.localizedDescription)
            }
        }
        if snapshot.connection.isConnected { observeChanges() }
        return snapshot
    }

    public func requestPermissions() async throws -> SyncAppSnapshot {
        guard try await eventStore.requestFullAccess() else {
            throw SyncAdapterError.authenticationRequired
        }
        return try await loadSnapshot()
    }

    public func connect(provider: SyncProviderChoice) async throws -> SyncAppSnapshot {
        switch provider {
        case .appleReminders:
            let permission = await eventStore.authorizationStatus()
            guard permission.canRead else {
                snapshot.connection = connection(for: provider, permission: permission)
                return snapshot
            }
            defaults.set(provider.rawValue, forKey: "provider")
            account = SyncAccount(provider: .eventKit, accountID: "device")
            snapshot.connection = SyncConnectionState(provider: provider, status: .connected, accountName: "This device", detail: "Apple Reminders is connected. Choose lists to sync.")
            snapshot.availableLists = try await availableLists()
            selectedListIDs = selectedListIDs.intersection(Set(snapshot.availableLists.map(\.id)))
            snapshot.selectedListIDs = selectedListIDs
            await selectedScope.set(selectedListIDs)
            observeChanges()
            return snapshot
        case .googleTasks, .microsoftToDo, .customREST:
            guard let factory = providerFactories[provider] else { throw SyncAppCoordinatorError.providerUnavailable(provider.title) }
            do {
                let connection = try await factory.connect()
                let activated = try await activate(connection, provider: provider, factory: factory)
                snapshot.lastError = nil
                return activated
            } catch {
                snapshot.connection = SyncConnectionState(provider: provider, status: Self.connectionStatus(for: error), detail: error.localizedDescription)
                throw error
            }
        }
    }

    private var pendingOAuth: (provider: SyncProviderChoice, request: OAuthAuthorizationRequest)?

    public func beginOAuthAuthorization(provider: SyncProviderChoice) async throws -> SyncOAuthAuthorization {
        guard let factory = providerFactories[provider] else { throw SyncAppCoordinatorError.providerUnavailable(provider.title) }
        let request = try factory.beginOAuthAuthorization()
        pendingOAuth = (provider, request)
        snapshot.connection = SyncConnectionState(provider: provider, status: .connecting, detail: "Complete sign-in in the browser…")
        return SyncOAuthAuthorization(provider: provider, url: request.authorizationURL)
    }

    public func completeOAuthAuthorization(callbackURL: URL) async throws -> SyncAppSnapshot {
        guard let pendingOAuth, let factory = providerFactories[pendingOAuth.provider] else {
            throw SyncAppCoordinatorError.oauthCallbackInvalid
        }
        do {
            let connection = try await factory.completeOAuthAuthorization(callbackURL: callbackURL, request: pendingOAuth.request)
            self.pendingOAuth = nil
            let activated = try await activate(connection, provider: pendingOAuth.provider, factory: factory)
            snapshot.lastError = nil
            return activated
        } catch {
            self.pendingOAuth = nil
            snapshot.connection = SyncConnectionState(provider: pendingOAuth.provider, status: Self.connectionStatus(for: error), detail: error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async throws -> SyncAppSnapshot {
        changeTask?.cancel()
        changeTask = nil
        let factory = activeProviderFactory
        activeProviderFactory = nil
        activeAdapter = nil
        account = nil
        defaults.removeObject(forKey: "provider")
        snapshot.connection = SyncConnectionState()
        snapshot.availableLists = []
        snapshot.selectedListIDs = []
        snapshot.capabilities = []
        snapshot.warnings = []
        selectedListIDs.removeAll()
        await selectedScope.set([])
        try await factory?.disconnect()
        return snapshot
    }

    public func updateListSelection(_ ids: Set<String>) async throws -> SyncAppSnapshot {
        let available = Set(snapshot.availableLists.map(\.id))
        guard ids.isSubset(of: available) else { throw SyncAppCoordinatorError.invalidSelection }
        selectedListIDs = ids
        defaults.set(Array(ids).sorted(), forKey: "selected-list-ids")
        snapshot.selectedListIDs = ids
        await selectedScope.set(ids)
        return snapshot
    }

    public func applyLocalChange(_ change: LocalChange) async throws -> SyncAppSnapshot {
        guard snapshot.connection.isConnected, let account else { throw SyncAppCoordinatorError.notConnected }
        let adapter: any ExternalSyncAdapter
        if account.provider == .eventKit {
            adapter = EventKitRemindersAdapter(
                account: account,
                store: eventStore,
                selection: ExplicitEventKitListSelection(selectedListIDs: selectedListIDs),
                mapping: listMapping,
                changeSource: changeSource
            )
        } else if let activeAdapter {
            adapter = activeAdapter
        } else {
            throw SyncAppCoordinatorError.notConnected
        }
        let engine = SyncEngine(account: account, adapter: adapter, stateStore: stateStore)
        try await engine.applyLocalChange(change)
        snapshot.lastError = nil
        return snapshot
    }

    public func syncNow() async throws -> SyncAppSnapshot {
        guard snapshot.connection.isConnected, let account else { throw SyncAppCoordinatorError.notConnected }
        guard !selectedListIDs.isEmpty else { throw SyncAppCoordinatorError.noListsSelected }
        let adapter: any ExternalSyncAdapter
        if account.provider == .eventKit {
            let eventKitAdapter = EventKitRemindersAdapter(
                account: account,
                store: eventStore,
                selection: AllEventKitListsSelection(),
                mapping: listMapping,
                changeSource: changeSource
            )
            adapter = SelectedListsSyncAdapter(base: eventKitAdapter, scope: selectedScope)
        } else if let activeAdapter {
            adapter = activeAdapter
        } else {
            throw SyncAppCoordinatorError.notConnected
        }
        let engine = SyncEngine(account: account, adapter: adapter, stateStore: stateStore)
        let report = try await engine.sync()
        let state = try await engine.currentState()
        snapshot.lastSync = SyncRunSummary(
            startedAt: report.startedAt,
            finishedAt: report.finishedAt,
            status: report.rejectedCount == 0 && report.conflictCount == 0 ? .succeeded : .partiallySucceeded,
            scannedCount: report.pulledCount,
            createdCount: report.createdCount,
            updatedCount: report.updatedCount,
            deletedCount: report.deletedCount,
            conflictCount: report.conflictCount,
            errorMessage: report.rejectedCount == 0 ? nil : "Some provider writes were rejected and will be retried."
        )
        snapshot.conflicts = conflictSummaries(state)
        snapshot.warnings = report.diagnostics.map { SyncWarningSummary(code: $0.code.rawValue, field: $0.field.rawValue, message: $0.message, resourceID: $0.resourceID) }
        return snapshot
    }

    public func resolveConflict(id: String, resolution: SyncConflictResolution) async throws -> SyncAppSnapshot {
        guard let conflictID = SyncID(string: id), let account else { throw SyncAppCoordinatorError.conflictNotFound }
        let adapter: any ExternalSyncAdapter
        if account.provider == .eventKit {
            let eventKitAdapter = EventKitRemindersAdapter(account: account, store: eventStore, selection: AllEventKitListsSelection(), mapping: listMapping, changeSource: changeSource)
            adapter = SelectedListsSyncAdapter(base: eventKitAdapter, scope: selectedScope)
        } else if let activeAdapter {
            adapter = activeAdapter
        } else {
            throw SyncAppCoordinatorError.notConnected
        }
        let engine = SyncEngine(account: account, adapter: adapter, stateStore: stateStore)
        let domainResolution: ConflictResolution = switch resolution {
        case .keepLocal: .localWon
        case .keepRemote: .remoteWon
        case .dismiss: .dismissed
        }
        try await engine.resolveConflict(id: conflictID, resolution: domainResolution)
        snapshot.conflicts = conflictSummaries(try await stateStore.load())
        return snapshot
    }

    private func activate(_ connection: SyncProviderConnection, provider: SyncProviderChoice, factory: any SyncProviderConnectionFactory) async throws -> SyncAppSnapshot {
        self.account = connection.account
        self.activeProviderFactory = factory
        self.activeAdapter = SelectedListsSyncAdapter(base: connection.adapter, scope: selectedScope)
        defaults.set(provider.rawValue, forKey: "provider")
        snapshot.connection = SyncConnectionState(provider: provider, status: .connected, accountName: connection.displayName ?? connection.account.accountID, detail: "Connected. Choose lists to sync.")
        snapshot.availableLists = connection.lists.filter { !$0.isDeleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { SyncListOption(id: $0.remoteID, name: $0.name, detail: nil, isReadOnly: false) }
        selectedListIDs = selectedListIDs.intersection(Set(snapshot.availableLists.map(\.id)))
        await selectedScope.set(selectedListIDs)
        snapshot.selectedListIDs = selectedListIDs
        snapshot.capabilities = connection.fieldCapabilities.fields.sorted { $0.key.rawValue < $1.key.rawValue }.map { SyncCapabilitySummary(field: $0.key.rawValue, support: $0.value.rawValue) }
        snapshot.warnings = connection.diagnostics.map { SyncWarningSummary(code: $0.code.rawValue, field: $0.field.rawValue, message: $0.message, resourceID: $0.resourceID) }
        return snapshot
    }

    private static func connectionStatus(for error: Error) -> SyncConnectionStatus {
        if let adapterError = error as? SyncAdapterError, adapterError == .authenticationRequired { return .authenticationRequired }
        if error is OAuthError { return .authenticationRequired }
        return .failed
    }

    private func availableLists() async throws -> [SyncListOption] {
        try await eventStore.fetchLists().sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
            SyncListOption(id: $0.id, name: $0.name, detail: $0.isDefault ? "Default list" : nil, isReadOnly: $0.isReadOnly)
        }
    }

    private func connection(for provider: SyncProviderChoice?, permission: EventKitRemindersAuthorizationStatus) -> SyncConnectionState {
        guard let provider else { return SyncConnectionState() }
        guard provider == .appleReminders else { return SyncConnectionState(provider: provider, status: .authenticationRequired, detail: "Complete device-only OAuth setup to connect this provider.") }
        if permission.canRead { return SyncConnectionState(provider: provider, status: .connected, accountName: "This device", detail: "Apple Reminders is connected.") }
        if permission == .notDetermined { return SyncConnectionState(provider: provider, status: .authenticationRequired, detail: "Allow Reminders access to continue.") }
        return SyncConnectionState(provider: provider, status: .failed, detail: "Reminders access is denied or restricted.")
    }

    private func permissionStatus(_ status: EventKitRemindersAuthorizationStatus) -> SyncPermissionStatus {
        if status.canRead { return .granted }
        switch status {
        case .notDetermined: return .notRequested
        case .restricted: return .restricted
        default: return .denied
        }
    }

    private func conflictSummaries(_ state: SyncState) -> [SyncConflictSummary] {
        state.conflicts.filter { $0.resolution == .pending }.sorted { $0.createdAt < $1.createdAt }.map {
            SyncConflictSummary(id: $0.id.description, title: $0.localTask?.title ?? $0.remoteTask?.title ?? $0.localList?.name ?? $0.remoteList?.name ?? "Sync conflict", fields: $0.fields.map(\.rawValue), detectedAt: $0.createdAt)
        }
    }

    private func observeChanges() {
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.changeSource.events() {
                guard !Task.isCancelled else { return }
                guard self.snapshot.connection.isConnected, !self.selectedListIDs.isEmpty else { continue }
                _ = try? await self.syncNow()
            }
        }
    }

    /// Re-read permission/list state when the scene returns to the foreground, then
    /// run one ordinary engine sync. The engine remains the only owner of persistence
    /// and merge behavior.
    public func applicationWillEnterForeground() async {
        _ = try? await loadSnapshot()
        guard snapshot.connection.isConnected, !selectedListIDs.isEmpty else { return }
        _ = try? await syncNow()
    }

    /// EventKit notifications are intentionally not retained while suspended. The
    /// next foreground/background run performs a fresh selected-list pull.
    public func applicationDidEnterBackground() {
        changeTask?.cancel()
        changeTask = nil
    }

    /// Background task entry point. A new process restores persisted provider/list
    /// choices before running the exact same engine path as the foreground action.
    public func runBackgroundSync() async -> Bool {
        do {
            _ = try await loadSnapshot()
            guard snapshot.connection.isConnected, !selectedListIDs.isEmpty else { return false }
            _ = try await syncNow()
            return true
        } catch {
            snapshot.lastError = SyncErrorState(
                phase: .persistence,
                message: error.localizedDescription,
                recoveryAction: "Open the app to review sync settings."
            )
            return false
        }
    }

    private static func defaultProviderFactories(bundle: Bundle = .main) -> [SyncProviderChoice: any SyncProviderConnectionFactory] {
        let redirectURI = (bundle.object(forInfoDictionaryKey: "ExternalSyncOAuthRedirectURI") as? String) ?? "appleexternalsync://oauth/callback"
        let googleClientID = bundle.object(forInfoDictionaryKey: "ExternalSyncGoogleClientID") as? String
        let microsoftClientID = bundle.object(forInfoDictionaryKey: "ExternalSyncMicrosoftClientID") as? String
        var result: [SyncProviderChoice: any SyncProviderConnectionFactory] = [:]
        if let googleClientID, !googleClientID.isEmpty, !googleClientID.contains("$(") {
            result[.googleTasks] = DeviceOAuthConnectionFactory.googleTasks(accountID: "device", clientID: googleClientID, redirectURI: redirectURI)
        }
        if let microsoftClientID, !microsoftClientID.isEmpty, !microsoftClientID.contains("$(") {
            result[.microsoftToDo] = DeviceOAuthConnectionFactory.microsoftToDo(accountID: "device", clientID: microsoftClientID, redirectURI: redirectURI)
        }
        if let json = bundle.object(forInfoDictionaryKey: "ExternalSyncRESTConfiguration") as? String,
           !json.isEmpty,
           !json.contains("$(") {
            do {
                let settings = try GenericRESTConnectionSettings(jsonData: Data(json.utf8))
                result[.customREST] = GenericRESTConnectionFactory(settings: settings)
            } catch {
                // Leave custom REST unavailable rather than silently falling back to
                // fixed paths or an unconfigured token source.
            }
        }
        return result
    }


    public static func prepareDefaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let url = defaultDatabaseURL(fileManager: fileManager)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    public static func defaultDatabaseURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? fileManager.temporaryDirectory
        return base.appendingPathComponent("AppleExternalSync", isDirectory: true).appendingPathComponent("sync.sqlite")
    }
}
#else
public struct ProductionSyncCoordinator: SyncAppCoordinator, Sendable {
    private let message: String
    public init(databaseURL: URL? = nil, defaults: UserDefaults = .standard, providerFactories: [SyncProviderChoice: any SyncProviderConnectionFactory] = [:]) throws {
        self.message = "EventKit is unavailable on this platform."
    }
    public func loadSnapshot() async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func requestPermissions() async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func connect(provider: SyncProviderChoice) async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func beginOAuthAuthorization(provider: SyncProviderChoice) async throws -> SyncOAuthAuthorization { throw SyncAdapterError.unavailable(message) }
    public func completeOAuthAuthorization(callbackURL: URL) async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func disconnect() async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func updateListSelection(_ selectedListIDs: Set<String>) async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func applyLocalChange(_ change: LocalChange) async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func syncNow() async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func resolveConflict(id: String, resolution: SyncConflictResolution) async throws -> SyncAppSnapshot { throw SyncAdapterError.unavailable(message) }
    public func applicationWillEnterForeground() async {}
    public func applicationDidEnterBackground() {}
    public func runBackgroundSync() async -> Bool { false }
}
#endif
