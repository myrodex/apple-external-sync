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
    private let localAccountID: String
    private let providerFactories: [SyncProviderChoice: any SyncProviderConnectionFactory]
    private let selectedScope: SelectedListScope
    private let pendingAuthorizationStore: any OAuthPendingAuthorizationStore
    private let now: @Sendable () -> Date
    private var activeProviderFactory: (any SyncProviderConnectionFactory)?
    private var activeAdapter: (any ExternalSyncAdapter)?

    public init(
        databaseURL: URL? = nil,
        defaults: UserDefaults = .standard,
        providerFactories: [SyncProviderChoice: any SyncProviderConnectionFactory] = [:],
        pendingAuthorizationStore: any OAuthPendingAuthorizationStore = KeychainOAuthPendingAuthorizationStore(),
        now: @escaping @Sendable () -> Date = Date.init
    ) throws {
        let resolvedURL = try databaseURL ?? Self.prepareDefaultDatabaseURL()
        self.stateStore = try SQLiteLocalStore(url: resolvedURL)
        self.eventStore = EventKitStore()
        self.changeSource = EventKitStoreChangeNotifications(eventStore: eventStore.eventStore)
        self.listMapping = InMemoryEventKitListMapping()
        self.defaults = defaults
        let localAccountKey = "eventkit-account-id"
        let localAccountID = defaults.string(forKey: localAccountKey) ?? UUID().uuidString.lowercased()
        defaults.set(localAccountID, forKey: localAccountKey)
        self.localAccountID = localAccountID
        self.providerFactories = providerFactories.isEmpty ? Self.defaultProviderFactories() : providerFactories
        self.pendingAuthorizationStore = pendingAuthorizationStore
        self.now = now
        self.selectedListIDs = []
        self.selectedScope = SelectedListScope()
    }

    deinit { changeTask?.cancel() }

    public func loadSnapshot() async throws -> SyncAppSnapshot {
        try? await pendingAuthorizationStore.removeExpired(at: now())
        let provider = defaults.string(forKey: "provider").flatMap(SyncProviderChoice.init(rawValue:))
        if provider == .appleReminders {
            account = SyncAccount(provider: .eventKit, accountID: localAccountID)
        } else if let provider, let factory = providerFactories[provider] {
            account = factory.account
        } else {
            account = nil
        }
        if let account {
            selectedListIDs = Set(defaults.stringArray(forKey: selectedListKey(for: account)) ?? [])
        } else {
            selectedListIDs = []
        }
        let permission = await eventStore.authorizationStatus()
        let lists = permission.canRead ? try await availableLists() : []
        selectedListIDs = selectedListIDs.intersection(Set(lists.map(\.id)))
        if let account { defaults.set(Array(selectedListIDs).sorted(), forKey: selectedListKey(for: account)) }
        await selectedScope.set(selectedListIDs)
        _ = try? await stateStore.cleanup(asOf: now(), retention: SQLiteLocalStore.defaultRetention)
        let state = if let account {
            try await stateStore.load(account: account)
        } else {
            SyncState()
        }
        snapshot = SyncAppSnapshot(
            connection: connection(for: provider, permission: permission),
            permissions: [
                SyncPermission(kind: .reminders, status: permissionStatus(permission), explanation: "Read and update only the reminder lists you explicitly select."),
                SyncPermission(kind: .notifications, explanation: "Optional alerts for conflicts and failed background sync.")
            ],
            availableLists: lists,
            selectedListIDs: selectedListIDs,
            conflicts: conflictSummaries(state, account: account),
            lastError: nil
        )
        if let account {
            await restoreLatestAudit(for: account)
        }
        if let provider, provider != .appleReminders, let factory = providerFactories[provider] {
            do {
                let connection = try await factory.connect()
                let activated = try await activate(connection, provider: provider, factory: factory)
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
            if activeProviderFactory != nil || account != nil {
                _ = try await disconnect()
            }
            let permission = await eventStore.authorizationStatus()
            guard permission.canRead else {
                snapshot.connection = connection(for: provider, permission: permission)
                return snapshot
            }
            defaults.set(provider.rawValue, forKey: "provider")
            let eventKitAccount = SyncAccount(provider: .eventKit, accountID: localAccountID)
            account = eventKitAccount
            selectedListIDs = Set(defaults.stringArray(forKey: selectedListKey(for: eventKitAccount)) ?? [])
            snapshot.connection = SyncConnectionState(provider: provider, status: .connected, accountName: "This device", detail: "Apple Reminders is connected. Choose lists to sync.")
            snapshot.availableLists = try await availableLists()
            selectedListIDs = selectedListIDs.intersection(Set(snapshot.availableLists.map(\.id)))
            defaults.set(Array(selectedListIDs).sorted(), forKey: selectedListKey(for: eventKitAccount))
            snapshot.selectedListIDs = selectedListIDs
            await selectedScope.set(selectedListIDs)
            observeChanges()
            return snapshot
        case .googleTasks, .microsoftToDo, .customREST:
            guard let factory = providerFactories[provider] else { throw SyncAppCoordinatorError.providerUnavailable(provider.title) }
            if activeProviderFactory != nil || account != nil {
                _ = try await disconnect()
            }
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

    public func beginOAuthAuthorization(provider: SyncProviderChoice) async throws -> SyncOAuthAuthorization {
        guard let factory = providerFactories[provider] else { throw SyncAppCoordinatorError.providerUnavailable(provider.title) }
        let request = try factory.beginOAuthAuthorization()
        let pending = PendingOAuthAuthorization(request: request, expiresAt: now().addingTimeInterval(10 * 60))
        try await pendingAuthorizationStore.save(pending)
        snapshot.connection = SyncConnectionState(provider: provider, status: .connecting, detail: "Complete sign-in in the browser…")
        return SyncOAuthAuthorization(provider: provider, url: request.authorizationURL)
    }

    public func completeOAuthAuthorization(callbackURL: URL) async throws -> SyncAppSnapshot {
        guard let pending = try await pendingAuthorizationStore.load(at: now()),
              let factory = providerFactories[SyncProviderChoice(from: pending.request.provider)] else {
            throw SyncAppCoordinatorError.oauthCallbackInvalid
        }
        let provider = SyncProviderChoice(from: pending.request.provider)
        do {
            let connection = try await factory.completeOAuthAuthorization(callbackURL: callbackURL, request: pending.request)
            if let existingAccount = account, existingAccount != connection.account {
                _ = try await disconnect()
            }
            try await pendingAuthorizationStore.remove()
            let activated = try await activate(connection, provider: provider, factory: factory)
            snapshot.lastError = nil
            return activated
        } catch {
            snapshot.connection = SyncConnectionState(provider: provider, status: Self.connectionStatus(for: error), detail: error.localizedDescription)
            throw error
        }
    }

    public func disconnect() async throws -> SyncAppSnapshot {
        changeTask?.cancel()
        changeTask = nil
        let factory = activeProviderFactory
        let disconnectingAccount = account
        var firstError: Error?
        if let disconnectingAccount {
            do {
                try await stateStore.remove(account: disconnectingAccount)
            } catch {
                firstError = error
            }
        }
        do {
            try await factory?.disconnect()
        } catch {
            firstError = firstError ?? error
        }
        do {
            try await pendingAuthorizationStore.remove()
        } catch {
            firstError = firstError ?? error
        }

        // Keep the active identity/factory when either half fails. A subsequent
        // Disconnect can then retry the failed cleanup instead of losing the only
        // handles needed to revoke credentials or remove state.
        if let firstError {
            let occurredAt = now()
            snapshot.lastError = SyncErrorState(
                phase: .persistence,
                message: firstError.localizedDescription,
                occurredAt: occurredAt,
                recoveryAction: "Retry disconnect to finish removing this account's credentials and sync state."
            )
            throw firstError
        }

        activeProviderFactory = nil
        activeAdapter = nil
        account = nil
        defaults.removeObject(forKey: "provider")
        if let disconnectingAccount { defaults.removeObject(forKey: selectedListKey(for: disconnectingAccount)) }
        snapshot.connection = SyncConnectionState()
        snapshot.availableLists = []
        snapshot.selectedListIDs = []
        snapshot.capabilities = []
        snapshot.warnings = []
        selectedListIDs.removeAll()
        await selectedScope.set([])
        snapshot.lastError = nil
        return snapshot
    }

    public func updateListSelection(_ ids: Set<String>) async throws -> SyncAppSnapshot {
        let available = Set(snapshot.availableLists.map(\.id))
        guard ids.isSubset(of: available) else { throw SyncAppCoordinatorError.invalidSelection }
        selectedListIDs = ids
        if let account { defaults.set(Array(ids).sorted(), forKey: selectedListKey(for: account)) }
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
        snapshot.conflicts = conflictSummaries(state, account: account)
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
        snapshot.conflicts = conflictSummaries(try await engine.currentState(), account: account)
        return snapshot
    }

    private func activate(_ connection: SyncProviderConnection, provider: SyncProviderChoice, factory: any SyncProviderConnectionFactory) async throws -> SyncAppSnapshot {
        guard connection.account == factory.account else {
            throw SyncAppCoordinatorError.providerAccountMismatch(expected: factory.account, actual: connection.account)
        }
        self.account = connection.account
        self.activeProviderFactory = factory
        self.activeAdapter = SelectedListsSyncAdapter(base: connection.adapter, scope: selectedScope)
        defaults.set(provider.rawValue, forKey: "provider")
        snapshot.connection = SyncConnectionState(provider: provider, status: .connected, accountName: connection.displayName ?? connection.account.accountID, detail: "Connected. Choose lists to sync.")
        snapshot.availableLists = connection.lists.filter { !$0.isDeleted }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map { SyncListOption(id: $0.remoteID, name: $0.name, detail: nil, isReadOnly: false) }
        selectedListIDs = Set(defaults.stringArray(forKey: selectedListKey(for: connection.account)) ?? [])
            .intersection(Set(snapshot.availableLists.map(\.id)))
        defaults.set(Array(selectedListIDs).sorted(), forKey: selectedListKey(for: connection.account))
        await selectedScope.set(selectedListIDs)
        snapshot.selectedListIDs = selectedListIDs
        snapshot.capabilities = connection.fieldCapabilities.fields.sorted { $0.key.rawValue < $1.key.rawValue }.map { SyncCapabilitySummary(field: $0.key.rawValue, support: $0.value.rawValue) }
        snapshot.warnings = connection.diagnostics.map { SyncWarningSummary(code: $0.code.rawValue, field: $0.field.rawValue, message: $0.message, resourceID: $0.resourceID) }
        await restoreLatestAudit(for: connection.account)
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

    private func conflictSummaries(_ state: SyncState, account: SyncAccount?) -> [SyncConflictSummary] {
        guard let account else { return [] }
        return state.conflicts.filter { $0.account == account && $0.resolution == .pending }.sorted { $0.createdAt < $1.createdAt }.map {
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
            guard snapshot.connection.isConnected else {
                await recordBackgroundFailure(SyncAppCoordinatorError.notConnected)
                return false
            }
            guard !selectedListIDs.isEmpty else {
                await recordBackgroundFailure(SyncAppCoordinatorError.noListsSelected)
                return false
            }
            let updated = try await syncNow()
            return updated.lastSync?.status.isSuccessfulForBackground == true
        } catch {
            await recordBackgroundFailure(error)
            return false
        }
    }

    public func recordBackgroundSyncError(_ message: String) async {
        await recordBackgroundFailure(NSError(domain: "AppleExternalSync.Background", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))
    }

    private func recordBackgroundFailure(_ error: Error) async {
        let occurredAt = now()
        snapshot.lastError = SyncErrorState(
            phase: .persistence,
            message: error.localizedDescription,
            occurredAt: occurredAt,
            recoveryAction: "Open the app to review sync settings."
        )
        if let auditAccount = account ?? defaults.string(forKey: "provider")
            .flatMap(SyncProviderChoice.init(rawValue:))
            .flatMap({ providerFactories[$0]?.account }) {
            var run = SyncRun(account: auditAccount, startedAt: occurredAt)
            run.finishedAt = occurredAt
            run.status = .failed
            run.errorMessage = error.localizedDescription
            try? await stateStore.upsertSyncRun(run)
        }
    }

    private func restoreLatestAudit(for account: SyncAccount) async {
        guard var run = try? await stateStore.syncRuns(account: account, limit: 1).first else { return }
        if run.status == .running {
            run.status = .failed
            run.finishedAt = now()
            run.errorMessage = "The previous sync stopped before it completed."
            try? await stateStore.upsertSyncRun(run)
        }
        let status: AppSyncRunStatus
        switch run.status {
        case .running: status = .running
        case .succeeded: status = .succeeded
        case .partiallySucceeded: status = .partiallySucceeded
        case .failed: status = .failed
        case .cancelled: status = .cancelled
        }
        snapshot.lastSync = SyncRunSummary(
            id: run.id,
            startedAt: run.startedAt,
            finishedAt: run.finishedAt,
            status: status,
            scannedCount: run.scannedCount,
            createdCount: run.createdCount,
            updatedCount: run.updatedCount,
            deletedCount: run.deletedCount,
            conflictCount: run.conflictCount,
            errorMessage: run.errorMessage
        )
        if run.status == .failed {
            snapshot.lastError = SyncErrorState(
                phase: .persistence,
                message: run.errorMessage ?? "The last background sync failed.",
                occurredAt: run.finishedAt ?? run.startedAt,
                recoveryAction: "Open the app to review sync settings."
            )
        } else {
            snapshot.lastError = nil
        }
    }

    private func selectedListKey(for account: SyncAccount) -> String {
        // UserDefaults keys accept the provider's opaque stable identity directly. Do not
        // normalize punctuation: replacing dots/underscores would make distinct accounts
        // share a selection slot.
        return "selected-list-ids.\(account.provider.rawValue).\(account.accountID)"
    }

    private static func defaultProviderFactories(bundle: Bundle = .main) -> [SyncProviderChoice: any SyncProviderConnectionFactory] {
        let redirectURI = (bundle.object(forInfoDictionaryKey: "ExternalSyncOAuthRedirectURI") as? String) ?? "appleexternalsync://oauth/callback"
        let googleClientID = bundle.object(forInfoDictionaryKey: "ExternalSyncGoogleClientID") as? String
        let googleAccountID = bundle.object(forInfoDictionaryKey: "ExternalSyncGoogleAccountID") as? String
        let microsoftClientID = bundle.object(forInfoDictionaryKey: "ExternalSyncMicrosoftClientID") as? String
        let microsoftAccountID = bundle.object(forInfoDictionaryKey: "ExternalSyncMicrosoftAccountID") as? String
        var result: [SyncProviderChoice: any SyncProviderConnectionFactory] = [:]
        if let googleClientID, let googleAccountID,
           !googleClientID.isEmpty, !googleClientID.contains("$("),
           !googleAccountID.isEmpty, !googleAccountID.contains("$(") {
            result[.googleTasks] = DeviceOAuthConnectionFactory.googleTasks(accountID: googleAccountID, clientID: googleClientID, redirectURI: redirectURI)
        }
        if let microsoftClientID, let microsoftAccountID,
           !microsoftClientID.isEmpty, !microsoftClientID.contains("$("),
           !microsoftAccountID.isEmpty, !microsoftAccountID.contains("$(") {
            result[.microsoftToDo] = DeviceOAuthConnectionFactory.microsoftToDo(accountID: microsoftAccountID, clientID: microsoftClientID, redirectURI: redirectURI)
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
    public init(databaseURL: URL? = nil, defaults: UserDefaults = .standard, providerFactories: [SyncProviderChoice: any SyncProviderConnectionFactory] = [:], pendingAuthorizationStore: any OAuthPendingAuthorizationStore = KeychainOAuthPendingAuthorizationStore(), now: @escaping @Sendable () -> Date = Date.init) throws {
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
    public func recordBackgroundSyncError(_ message: String) async {}
    public func runBackgroundSync() async -> Bool { false }
}
#endif


private extension SyncProviderChoice {
    init(from provider: SyncProvider) {
        switch provider {
        case .googleTasks: self = .googleTasks
        case .microsoftGraph: self = .microsoftToDo
        case .genericREST: self = .customREST
        case .eventKit: self = .appleReminders
        }
    }
}
