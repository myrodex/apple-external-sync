import Foundation
import XCTest
@testable import SyncAppSupport

final class AppleLifecycleTests: XCTestCase {
    func testInstallRegistersAndSchedulesInitialRequest() async throws {
        let scheduler = RecordingScheduler()
        let lifecycle = AppleSyncLifecycle(minimumBackgroundDelay: 42) { true }

        try await lifecycle.install(scheduler)

        let state = scheduler.snapshot()
        XCTAssertEqual(state.registerCount, 1)
        XCTAssertEqual(state.scheduleDelays, [42])
    }

    func testBackgroundRunReschedulesAfterSuccessfulOperation() async throws {
        let scheduler = RecordingScheduler()
        let lifecycle = AppleSyncLifecycle(minimumBackgroundDelay: 7) { true }
        try await lifecycle.install(scheduler)

        let result = await lifecycle.runBackgroundSync()

        XCTAssertTrue(result)
        XCTAssertEqual(scheduler.snapshot().scheduleDelays, [7, 7])
    }

    func testBackgroundRunReportsOperationFailureButStillReschedules() async throws {
        let scheduler = RecordingScheduler()
        let lifecycle = AppleSyncLifecycle(minimumBackgroundDelay: 9) { false }
        try await lifecycle.install(scheduler)

        let result = await lifecycle.runBackgroundSync()

        XCTAssertFalse(result)
        XCTAssertEqual(scheduler.snapshot().scheduleDelays, [9, 9])
    }

    func testBackgroundRunReportsRescheduleFailure() async throws {
        let scheduler = RecordingScheduler()
        let lifecycle = AppleSyncLifecycle(minimumBackgroundDelay: 11) { true }
        try await lifecycle.install(scheduler)
        scheduler.failScheduling = true

        let result = await lifecycle.runBackgroundSync()

        XCTAssertFalse(result)
        XCTAssertEqual(scheduler.snapshot().scheduleDelays, [11])
    }

    func testRegisterRequiresInstalledScheduler() async {
        let lifecycle = AppleSyncLifecycle { true }

        do {
            try await lifecycle.register()
            XCTFail("Expected register to require an installed scheduler")
        } catch let error as BackgroundSyncSchedulerError {
            XCTAssertEqual(error, .notInstalled)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}

private final class RecordingScheduler: BackgroundSyncScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var registrations = 0
    private var delays: [TimeInterval] = []
    private var canceled = false
    var failScheduling = false

    func register() throws {
        lock.lock()
        defer { lock.unlock() }
        registrations += 1
    }

    func schedule(after delay: TimeInterval) throws {
        lock.lock()
        defer { lock.unlock() }
        if failScheduling {
            throw BackgroundSyncSchedulerError.scheduleFailed("test", "simulated scheduler failure")
        }
        delays.append(delay)
    }

    func cancel() {
        lock.lock()
        canceled = true
        lock.unlock()
    }

    func snapshot() -> (registerCount: Int, scheduleDelays: [TimeInterval], canceled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        return (registrations, delays, canceled)
    }
}
