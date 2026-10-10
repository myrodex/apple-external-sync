import Foundation
import SyncDomain
import SyncContracts

#if canImport(EventKit)
@preconcurrency import EventKit
import CoreGraphics

/// Main-actor EventKit implementation behind the adapter's testable store protocol.
/// EventKit objects are not Sendable; one store instance is kept on the main actor and
/// all provider work is serialized there while the adapter remains actor-isolated.
@MainActor
public final class EventKitStore: EventKitRemindersStore, @unchecked Sendable {
    public let eventStore: EKEventStore
    private let epoch = Date(timeIntervalSince1970: 0)

    public init(eventStore: EKEventStore = EKEventStore()) {
        self.eventStore = eventStore
    }

    public func authorizationStatus() async -> EventKitRemindersAuthorizationStatus {
        Self.map(EKEventStore.authorizationStatus(for: .reminder))
    }

    @discardableResult
    public func requestFullAccess() async throws -> Bool {
        if #available(iOS 17.0, macOS 14.0, *) {
            return try await withCheckedThrowingContinuation { continuation in
                eventStore.requestFullAccessToReminders { granted, error in
                    if let error { continuation.resume(throwing: Self.map(error)) }
                    else { continuation.resume(returning: granted) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            eventStore.requestAccess(to: .reminder) { granted, error in
                if let error { continuation.resume(throwing: Self.map(error)) }
                else { continuation.resume(returning: granted) }
            }
        }
    }

    public func fetchLists() async throws -> [EventKitReminderListSnapshot] {
        let defaultID = eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
        return eventStore.calendars(for: .reminder).map { calendar in
            EventKitReminderListSnapshot(
                id: calendar.calendarIdentifier,
                name: calendar.title,
                colorHex: Self.hexColor(calendar.cgColor),
                isDefault: calendar.calendarIdentifier == defaultID,
                isReadOnly: !calendar.allowsContentModifications,
                createdAt: epoch,
                updatedAt: epoch
            )
        }
    }

    public func fetchReminders(listIDs: Set<String>) async throws -> [EventKitReminderSnapshot] {
        let calendars = eventStore.calendars(for: .reminder).filter { listIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let reminders: [EventKitReminderSnapshot] = await withCheckedContinuation { continuation in
            eventStore.fetchReminders(matching: eventStore.predicateForReminders(in: calendars)) { values in
                let snapshots = values?.compactMap(Self.snapshot(_:)) ?? []
                continuation.resume(returning: snapshots)
            }
        }
        return reminders
    }

    public func fetchReminder(id: String) async throws -> EventKitReminderSnapshot? {
        guard let reminder = eventStore.calendarItem(withIdentifier: id) as? EKReminder else { return nil }
        return Self.snapshot(reminder)
    }

    public func fetchList(id: String) async throws -> EventKitReminderListSnapshot? {
        guard let list = eventStore.calendar(withIdentifier: id) else { return nil }
        return snapshot(list)
    }

    public func saveList(_ list: EventKitReminderListWrite) async throws -> EventKitReminderListSnapshot {
        let calendar: EKCalendar
        if let id = list.id, let existing = eventStore.calendar(withIdentifier: id) {
            guard existing.allowsContentModifications else { throw SyncAdapterError.unsupported("The selected EventKit reminder list is read-only.") }
            calendar = existing
        } else {
            guard let source = eventStore.defaultCalendarForNewReminders()?.source else {
                throw SyncAdapterError.unavailable("EventKit did not provide a writable reminder source.")
            }
            calendar = EKCalendar(for: .reminder, eventStore: eventStore)
            calendar.source = source
        }
        guard !list.name.isEmpty else { throw SyncAdapterError.invalidResponse("An EventKit reminder list name cannot be empty.") }
        calendar.title = list.name
        if let colorHex = list.colorHex {
            guard let color = Self.cgColor(from: colorHex) else { throw SyncAdapterError.invalidResponse("Invalid EventKit reminder list color: \(colorHex).") }
            calendar.cgColor = color
        }
        do { try eventStore.saveCalendar(calendar, commit: true) }
        catch { throw Self.map(error) }
        return snapshot(calendar)
    }

    public func deleteList(id: String) async throws {
        guard let calendar = eventStore.calendar(withIdentifier: id) else { return }
        guard calendar.allowsContentModifications else { throw SyncAdapterError.unsupported("The selected EventKit reminder list is read-only.") }
        // Removing a calendar deletes its reminders. The sync protocol has no explicit
        // cascade acknowledgement, so fail closed instead of causing data loss.
        throw SyncAdapterError.unsupported("Deleting an EventKit reminder list is destructive and is not supported.")
    }

    public func saveReminder(_ reminder: EventKitReminderWrite) async throws -> EventKitReminderSnapshot {
        guard let calendar = eventStore.calendar(withIdentifier: reminder.listID) else {
            throw SyncAdapterError.unsupported("The mapped EventKit reminder list no longer exists.")
        }
        guard calendar.allowsContentModifications else { throw SyncAdapterError.unsupported("The mapped EventKit reminder list is read-only.") }

        let item: EKReminder
        if let id = reminder.id, let existing = eventStore.calendarItem(withIdentifier: id) {
            guard let existingReminder = existing as? EKReminder else { throw SyncAdapterError.invalidResponse("The mapped EventKit calendar item is not a reminder.") }
            item = existingReminder
        } else {
            item = EKReminder(eventStore: eventStore)
        }
        item.calendar = calendar
        item.title = reminder.title
        item.notes = reminder.notes
        item.priority = Self.eventKitPriority(reminder.priority)
        item.dueDateComponents = Self.dateComponents(from: reminder.dueDate)
        item.isCompleted = reminder.isCompleted
        item.completionDate = reminder.isCompleted ? reminder.completedAt : nil
        do { try eventStore.save(item, commit: true) }
        catch { throw Self.map(error) }
        guard let result = Self.snapshot(item) else { throw SyncAdapterError.invalidResponse("EventKit saved a reminder without a calendar identifier.") }
        return result
    }

    public func deleteReminder(id: String) async throws {
        guard let item = eventStore.calendarItem(withIdentifier: id) else { return }
        guard let reminder = item as? EKReminder else { throw SyncAdapterError.invalidResponse("The mapped EventKit calendar item is not a reminder.") }
        guard reminder.calendar?.allowsContentModifications ?? false else { throw SyncAdapterError.unsupported("The mapped EventKit reminder list is read-only.") }
        do { try eventStore.remove(reminder, commit: true) }
        catch { throw Self.map(error) }
    }

    private func snapshot(_ calendar: EKCalendar) -> EventKitReminderListSnapshot {
        let defaultID = eventStore.defaultCalendarForNewReminders()?.calendarIdentifier
        return EventKitReminderListSnapshot(
            id: calendar.calendarIdentifier,
            name: calendar.title,
            colorHex: Self.hexColor(calendar.cgColor),
            isDefault: calendar.calendarIdentifier == defaultID,
            isReadOnly: !calendar.allowsContentModifications,
            createdAt: epoch,
            updatedAt: epoch
        )
    }

    private static func map(_ status: EKAuthorizationStatus) -> EventKitRemindersAuthorizationStatus {
        if #available(iOS 17.0, macOS 14.0, *) {
            switch status {
            case .notDetermined: return .notDetermined
            case .restricted: return .restricted
            case .denied: return .denied
            case .writeOnly: return .writeOnly
            case .fullAccess: return .fullAccess
            @unknown default: return .unknown
            }
        }
        switch status {
        case .notDetermined: return .notDetermined
        case .restricted: return .restricted
        case .denied: return .denied
        case .authorized: return .authorized
        case .fullAccess: return .fullAccess
        case .writeOnly: return .writeOnly
        @unknown default: return .unknown
        }
    }

    private static func snapshot(_ reminder: EKReminder) -> EventKitReminderSnapshot? {
        guard let calendarID = reminder.calendar?.calendarIdentifier, !calendarID.isEmpty else { return nil }
        let createdAt = reminder.creationDate ?? reminder.lastModifiedDate ?? Date(timeIntervalSince1970: 0)
        let updatedAt = reminder.lastModifiedDate ?? createdAt
        return EventKitReminderSnapshot(
            id: reminder.calendarItemIdentifier,
            listID: calendarID,
            title: reminder.title,
            notes: reminder.notes,
            isCompleted: reminder.isCompleted,
            dueDate: Self.date(from: reminder.dueDateComponents),
            completedAt: reminder.completionDate,
            priority: Self.priority(from: reminder.priority),
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }

    private static func date(from components: DateComponents?) -> Date? {
        guard let components else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = components.timeZone ?? .current
        return calendar.date(from: components)
    }

    private static func dateComponents(from date: Date?) -> DateComponents? {
        guard let date else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
    }

    private static func priority(from value: Int) -> TaskPriority {
        switch value {
        case 1...3: return .high
        case 4...6: return .medium
        case 7...9: return .low
        default: return .none
        }
    }

    private static func eventKitPriority(_ value: TaskPriority) -> Int {
        switch value {
        case .urgent, .high: return 1
        case .medium: return 5
        case .low: return 9
        case .none: return 0
        }
    }

    private static func hexColor(_ color: CGColor?) -> String? {
        guard let color,
              let rgb = color.converted(to: CGColorSpaceCreateDeviceRGB(), intent: .defaultIntent, options: nil),
              let values = rgb.components,
              values.count >= 3 else { return nil }
        let red = max(0, min(1, values[0]))
        let green = max(0, min(1, values[1]))
        let blue = max(0, min(1, values[2]))
        return String(format: "#%02X%02X%02X", Int((red * 255).rounded()), Int((green * 255).rounded()), Int((blue * 255).rounded()))
    }

    private static func cgColor(from string: String) -> CGColor? {
        let value = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("#") else { return nil }
        let hex = String(value.dropFirst())
        guard hex.count == 6 || hex.count == 8, let number = UInt64(hex, radix: 16) else { return nil }
        let divisor: CGFloat = 255
        let red = CGFloat((number >> (hex.count == 8 ? 24 : 16)) & 0xff) / divisor
        let green = CGFloat((number >> (hex.count == 8 ? 16 : 8)) & 0xff) / divisor
        let blue = CGFloat((number >> (hex.count == 8 ? 8 : 0)) & 0xff) / divisor
        let alpha = hex.count == 8 ? CGFloat(number & 0xff) / divisor : 1
        return CGColor(red: red, green: green, blue: blue, alpha: alpha)
    }

    nonisolated private static func map(_ error: Error) -> SyncAdapterError {
        SyncAdapterError.transport(error.localizedDescription)
    }
}

/// Coalesces Apple's coarse store notifications. A notification does not identify a
/// changed item, so callers must refetch all selected lists after each emitted event.
@MainActor
public final class EventKitStoreChangeNotifications: @preconcurrency EventKitStoreChangeSource, @unchecked Sendable {
    private let center: NotificationCenter
    private let debounceNanoseconds: UInt64
    private var observer: NSObjectProtocol?
    private var pendingEmission: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

    public init(eventStore: EKEventStore, notificationCenter: NotificationCenter = .default, debounce: Duration = .milliseconds(150)) {
        self.center = notificationCenter
        let parts = debounce.components
        self.debounceNanoseconds = parts.seconds >= 0
            ? UInt64(parts.seconds) * 1_000_000_000 + UInt64(max(0, parts.attoseconds) / 1_000_000_000)
            : 0
        self.observer = notificationCenter.addObserver(forName: .EKEventStoreChanged, object: eventStore, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.scheduleEmission() }
        }
    }

    isolated deinit {
        pendingEmission?.cancel()
        if let observer { center.removeObserver(observer) }
        continuations.values.forEach { $0.finish() }
    }

    public func events() -> AsyncStream<Void> {
        let id = UUID()
        return AsyncStream { continuation in
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in self?.continuations.removeValue(forKey: id) }
            }
        }
    }

