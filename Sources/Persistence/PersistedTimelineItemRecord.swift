import Foundation
import GRDB

public struct PersistedTimelineItemRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "persisted_timeline_items"

    public var id: Int64?
    public var accountID: String
    public var roomID: String
    public var itemID: String
    public var sortIndex: Int
    public var payload: Data
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        accountID: String,
        roomID: String,
        itemID: String,
        sortIndex: Int,
        payload: Data,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.roomID = roomID
        self.itemID = itemID
        self.sortIndex = sortIndex
        self.payload = payload
        self.updatedAt = updatedAt
    }
}
