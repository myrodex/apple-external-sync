#if canImport(SwiftUI)
import SwiftUI

#if DEBUG
struct SyncAppPreviews: PreviewProvider {
    static var previews: some View {
        Group {
            SyncAppRootView(
                model: SyncAppViewModel(coordinator: PreviewSyncCoordinator())
            )
            SyncDashboardView(model: readyModel)
                .previewDisplayName("Dashboard")
        }
    }

    @MainActor
    private static var readyModel: SyncAppViewModel {
        let snapshot = SyncAppSnapshot(
            connection: SyncConnectionState(
                provider: .appleReminders,
                status: .connected,
                accountName: "Preview account"
            ),
            permissions: [
                SyncPermission(kind: .reminders, status: .granted, explanation: "Read and update lists."),
                SyncPermission(kind: .notifications, status: .granted, explanation: "Show sync alerts.")
            ],
            availableLists: [SyncListOption(id: "work", name: "Work", detail: "12 tasks")],
            selectedListIDs: ["work"],
            lastSync: SyncRunSummary(
                startedAt: Date().addingTimeInterval(-300),
                finishedAt: Date().addingTimeInterval(-295),
                status: .succeeded,
                scannedCount: 12,
                updatedCount: 2
            )
        )
        return SyncAppViewModel(coordinator: PreviewSyncCoordinator(snapshot: snapshot), initialSnapshot: snapshot)
    }
}
#endif
#endif
