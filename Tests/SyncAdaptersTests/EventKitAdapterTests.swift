import XCTest
@preconcurrency import EventKit
@testable import SyncAdapters
import SyncContracts
import SyncDomain

final class EventKitAdapterTests: XCTestCase {
    func testPullRefetchesOnlyExplicitlySelectedListsAndReportsUnsupportedOrdering() async throws {
        let first = EventKitReminderListSnapshot(id: "work", name: "Work")
        let second = EventKitReminderListSnapshot(id: "home", name: "Home")
        let reminder = EventKitReminderSnapshot(
            id: "task-1",
            listID: "work",
            title: "Ship it",
            notes: "Notes",
            isCompleted: false,
            dueDate: Date(timeIntervalSince1970: 1_700_000_000),
            createdAt: Date(timeIntervalSince1970: 10),
            updatedAt: Date(timeIntervalSince1970: 20)
        )
        let store = FakeEventKitStore(status: .fullAccess, lists: [first, second], reminders: [reminder])
        let adapter = EventKitRemindersAdapter(
            account: SyncAccount(provider: .eventKit, accountID: "local"),
            store: store,
            selection: ExplicitEventKitListSelection(selectedListIDs: ["work"]),
            mapping: InMemoryEventKitListMapping(),
            changeSource: FinishedChangeSource(),
            now: { Date(timeIntervalSince1970: 30) }
        )

        let changes = try await adapter.pullChanges(since: "ignored")
        XCTAssertFalse(changes.isFullSnapshot, "An explicit list selection is a partial snapshot; unselected lists must not be inferred as deletes.")
        XCTAssertNil(changes.nextCursor)
        XCTAssertEqual(changes.serverNow, Date(timeIntervalSince1970: 30))
        XCTAssertEqual(changes.changes.count, 2)
        XCTAssertEqual(changes.diagnostics.map(\.field), [.listPosition])
        XCTAssertEqual(changes.diagnostics.first?.resourceID, "work")

        let listIDs = changes.changes.compactMap { change -> String? in
            guard case let .list(list) = change else { return nil }
            return list.remoteID
        }
        XCTAssertEqual(listIDs, ["work"])
        let taskIDs = changes.changes.compactMap { change -> String? in
            guard case let .task(task) = change else { return nil }
            return task.remoteID
        }
        XCTAssertEqual(taskIDs, ["task-1"])
        let fetchedIDs = await store.lastFetchedListIDs()
        XCTAssertEqual(fetchedIDs, ["work"])
    }

    func testAllListSelectionStillEmitsACompleteSnapshot() async throws {
        let store = FakeEventKitStore(
            status: .fullAccess,
            lists: [EventKitReminderListSnapshot(id: "work", name: "Work")]
        )
        let adapter = EventKitRemindersAdapter(
            account: SyncAccount(provider: .eventKit, accountID: "local"),
            store: store,
            selection: AllEventKitListsSelection(),
            mapping: InMemoryEventKitListMapping(),
            changeSource: FinishedChangeSource()
        )

        let changes = try await adapter.pullChanges(since: nil)
        XCTAssertTrue(changes.isFullSnapshot)
    }

    func testReminderSnapshotMapperRunsOffMainActorLikeEventKitSearchCallback() async throws {
        let snapshot = await Task.detached {
            EventKitReminderSnapshotMapper.make(EventKitReminderFields(
                id: "task-1",
                listID: "work",
                title: "Callback task",
                notes: "Search queue",
                isCompleted: true,
                dueDate: EventKitReminderSnapshotMapper.date(from: DateComponents(year: 2026, month: 10, day: 11)),
                completedAt: Date(timeIntervalSince1970: 100),
                priority: EventKitReminderSnapshotMapper.taskPriority(from: 9),
                createdAt: Date(timeIntervalSince1970: 50),
                updatedAt: Date(timeIntervalSince1970: 100)
            ))
        }.value

        XCTAssertEqual(snapshot.id, "task-1")
        XCTAssertEqual(snapshot.listID, "work")
        XCTAssertEqual(snapshot.title, "Callback task")
        XCTAssertEqual(snapshot.priority, .low)
        XCTAssertTrue(snapshot.isCompleted)
    }

    func testPullRequiresReadableAccessAndRequestAccessUpdatesFakeStatus() async throws {
        let store = FakeEventKitStore(status: .notDetermined)
        let adapter = EventKitRemindersAdapter(
            account: SyncAccount(provider: .eventKit, accountID: "local"),
            store: store,
            mapping: InMemoryEventKitListMapping(),
            changeSource: FinishedChangeSource()
        )
        do {
            _ = try await adapter.pullChanges(since: nil)
            XCTFail("Expected pull to require permission")
        } catch let error as SyncAdapterError {
            XCTAssertEqual(error, .authenticationRequired)
        }

        let granted = try await adapter.requestFullAccess()
        XCTAssertTrue(granted)
        let status = await adapter.authorizationStatus()
        XCTAssertEqual(status, .fullAccess)
    }

