import Combine
import Foundation

@MainActor
public final class SyncAppViewModel: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case loading
        case onboarding
        case connectionSetup
        case listSelection
        case ready
        case syncing
        case failed
    }

    @Published public private(set) var phase: Phase = .loading
    @Published public private(set) var snapshot = SyncAppSnapshot()
    @Published public private(set) var isUpdating = false
    @Published public private(set) var operationError: SyncErrorState?
    @Published public private(set) var loginItemError: String?
    @Published public private(set) var automaticSyncEnabled: Bool

    private let coordinator: any SyncAppCoordinator
    private let loginItemManager: any LoginItemManaging
    private var loadTask: Task<Void, Never>?

    public init(
        coordinator: any SyncAppCoordinator,
        loginItemManager: any LoginItemManaging = LoginItemManagerFactory.makeDefault(),
        initialSnapshot: SyncAppSnapshot? = nil
    ) {
        self.coordinator = coordinator
        self.loginItemManager = loginItemManager
        self.snapshot = initialSnapshot ?? SyncAppSnapshot()
        self.phase = initialSnapshot.map(Self.phase(for:)) ?? .loading
        self.automaticSyncEnabled = loginItemManager.isEnabled
    }

    deinit {
        loadTask?.cancel()
    }

    public func start() {
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            await self?.loadSnapshot()
        }
    }

    public func loadSnapshot() async {
        guard !isUpdating else { return }
        isUpdating = true
        defer { isUpdating = false }
        do {
            let loaded = try await coordinator.loadSnapshot()
            apply(loaded)
        } catch {
            fail(error, phase: .loading)
        }
    }

    public func requestPermissions() {
        perform(.onboarding) { coordinator in
            try await coordinator.requestPermissions()
        }
    }

    public func connect(provider: SyncProviderChoice) {
        perform(.connectionSetup) { coordinator in
            try await coordinator.connect(provider: provider)
        }
    }

    public func disconnect() {
        perform(.connectionSetup) { coordinator in
            try await coordinator.disconnect()
        }
    }

    public func setListSelected(_ selected: Bool, listID: String) {
        var selection = snapshot.selectedListIDs
        if selected {
            selection.insert(listID)
        } else {
            selection.remove(listID)
        }
        phase = .listSelection
        let selectedIDs = selection
        perform(.listSelection) { coordinator in
            try await coordinator.updateListSelection(selectedIDs)
        }
    }

    public func showListSelection() {
        phase = .listSelection
    }

    public func syncNow() {
        guard snapshot.connection.isConnected else {
            operationError = SyncErrorState(
                phase: .connection,
                message: SyncAppCoordinatorError.notConnected.localizedDescription,
                recoveryAction: "Connect an account and try again."
            )
            phase = .connectionSetup
            return
        }
        guard snapshot.hasSelectedLists else {
            operationError = SyncErrorState(
                phase: .listSelection,
                message: SyncAppCoordinatorError.noListsSelected.localizedDescription,
                recoveryAction: "Choose at least one list and try again."
            )
            phase = .listSelection
            return
        }
        perform(.syncing) { coordinator in
            try await coordinator.syncNow()
        }
    }

    public func resolveConflict(id: String, resolution: SyncConflictResolution) {
        perform(phase) { coordinator in
            try await coordinator.resolveConflict(id: id, resolution: resolution)
        }
    }

    public func setAutomaticSyncEnabled(_ enabled: Bool) {
        loginItemError = nil
        do {
            try loginItemManager.setEnabled(enabled)
            automaticSyncEnabled = loginItemManager.isEnabled
        } catch {
            loginItemError = error.localizedDescription
            automaticSyncEnabled = loginItemManager.isEnabled
        }
    }

    private func perform(
        _ inFlightPhase: Phase,
        operation: @escaping @Sendable (any SyncAppCoordinator) async throws -> SyncAppSnapshot
    ) {
        guard !isUpdating else { return }
        isUpdating = true
        phase = inFlightPhase
        operationError = nil
        let operationPhase = inFlightPhase
        Task { [weak self] in
            guard let self else { return }
            do {
                let updated = try await operation(self.coordinator)
                apply(updated)
            } catch is CancellationError {
                // A cancelled view task is not a user-visible sync failure.
            } catch {
                fail(error, phase: operationPhase)
            }
            isUpdating = false
        }
    }

    private static func phase(for snapshot: SyncAppSnapshot) -> Phase {
        if !snapshot.hasRequiredPermissions { return .onboarding }
        if !snapshot.connection.isConnected { return .connectionSetup }
        if !snapshot.hasSelectedLists { return .listSelection }
        if snapshot.lastError != nil { return .failed }
        if snapshot.lastSync?.status == .running { return .syncing }
        return .ready
    }

    private func apply(_ newSnapshot: SyncAppSnapshot) {
        snapshot = newSnapshot
        operationError = newSnapshot.lastError
        phase = Self.phase(for: newSnapshot)
    }

    private func fail(_ error: Error, phase failurePhase: Phase) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let errorState = SyncErrorState(
            phase: failurePhase.errorPhase,
            message: message,
            recoveryAction: recoveryAction(for: failurePhase)
        )
        operationError = errorState
        snapshot.lastError = errorState
        phase = .failed
    }

    private func recoveryAction(for phase: Phase) -> String? {
        switch phase {
        case .onboarding: return "Allow access in Settings, then try again."
        case .connectionSetup: return "Check the account and try connecting again."
        case .listSelection: return "Refresh the lists and choose at least one."
        case .syncing: return "Check the provider connection and try again."
        default: return "Try again."
        }
    }
}

private extension SyncAppViewModel.Phase {
    var errorPhase: SyncErrorPhase {
        switch self {
        case .onboarding: return .permissions
        case .connectionSetup: return .connection
        case .listSelection: return .listSelection
        case .syncing, .ready: return .push
        case .loading, .failed: return .unknown
        }
    }
}
