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
/// launch. The handler is intentionally injected so no provider or engine singleton
/// is hidden in this package.
@available(iOS 13.0, *)
public final class IOSBackgroundSyncScheduler: BackgroundSyncScheduling, @unchecked Sendable {
    public typealias Operation = @Sendable () async -> Void

    private let identifier: String
    private let operation: Operation
    private let scheduler: BGTaskScheduler
    private let queue: DispatchQueue

    public init(
        identifier: String,
        operation: @escaping Operation,
        scheduler: BGTaskScheduler = .shared,
        queue: DispatchQueue = .main
    ) {
        self.identifier = identifier
        self.operation = operation
        self.scheduler = scheduler
        self.queue = queue
    }

    public func register() throws {
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: queue) { [operation] task in
            guard let task = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            let completion = BGTaskCompletion(task)
            let worker = Task { [operation, completion] in
                await operation()
                guard !Task.isCancelled else { return }
                completion.complete(success: true)
            }
            task.expirationHandler = { [completion] in
                worker.cancel()
                completion.complete(success: false)
            }
        }
        guard registered else {
            throw BackgroundSyncSchedulerError.registrationRejected(identifier)
        }
    }

    /// `BGTask` is an Objective-C object whose completion method is documented to be
    /// callable from any queue, but it is not annotated `Sendable` in the SDK. Keep the
    /// SDK object behind a one-shot synchronization boundary rather than capturing it in
    /// an unstructured Swift concurrency task.
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
}
#endif

public enum BackgroundSyncSchedulerError: Error, LocalizedError, Sendable, Equatable {
    case registrationRejected(String)
    case scheduleFailed(String, String)

    public var errorDescription: String? {
        switch self {
        case .registrationRejected(let identifier):
            return "iOS rejected background task registration for \(identifier)."
        case let .scheduleFailed(identifier, message):
            return "Unable to schedule background sync \(identifier): \(message)"
        }
    }
}

/// Shared lifecycle orchestration for SwiftUI/AppKit/UIKit shells. It triggers an
/// immediate foreground sync and re-schedules the next opportunistic background run.
public actor AppleSyncLifecycle {
    private let run: @Sendable () async -> Void
    private let backgroundScheduler: any BackgroundSyncScheduling
    private let minimumBackgroundDelay: TimeInterval

    public init(
        backgroundScheduler: any BackgroundSyncScheduling = UnsupportedBackgroundSyncScheduler(),
        minimumBackgroundDelay: TimeInterval = 15 * 60,
        run: @escaping @Sendable () async -> Void
    ) {
        self.run = run
        self.backgroundScheduler = backgroundScheduler
        self.minimumBackgroundDelay = minimumBackgroundDelay
    }

    public func register() throws {
        try backgroundScheduler.register()
    }

    public func foreground() async {
        await run()
        try? await scheduleNext()
    }

    public func background() async {
        try? await scheduleNext()
    }

    public func scheduleNext() async throws {
        try backgroundScheduler.schedule(after: minimumBackgroundDelay)
    }

    public func cancel() {
        backgroundScheduler.cancel()
    }
}
