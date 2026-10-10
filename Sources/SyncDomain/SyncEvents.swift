import Foundation

public enum LocalChange: Sendable, Hashable {
    case upsertTask(CanonicalTask)
    case deleteTask(id: SyncID, reason: DeletionReason, at: Date)
    case upsertList(CanonicalList)
    case deleteList(id: SyncID, reason: DeletionReason, at: Date)
}

public enum SyncEvent: Sendable, Hashable {
    case started(SyncAccount)
    case pulled(SyncAccount, count: Int)
    case pushed(SyncAccount, count: Int)
    case conflict(SyncConflict)
    case completed(SyncAccount)
}