    func testPushCreatesExplicitListMappingAndTransformsUrgentPriority() async throws {
        let store = FakeEventKitStore(status: .fullAccess, lists: [EventKitReminderListSnapshot(id: "work", name: "Work")])
        let mapping = InMemoryEventKitListMapping()
        let adapter = EventKitRemindersAdapter(
            account: SyncAccount(provider: .eventKit, accountID: "local"),
            store: store,
            mapping: mapping,
            changeSource: FinishedChangeSource(),
            now: { Date(timeIntervalSince1970: 40) }
        )
        let listID = SyncID()
        let taskID = SyncID()
        let result = try await adapter.push([
            .upsertList(canonicalListID: listID, list: RemoteList(remoteID: "", name: "New", position: "opaque")),
            .upsertTask(canonicalTaskID: taskID, task: RemoteTask(
                remoteID: "",
                title: "Urgent",
                remoteListID: "work",
                priority: .urgent
            ))
        ], cursor: nil)

        XCTAssertEqual(result.accepted, 2)
        XCTAssertTrue(result.rejected.isEmpty)
        XCTAssertEqual(result.mappings.count, 2)
        XCTAssertEqual(result.diagnostics.map(\.field), [.listPosition, .taskPriority])
        let mappedRemoteListID = await mapping.remoteListID(for: listID)
        XCTAssertEqual(mappedRemoteListID, "created-list")
        let saved = await store.savedReminderWrites()
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.priority, .urgent)
    }

    @MainActor
    func testStoreChangedNotificationEmitsARefetchSignal() async {
        let center = NotificationCenter()
        let eventStore = EKEventStore()
        let source = EventKitStoreChangeNotifications(eventStore: eventStore, notificationCenter: center, debounce: .zero)
        var iterator = source.events().makeAsyncIterator()
        center.post(name: .EKEventStoreChanged, object: eventStore)
        let event: Void? = await iterator.next()
        XCTAssertNotNil(event)
    }

    func testWriteIsRejectedWhenTaskHasNoExplicitListMapping() async throws {
        let store = FakeEventKitStore(status: .fullAccess)
        let adapter = EventKitRemindersAdapter(
            account: SyncAccount(provider: .eventKit, accountID: "local"),
            store: store,
            mapping: InMemoryEventKitListMapping(),
            changeSource: FinishedChangeSource()
        )
        let result = try await adapter.push([
            .upsertTask(canonicalTaskID: SyncID(), task: RemoteTask(remoteID: "", title: "No list"))
        ], cursor: nil)
        XCTAssertEqual(result.accepted, 0)
        XCTAssertEqual(result.rejected.count, 1)
        XCTAssertTrue(result.rejected[0].reason.contains("reminder list"))
    }
}

private struct FinishedChangeSource: EventKitStoreChangeSource {
    func events() -> AsyncStream<Void> {
        AsyncStream { continuation in continuation.finish() }
    }
}

private actor FakeEventKitStore: EventKitRemindersStore {
    private var status: EventKitRemindersAuthorizationStatus
    private var lists: [String: EventKitReminderListSnapshot]
    private var reminders: [String: EventKitReminderSnapshot]
    private var fetchedListIDs: Set<String> = []
    private var savedWrites: [EventKitReminderWrite] = []

    init(
        status: EventKitRemindersAuthorizationStatus,
        lists: [EventKitReminderListSnapshot] = [],
        reminders: [EventKitReminderSnapshot] = []
    ) {
        self.status = status
        self.lists = Dictionary(uniqueKeysWithValues: lists.map { ($0.id, $0) })
        self.reminders = Dictionary(uniqueKeysWithValues: reminders.map { ($0.id, $0) })
    }

    func authorizationStatus() async -> EventKitRemindersAuthorizationStatus { status }

    func requestFullAccess() async throws -> Bool {
        status = .fullAccess
        return true
    }

    func fetchLists() async throws -> [EventKitReminderListSnapshot] {
        lists.values.sorted { $0.id < $1.id }
    }

    func fetchReminders(listIDs: Set<String>) async throws -> [EventKitReminderSnapshot] {
        fetchedListIDs = listIDs
        return reminders.values.filter { listIDs.contains($0.listID) }.sorted { $0.id < $1.id }
    }

    func fetchReminder(id: String) async throws -> EventKitReminderSnapshot? { reminders[id] }
    func fetchList(id: String) async throws -> EventKitReminderListSnapshot? { lists[id] }

    func saveList(_ list: EventKitReminderListWrite) async throws -> EventKitReminderListSnapshot {
        let id = list.id ?? "created-list"
        let snapshot = EventKitReminderListSnapshot(id: id, name: list.name, colorHex: list.colorHex)
        lists[id] = snapshot
        return snapshot
    }

    func deleteList(id: String) async throws { lists.removeValue(forKey: id) }

    func saveReminder(_ reminder: EventKitReminderWrite) async throws -> EventKitReminderSnapshot {
        savedWrites.append(reminder)
        let id = reminder.id ?? "created-task"
        let date = Date(timeIntervalSince1970: 1)
        let snapshot = EventKitReminderSnapshot(
            id: id,
            listID: reminder.listID,
            title: reminder.title,
            notes: reminder.notes,
            isCompleted: reminder.isCompleted,
            dueDate: reminder.dueDate,
            completedAt: reminder.completedAt,
            priority: reminder.priority,
            createdAt: date,
            updatedAt: date
        )
        reminders[id] = snapshot
        return snapshot
    }

    func deleteReminder(id: String) async throws { reminders.removeValue(forKey: id) }
    func lastFetchedListIDs() -> [String] { fetchedListIDs.sorted() }
    func savedReminderWrites() -> [EventKitReminderWrite] { savedWrites }
}
