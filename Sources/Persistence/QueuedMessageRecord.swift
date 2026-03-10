import Foundation
import GRDB

public struct QueuedMessageRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    public static let databaseTableName = "queued_messages"

    public var id: Int64?
    public var accountID: String
    public var roomID: String
    public var transactionID: String
    public var senderID: String
    public var body: String
    public var createdAt: Date
    public var updatedAt: Date
    public var state: String
    public var eventID: String?
    public var attemptCount: Int
    public var errorDescription: String?

    public init(
        id: Int64? = nil,
        accountID: String,
        roomID: String,
        transactionID: String,
        senderID: String,
        body: String,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        state: String,
        eventID: String? = nil,
        attemptCount: Int = 0,
        errorDescription: String? = nil
    ) {
        self.id = id
        self.accountID = accountID
        self.roomID = roomID
        self.transactionID = transactionID
        self.senderID = senderID
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.state = state
        self.eventID = eventID
        self.attemptCount = attemptCount
        self.errorDescription = errorDescription
    }
}

