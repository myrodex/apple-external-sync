#if canImport(SwiftUI)
import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

public struct SyncAppRootView: View {
    @StateObject private var model: SyncAppViewModel
    private let providers: [SyncProviderChoice]

    public init(
        model: @autoclosure @escaping () -> SyncAppViewModel,
        providers: [SyncProviderChoice] = SyncProviderChoice.allCases
    ) {
        _model = StateObject(wrappedValue: model())
        self.providers = providers
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .loading:
                ProgressView("Loading sync settings…")
            case .onboarding:
                SyncOnboardingView(model: model)
            case .connectionSetup:
                ConnectionSetupView(model: model, providers: providers)
            case .listSelection:
                ListSelectionView(model: model)
            case .syncing, .ready, .failed:
                SyncDashboardView(model: model)
            }
        }
        .task { model.start() }
    }
}

public struct SyncOnboardingView: View {
    @ObservedObject private var model: SyncAppViewModel

    public init(model: SyncAppViewModel) {
        self.model = model
    }

    public var body: some View {
        SyncPage(title: "Set up sync", subtitle: "Choose which Apple data this app may access.") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(model.snapshot.permissions) { permission in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: permission.kind.systemImage)
                            .frame(width: 24)
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.kind.title).font(.headline)
                            Text(permission.explanation).font(.subheadline).foregroundStyle(.secondary)
                            Text(permission.kind.isRequiredForSync ? permission.status.title : "Optional · \(permission.status.title)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(permission.status.isGranted ? .green : .orange)
                        }
                        Spacer()
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    model.requestPermissions()
                } label: {
                    Label("Allow access", systemImage: "checkmark.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUpdating)
            }
        }
    }
}

public struct ConnectionSetupView: View {
    @ObservedObject private var model: SyncAppViewModel
    private let providers: [SyncProviderChoice]
    @State private var provider: SyncProviderChoice

    public init(model: SyncAppViewModel, providers: [SyncProviderChoice]) {
        self.model = model
        self.providers = providers
        _provider = State(initialValue: providers.first ?? .appleReminders)
    }

    public var body: some View {
        SyncPage(title: "Connect an account", subtitle: "Sync only the provider you explicitly choose.") {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Provider", selection: $provider) {
                    ForEach(providers) { option in
                        Label(option.title, systemImage: option.systemImage).tag(option)
                    }
                }
                .pickerStyle(.menu)

                if let detail = model.snapshot.connection.detail {
                    Text(detail).font(.subheadline).foregroundStyle(.secondary)
                }

                Button {
                    if provider == .appleReminders || provider == .customREST {
                        model.connect(provider: provider)
                    } else {
                        model.beginOAuthAuthorization(provider: provider)
                    }
                } label: {
                    Label((provider == .appleReminders || provider == .customREST) ? "Connect" : "Sign in with \(provider.title)", systemImage: (provider == .appleReminders || provider == .customREST) ? "link.badge.plus" : "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUpdating)
                .onReceive(model.$authorizationRequest.compactMap { $0 }) { request in
                    #if canImport(UIKit)
                    UIApplication.shared.open(request.url)
                    #elseif canImport(AppKit)
                    NSWorkspace.shared.open(request.url)
                    #endif
                    _ = model.consumeAuthorizationRequest()
                }
            }
        }
    }
}

public struct ListSelectionView: View {
    @ObservedObject private var model: SyncAppViewModel

    public init(model: SyncAppViewModel) {
        self.model = model
    }