    private func scheduleEmission() {
        pendingEmission?.cancel()
        pendingEmission = Task { @MainActor [weak self] in
            guard let self else { return }
            if debounceNanoseconds > 0 { try? await Task.sleep(nanoseconds: debounceNanoseconds) }
            guard !Task.isCancelled else { return }
            continuations.values.forEach { _ = $0.yield(()) }
        }
    }
}
#endif

#if !canImport(EventKit)
/// Explicit fallback keeps non-Apple previews and CI composition buildable.
public struct EventKitStore: EventKitRemindersStore {
    public init() {}
    public func authorizationStatus() async -> EventKitRemindersAuthorizationStatus { .unknown }
    public func requestFullAccess() async throws -> Bool { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func fetchLists() async throws -> [EventKitReminderListSnapshot] { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func fetchReminders(listIDs: Set<String>) async throws -> [EventKitReminderSnapshot] { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func fetchReminder(id: String) async throws -> EventKitReminderSnapshot? { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func fetchList(id: String) async throws -> EventKitReminderListSnapshot? { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func saveList(_ list: EventKitReminderListWrite) async throws -> EventKitReminderListSnapshot { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func deleteList(id: String) async throws { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func saveReminder(_ reminder: EventKitReminderWrite) async throws -> EventKitReminderSnapshot { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
    public func deleteReminder(id: String) async throws { throw SyncAdapterError.unavailable("EventKit is unavailable on this platform.") }
}
#endif
