import Foundation
import Dispatch

/// A platform-neutral boundary for scheduling opportunistic background sync work.
/// The scheduler does not own sync state; the injected operation is the same engine
/// call used by the foreground app.
public protocol BackgroundSyncScheduling: Sendable {
    func register() throws
    func schedule(after delay: TimeInterval) throws
    func cancel()
}

public struct UnsupportedBackgroundSyncScheduler: BackgroundSyncScheduling {
    public init() {}
    public func register() throws {}
    public func schedule(after delay: TimeInterval) throws {}
    public func cancel() {}
}

#if canImport(BackgroundTasks) && os(iOS)
import BackgroundTasks

/// iOS BGTaskScheduler integration. The app target must include the identifier in
/// `BGTaskSchedulerPermittedIdentifiers` and call `register()` during application
/// launch. The handler returns whether the actual sync succeeded; this result is
/// propagated to BGTaskScheduler rather than treating every run as success.
@available(iOS 13.0, *)
public final class IOSBackgroundSyncScheduler: BackgroundSyncScheduling, @unchecked Sendable {
    public typealias Operation = @Sendable () async -> Bool

    private let identifier: String
    private let operation: Operation
    private let scheduler: BGTaskScheduler
    private let queue: DispatchQueue
    private let expirationRetryDelay: TimeInterval

    public init(
        identifier: String,
        operation: @escaping Operation,
        scheduler: BGTaskScheduler = .shared,
        queue: DispatchQueue = .main,
        expirationRetryDelay: TimeInterval = 15 * 60
    ) {
        self.identifier = identifier
        self.operation = operation
        self.scheduler = scheduler
        self.queue = queue
        self.expirationRetryDelay = max(60, expirationRetryDelay)
    }

    public func register() throws {
        let scheduler = self.scheduler
        let expirationRetryDelay = self.expirationRetryDelay
        let owner = WeakSchedulerReference(self)
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: queue) { [operation, owner] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let completion = BGTaskCompletion(task)
            let worker = Task { [operation, completion] in
                // Registration is only the one-shot execution boundary. The injected
                // AppleSyncLifecycle operation owns rescheduling so foreground and
                // background runs share exactly one policy and result path.
                let succeeded = await operation()
                completion.complete(success: !Task.isCancelled && succeeded)
            }
            task.expirationHandler = { [owner] in
                worker.cancel()
                // The lifecycle operation may be cancelled before it can reschedule;
                // submit a recovery request directly in this terminal path.
                try? owner.value?.schedule(after: expirationRetryDelay)
                completion.complete(success: false)
            }
        }
        guard registered else {
            throw BackgroundSyncSchedulerError.registrationRejected(identifier)
        }
    }

    /// Scheduling is intentionally separate from `register()`: the app's
    /// `AppleSyncLifecycle` calls it after every foreground/background run.
    public func schedule(after delay: TimeInterval = 15 * 60) throws {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: max(0, delay))
        do {
            try scheduler.submit(request)
        } catch {
            throw BackgroundSyncSchedulerError.scheduleFailed(identifier, error.localizedDescription)
        }
    }

    public func cancel() {
        scheduler.cancel(taskRequestWithIdentifier: identifier)
    }

    /// `BGTask` is an Objective-C object whose completion method is documented to be
    /// callable from any queue, but it is not annotated `Sendable` in the SDK. Keep the
    /// SDK object behind a one-shot synchronization boundary.
    private final class WeakSchedulerReference: @unchecked Sendable {
        weak var value: IOSBackgroundSyncScheduler?

        init(_ value: IOSBackgroundSyncScheduler) {
            self.value = value
        }
    }

    private final class BGTaskCompletion: @unchecked Sendable {
        private let task: BGTask
        private let lock = NSLock()
        private var didComplete = false

        init(_ task: BGTask) {
            self.task = task
        }

        func complete(success: Bool) {
            lock.lock()
            guard !didComplete else {
                lock.unlock()
                return
            }
            didComplete = true
            lock.unlock()
            task.setTaskCompleted(success: success)
        }
    }
}
#endif

public enum BackgroundSyncSchedulerError: Error, LocalizedError, Sendable, Equatable {
    case registrationRejected(String)
    case scheduleFailed(String, String)
    case notInstalled

    public var errorDescription: String? {
        switch self {
        case .registrationRejected(let identifier):
            return "iOS rejected background task registration for \(identifier)."
        case let .scheduleFailed(identifier, message):
            return "Unable to schedule background sync \(identifier): \(message)"
        case .notInstalled:
            return "Background sync scheduling has not been installed."
        }
    }
}

/// Shared lifecycle orchestration for SwiftUI/AppKit/UIKit shells.
///
/// `AppleSyncLifecycle` owns the scheduler's registration and rescheduling policy.
/// Every run reports the injected operation's success and always attempts to submit
/// the next request. A scheduler failure therefore turns an otherwise successful run
/// into a failed background result instead of silently creating a one-shot task.
public actor AppleSyncLifecycle {
    public typealias Operation = @Sendable () async -> Bool

    private let run: Operation
    private let minimumBackgroundDelay: TimeInterval
    private var backgroundScheduler: (any BackgroundSyncScheduling)?
    private var isRegistered = false

    public init(
        backgroundScheduler: (any BackgroundSyncScheduling)? = nil,
        minimumBackgroundDelay: TimeInterval = 15 * 60,
        run: @escaping Operation
    ) {
        self.run = run
        self.minimumBackgroundDelay = minimumBackgroundDelay
        self.backgroundScheduler = backgroundScheduler
    }

    /// Installs one scheduler, registers its handler, and submits the initial request.
    /// Calling this again is idempotent for the already-installed scheduler.
    public func install(_ scheduler: any BackgroundSyncScheduling) throws {
        backgroundScheduler = scheduler
        if !isRegistered {
            try scheduler.register()
            isRegistered = true
        }
        try scheduler.schedule(after: minimumBackgroundDelay)
    }

    /// Kept as a lifecycle-friendly alias for callers that separate registration from
    /// initial scheduling. `install` is preferred because it prevents one-shot setup.
    public func register() throws {
        guard let scheduler = backgroundScheduler else {
            throw BackgroundSyncSchedulerError.notInstalled
        }
        if !isRegistered {
            try scheduler.register()
            isRegistered = true
        }
    }

    public func foreground() async -> Bool {
        await runAndSchedule()
    }

    /// Called by the BGTaskScheduler handler. It returns false for either a failed
    /// sync operation or a failed reschedule, allowing the system to retry.
    public func runBackgroundSync() async -> Bool {
        await runAndSchedule()
    }

    /// Schedule without performing work, used when a scene enters the background.
    public func scheduleNext() throws {
        guard let scheduler = backgroundScheduler else {
            throw BackgroundSyncSchedulerError.notInstalled
        }
        try scheduler.schedule(after: minimumBackgroundDelay)
    }

    public func background() async {
        _ = await runAndSchedule()
    }

    public func cancel() {
        backgroundScheduler?.cancel()
    }

    private func runAndSchedule() async -> Bool {
        let operationSucceeded = await run()
        guard let scheduler = backgroundScheduler else {
            // Foreground-only hosts deliberately use the lifecycle without a
            // scheduler; their sync result remains authoritative.
            return operationSucceeded
        }
        do {
            try scheduler.schedule(after: minimumBackgroundDelay)
            return operationSucceeded
        } catch {
            return false
        }
    }
}