    public var body: some View {
        SyncPage(title: "Choose lists", subtitle: "Nothing syncs until you select it.") {
            VStack(alignment: .leading, spacing: 12) {
                if model.snapshot.availableLists.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "list.bullet.rectangle")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("No lists available").font(.headline)
                        Text("Reconnect to refresh provider lists.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(model.snapshot.availableLists) { list in
                        Button {
                            model.setListSelected(!model.snapshot.selectedListIDs.contains(list.id), listID: list.id)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: model.snapshot.selectedListIDs.contains(list.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(model.snapshot.selectedListIDs.contains(list.id) ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(list.name).foregroundStyle(.primary)
                                    if let detail = list.detail {
                                        Text(detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                if list.isReadOnly {
                                    Text("Read-only").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(list.isReadOnly || model.isUpdating)
                        Divider()
                    }
                }

                if !model.snapshot.hasSelectedLists {
                    Label("Select at least one list to continue.", systemImage: "info.circle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                }

                Button {
                    model.syncNow()
                } label: {
                    Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isUpdating || !model.snapshot.hasSelectedLists)
            }
        }
    }
}

public struct SyncDashboardView: View {
    @ObservedObject private var model: SyncAppViewModel
    @State private var showingSettings = false

    public init(model: SyncAppViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            SyncPage(title: "External sync", subtitle: model.snapshot.connection.accountName ?? "Keep selected lists in sync.") {
                VStack(alignment: .leading, spacing: 16) {
                    connectionCard
                    syncStatusCard
                    if !model.snapshot.conflicts.isEmpty {
                        conflictsCard
                    }
                    if !model.snapshot.warnings.isEmpty {
                        warningsCard
                    }
                    if !model.snapshot.capabilities.isEmpty {
                        capabilitiesCard
                    }
                    if let error = model.operationError {
                        errorCard(error)
                    }
                    listSummary
                    Button {
                        model.syncNow()
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isUpdating)
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button { showingSettings = true } label: { Image(systemName: "gear") }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SyncSettingsView(model: model)
            }
        }
    }

    private var connectionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: model.snapshot.connection.status == .connected ? "checkmark.circle.fill" : "person.crop.circle.badge.exclamationmark")
                .foregroundStyle(model.snapshot.connection.status == .connected ? .green : .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.snapshot.connection.status.title).font(.headline)
                if let provider = model.snapshot.connection.provider {
                    Text(provider.title).font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Disconnect") { model.disconnect() }
                .buttonStyle(.bordered)
                .disabled(model.isUpdating || !model.snapshot.connection.isConnected)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var syncStatusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(model.snapshot.lastSync?.status.title ?? "Not synced yet")
            } icon: {
                Image(systemName: model.snapshot.lastSync?.status.systemImage ?? "clock")
                    .foregroundStyle(model.snapshot.lastSync?.status == .failed ? Color.red : Color.accentColor)
            }
            if let lastSync = model.snapshot.lastSync {
                Text(lastSync.finishedAt ?? lastSync.startedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(lastSync.changedCount) changes · \(lastSync.conflictCount) conflicts")
                    .font(.subheadline)
            } else {
                Text("Start a manual sync when you are ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var conflictsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Conflicts need your decision", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(model.snapshot.conflicts) { conflict in
                VStack(alignment: .leading, spacing: 7) {
                    Text(conflict.title).font(.subheadline.weight(.semibold))
                    if let listName = conflict.listName {
                        Text(listName).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(conflict.fields.joined(separator: ", "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Menu("Resolve") {
                        Button("Keep local") { model.resolveConflict(id: conflict.id, resolution: .keepLocal) }
                        Button("Keep remote") { model.resolveConflict(id: conflict.id, resolution: .keepRemote) }
                        Divider()
                        Button("Dismiss", role: .destructive) { model.resolveConflict(id: conflict.id, resolution: .dismiss) }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 4)
            }
        }
        .padding()
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
    }

    private var warningsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Provider field notices", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            ForEach(model.snapshot.warnings) { warning in
                VStack(alignment: .leading, spacing: 4) {
                    Text(warning.message).font(.subheadline)
                    if let field = warning.field {
                        Text(field).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
    }

    private var capabilitiesCard: some View {
        DisclosureGroup("Provider capabilities") {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.snapshot.capabilities) { capability in
                    HStack {
                        Text(capability.field)
                        Spacer()
                        Text(capability.support.capitalized).foregroundStyle(.secondary)
                    }
                    .font(.caption)
                }
            }
            .padding(.top, 8)
        }
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func errorCard(_ error: SyncErrorState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sync needs attention", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text(error.message)
            if let recovery = error.recoveryAction {
                Text(recovery).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private var listSummary: some View {
        HStack {
            Label("Lists", systemImage: "list.bullet")
            Spacer()
            Text("\(model.snapshot.selectedListIDs.count) of \(model.snapshot.availableLists.count) selected")
                .foregroundStyle(.secondary)
            Button("Change") { model.showListSelection() }
                .buttonStyle(.bordered)
        }
    }
}

public struct SyncSettingsView: View {
    @ObservedObject private var model: SyncAppViewModel
    @Environment(\.dismiss) private var dismiss

    public init(model: SyncAppViewModel) {
        self.model = model
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section("Background sync") {
                    Toggle("Start sync when I log in", isOn: Binding(
                        get: { model.automaticSyncEnabled },
                        set: { model.setAutomaticSyncEnabled($0) }
                    ))
                    .disabled(!model.automaticSyncSupported || model.automaticSyncRequiresApproval)
                    #if os(macOS)
                    if model.automaticSyncRequiresApproval {
                        Label("Approval required in System Settings.", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Open Login Items settings") {
                            model.openAutomaticSyncSettings()
                        }
                    } else {
                        Label(
                            model.automaticSyncEnabled ? "Enabled" : "Disabled",
                            systemImage: model.automaticSyncEnabled ? "checkmark.circle.fill" : "circle"
                        )
                        .foregroundStyle(model.automaticSyncEnabled ? .green : .secondary)
                    }
                    Text("This uses the macOS login-item service. It does not duplicate the sync engine.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #else
                    Text("Automatic login sync is available on macOS only.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif
                    if model.automaticSyncRequiresApproval {
                        Text("macOS requires approval for this login item.")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Login Items Settings") {
                            model.openAutomaticSyncSettings()
                        }
                        .buttonStyle(.bordered)
                    }
                    if let error = model.loginItemError {
                        Text(error).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Sync settings")
            .task { model.refreshAutomaticSyncStatus() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SyncPage<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.largeTitle.bold())
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                content()
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding()
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }
}

private extension SyncPermissionStatus {
    var title: String {
        switch self {
        case .notRequested: return "Not requested"
        case .requesting: return "Requesting…"
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        }
    }
}

#endif
