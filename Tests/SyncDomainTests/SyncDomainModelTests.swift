import Foundation
import XCTest
@testable import SyncDomain

final class SyncDomainModelTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func task(
        id: SyncID = SyncID(UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
        title: String = "Base",
        notes: String? = "base notes",
        completed: Bool = false,
        dueDate: Date? = nil,
        deletedAt: Date? = nil
    ) -> CanonicalTask {
        CanonicalTask(
            id: id,
            title: title,
            notes: notes,
            isCompleted: completed,
            dueDate: dueDate,
            createdAt: epoch,
            updatedAt: epoch,
            deletedAt: deletedAt,
            deletionReason: deletedAt == nil ? nil : .user
        )
    }

    func testDeterministicCanonicalIDIsStableAndNamespaceSeparated() {
        let first = SyncID.deterministic(namespace: "google:account-1:task:remote-1")
        let second = SyncID.deterministic(namespace: "google:account-1:task:remote-1")
        let list = SyncID.deterministic(namespace: "google:account-1:list:remote-1")

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first, list)
    }

    func testIndependentTaskEditsMergeWithoutConflict() {
        let base = task()
        var local = base
        local.title = "Local title"
        var remote = base
        remote.notes = "Remote notes"
        let now = epoch.addingTimeInterval(100)

        let result = CanonicalTaskMerger.merge(base: base, local: local, remote: remote, now: now)

        XCTAssertFalse(result.isConflict)
        XCTAssertEqual(result.task?.title, "Local title")
        XCTAssertEqual(result.task?.notes, "Remote notes")
        XCTAssertEqual(result.task?.updatedAt, now)
        XCTAssertEqual(Set(result.changedFields), Set([.title, .notes]))
    }

    func testConcurrentTaskEditProducesOnlyConflictingField() {
        let base = task()
        var local = base
        local.title = "Local title"
        var remote = base
        remote.title = "Remote title"
        remote.notes = "Remote notes"

        let result = CanonicalTaskMerger.merge(base: base, local: local, remote: remote, now: epoch.addingTimeInterval(1))

        XCTAssertTrue(result.isConflict)
        XCTAssertNil(result.task)
        XCTAssertEqual(result.conflicts, [.title])
    }

    func testDeleteVersusEditIsConflictButTwoDeletesConverge() {
        let base = task()
        let deleted = base.markingDeleted(at: epoch.addingTimeInterval(10), reason: .user)
        var edited = base
        edited.title = "Changed remotely"

        let conflict = CanonicalTaskMerger.merge(base: base, local: deleted, remote: edited, now: epoch.addingTimeInterval(20))
        XCTAssertEqual(Set(conflict.conflicts), Set([.deletedAt, .title]))
        XCTAssertNil(conflict.task)

        let remoteDeleted = base.markingDeleted(at: epoch.addingTimeInterval(11), reason: .remote)
        let converged = CanonicalTaskMerger.merge(base: base, local: deleted, remote: remoteDeleted, now: epoch.addingTimeInterval(20))
        XCTAssertFalse(converged.isConflict)
        XCTAssertNotNil(converged.task?.deletedAt)
    }

    func testListMergerIsFieldLevelAndDeterministic() {
        let base = CanonicalList(id: SyncID(UUID(uuidString: "00000000-0000-0000-0000-000000000002")!), name: "Base", createdAt: epoch, updatedAt: epoch)
        var local = base
        local.name = "Local"
        var remote = base
        remote.colorHex = "#FF0000"
        let now = epoch.addingTimeInterval(42)

        let result = CanonicalListMerger.merge(base: base, local: local, remote: remote, now: now)
        XCTAssertFalse(result.isConflict)
        XCTAssertEqual(result.list?.name, "Local")
        XCTAssertEqual(result.list?.colorHex, "#FF0000")
        XCTAssertEqual(result.list?.updatedAt, now)

        remote.name = "Remote"
        let conflict = CanonicalListMerger.merge(base: base, local: local, remote: remote, now: now)
        XCTAssertEqual(conflict.conflicts, [.name])
        XCTAssertNil(conflict.list)
    }

    func testTombstoneRetentionIsExactlyThirtyDaysByDefault() {
        let policy = TombstoneRetentionPolicy()
        XCTAssertFalse(policy.isExpired(deletedAt: epoch, now: epoch.addingTimeInterval(30 * 24 * 60 * 60 - 1)))
        XCTAssertTrue(policy.isExpired(deletedAt: epoch, now: epoch.addingTimeInterval(30 * 24 * 60 * 60)))
    }
}
