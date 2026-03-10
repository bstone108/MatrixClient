import Foundation
import GRDB

public struct PersistedRoomSummaryRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "persisted_room_summaries"

    public var id: Int64?
    public var accountID: String
    public var roomID: String
    public var payload: Data
    public var updatedAt: Date

    public init(
        id: Int64? = nil,
        accountID: String,
        roomID: String,
        payload: Data,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.accountID = accountID
        self.roomID = roomID
        self.payload = payload
        self.updatedAt = updatedAt
    }
}
