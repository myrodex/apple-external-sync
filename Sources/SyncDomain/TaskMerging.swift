import Foundation

public struct TaskMergeResult: Sendable {
    public let task: CanonicalTask?
    public let conflicts: [ConflictField]
    public let changedFields: [ConflictField]

    public init(task: CanonicalTask?, conflicts: [ConflictField], changedFields: [ConflictField]) {
        self.task = task
        self.conflicts = conflicts
        self.changedFields = changedFields
    }

    public var isConflict: Bool { !conflicts.isEmpty }
}

/// Performs a field-level three-way merge. A field is safe when only one side changed
/// relative to the last successful synchronization. Concurrent changes to the same
/// field are kept as a conflict instead of being resolved by wall-clock ordering.
public enum CanonicalTaskMerger {
    public static func merge(
        base: CanonicalTask?,
        local: CanonicalTask,
        remote: CanonicalTask,
        now: Date
    ) -> TaskMergeResult {
        guard let base else {
            if sameContent(local, remote) { return TaskMergeResult(task: local, conflicts: [], changedFields: []) }
            return TaskMergeResult(
                task: nil,
                conflicts: allFields,
                changedFields: allFields
            )
        }

        let localDeleted = local.deletedAt != nil
        let remoteDeleted = remote.deletedAt != nil
        if localDeleted != remoteDeleted {
            let editedSide = localDeleted ? remote : local
            let editedFields = changedFields(from: base, to: editedSide)
            if !editedFields.isEmpty {
                let fields = Array(Set(editedFields + [.deletedAt])).sorted { $0.rawValue < $1.rawValue }
                return TaskMergeResult(task: nil, conflicts: fields, changedFields: fields)
            }
        }

        var merged = base
        var conflicts: [ConflictField] = []
        var changed: [ConflictField] = []

        mergeField(.title, base.title, local.title, remote.title, &merged.title, &conflicts, &changed)
        mergeField(.notes, base.notes, local.notes, remote.notes, &merged.notes, &conflicts, &changed)
        mergeField(.listID, base.listID, local.listID, remote.listID, &merged.listID, &conflicts, &changed)
        mergeField(.isCompleted, base.isCompleted, local.isCompleted, remote.isCompleted, &merged.isCompleted, &conflicts, &changed)
        mergeField(.dueDate, base.dueDate, local.dueDate, remote.dueDate, &merged.dueDate, &conflicts, &changed)
        mergeField(.completedAt, base.completedAt, local.completedAt, remote.completedAt, &merged.completedAt, &conflicts, &changed)
        mergeField(.priority, base.priority, local.priority, remote.priority, &merged.priority, &conflicts, &changed)
        if localDeleted && remoteDeleted {
            merged.deletedAt = min(local.deletedAt ?? .distantFuture, remote.deletedAt ?? .distantFuture)
            merged.deletionReason = local.deletionReason ?? remote.deletionReason
            changed.append(.deletedAt)
        } else {
            mergeField(.deletedAt, base.deletedAt, local.deletedAt, remote.deletedAt, &merged.deletedAt, &conflicts, &changed)
        }

        if conflicts.isEmpty {
            merged.updatedAt = now
            if merged.isCompleted && merged.completedAt == nil {
                merged.completedAt = now
            }
            if !merged.isCompleted {
                merged.completedAt = nil
            }
            return TaskMergeResult(task: merged, conflicts: [], changedFields: changed)
        }
        return TaskMergeResult(task: nil, conflicts: conflicts, changedFields: changed)
    }

    public static let allFields: [ConflictField] = [
        .title, .notes, .listID, .isCompleted, .dueDate, .completedAt, .priority, .deletedAt
    ]

    public static func sameContent(_ lhs: CanonicalTask, _ rhs: CanonicalTask) -> Bool {
        lhs.title == rhs.title && lhs.notes == rhs.notes && lhs.listID == rhs.listID &&
            lhs.isCompleted == rhs.isCompleted && lhs.dueDate == rhs.dueDate &&
            lhs.completedAt == rhs.completedAt && lhs.priority == rhs.priority &&
            (lhs.deletedAt != nil) == (rhs.deletedAt != nil)
    }

    private static func changedFields(from base: CanonicalTask, to value: CanonicalTask) -> [ConflictField] {
        var fields: [ConflictField] = []
        if base.title != value.title { fields.append(.title) }
        if base.notes != value.notes { fields.append(.notes) }
        if base.listID != value.listID { fields.append(.listID) }
        if base.isCompleted != value.isCompleted { fields.append(.isCompleted) }
        if base.dueDate != value.dueDate { fields.append(.dueDate) }
        if base.completedAt != value.completedAt { fields.append(.completedAt) }
        if base.priority != value.priority { fields.append(.priority) }
        return fields
    }

    private static func mergeField<T: Equatable>(
        _ field: ConflictField,
        _ base: T,
        _ local: T,
        _ remote: T,
        _ destination: inout T,
        _ conflicts: inout [ConflictField],
        _ changed: inout [ConflictField]
    ) {
        let localChanged = local != base
        let remoteChanged = remote != base
        if localChanged || remoteChanged { changed.append(field) }
        if remoteChanged && !localChanged {
            destination = remote
        } else if localChanged && remoteChanged {
            if local == remote {
                destination = local
            } else {
                conflicts.append(field)
            }
        } else if localChanged {
            destination = local
        }
    }
}

public extension CanonicalTask {
    func markingDeleted(at date: Date, reason: DeletionReason) -> CanonicalTask {
        var copy = self
        copy.deletedAt = date
        copy.deletionReason = reason
        copy.updatedAt = date
        return copy
    }

    func revived(at date: Date) -> CanonicalTask {
        var copy = self
        copy.deletedAt = nil
        copy.deletionReason = nil
        copy.updatedAt = date
        return copy
    }
}

public extension CanonicalList {
    func markingDeleted(at date: Date, reason: DeletionReason) -> CanonicalList {
        var copy = self
        copy.deletedAt = date
        copy.deletionReason = reason
        copy.updatedAt = date
        return copy
    }
}

public struct ListMergeResult: Sendable {
    public let list: CanonicalList?
    public let conflicts: [ConflictField]
    public let changedFields: [ConflictField]

    public init(list: CanonicalList?, conflicts: [ConflictField] = [], changedFields: [ConflictField] = []) {
        self.list = list
        self.conflicts = conflicts
        self.changedFields = changedFields
    }

    public var isConflict: Bool { !conflicts.isEmpty }
}

public enum CanonicalListMerger {
    public static let allFields: [ConflictField] = [.name, .colorHex, .position, .deletedAt]

    public static func sameContent(_ lhs: CanonicalList, _ rhs: CanonicalList) -> Bool {
        lhs.name == rhs.name && lhs.colorHex == rhs.colorHex && lhs.position == rhs.position &&
            (lhs.deletedAt != nil) == (rhs.deletedAt != nil)
    }

    public static func merge(
        base: CanonicalList?,
        local: CanonicalList,
        remote: CanonicalList,
        now: Date
    ) -> ListMergeResult {
        guard let base else {
            if sameContent(local, remote) { return ListMergeResult(list: local) }
            return ListMergeResult(list: nil, conflicts: [.name, .colorHex, .position, .deletedAt], changedFields: [.name, .colorHex, .position, .deletedAt])
        }

        let localDeleted = local.deletedAt != nil
        let remoteDeleted = remote.deletedAt != nil
        if localDeleted != remoteDeleted {
            let editedSide = localDeleted ? remote : local
            var fields: [ConflictField] = []
            if base.name != editedSide.name { fields.append(.name) }
            if base.colorHex != editedSide.colorHex { fields.append(.colorHex) }
            if base.position != editedSide.position { fields.append(.position) }
            if !fields.isEmpty {
                fields.append(.deletedAt)
                fields.sort { $0.rawValue < $1.rawValue }
                return ListMergeResult(list: nil, conflicts: fields, changedFields: fields)
            }
        }

        var merged = base
        var conflicts: [ConflictField] = []
        var changed: [ConflictField] = []
        mergeField(.name, base.name, local.name, remote.name, &merged.name, &conflicts, &changed)
        mergeField(.colorHex, base.colorHex, local.colorHex, remote.colorHex, &merged.colorHex, &conflicts, &changed)
        mergeField(.position, base.position, local.position, remote.position, &merged.position, &conflicts, &changed)
        if localDeleted && remoteDeleted {
            merged.deletedAt = min(local.deletedAt ?? .distantFuture, remote.deletedAt ?? .distantFuture)
            merged.deletionReason = local.deletionReason ?? remote.deletionReason
            changed.append(.deletedAt)
        } else {
            mergeField(.deletedAt, base.deletedAt, local.deletedAt, remote.deletedAt, &merged.deletedAt, &conflicts, &changed)
        }

        guard conflicts.isEmpty else {
            return ListMergeResult(list: nil, conflicts: conflicts, changedFields: changed)
        }
        merged.updatedAt = now
        if merged.deletedAt == nil { merged.deletionReason = nil }
        return ListMergeResult(list: merged, changedFields: changed)
    }

    private static func mergeField<T: Equatable>(
        _ field: ConflictField,
        _ base: T,
        _ local: T,
        _ remote: T,
        _ destination: inout T,
        _ conflicts: inout [ConflictField],
        _ changed: inout [ConflictField]
    ) {
        let localChanged = local != base
        let remoteChanged = remote != base
        if localChanged || remoteChanged { changed.append(field) }
        if remoteChanged && !localChanged {
            destination = remote
        } else if localChanged && remoteChanged {
            if local == remote { destination = local }
            else { conflicts.append(field) }
        } else if localChanged {
            destination = local
        }
    }
}
