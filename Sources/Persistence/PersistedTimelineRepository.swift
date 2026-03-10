import Diagnostics
import Foundation
import GRDB

public struct PersistedTimelinePayload: Sendable {
    public let itemID: String
    public let sortIndex: Int
    public let payload: Data

    public init(itemID: String, sortIndex: Int, payload: Data) {
        self.itemID = itemID
        self.sortIndex = sortIndex
        self.payload = payload
    }
}

public actor PersistedTimelineRepository {
    private let database: AppDatabase
    private let diagnostics: DiagnosticsService
    private let accountID: String?

    public init(database: AppDatabase, diagnostics: DiagnosticsService, accountID: String? = nil) {
        self.database = database
        self.diagnostics = diagnostics
        self.accountID = accountID
    }

    public func replace(roomID: String, items: [PersistedTimelinePayload]) async throws {
        let accountID = self.accountID
        let persistedItems = items

        try await database.dbQueue.write { db in
            var deleteRequest = PersistedTimelineItemRecord
                .filter(Column("roomID") == roomID)

            if let accountID {
                deleteRequest = deleteRequest.filter(Column("accountID") == accountID)
            }

            try deleteRequest.deleteAll(db)

            let effectiveAccountID = accountID ?? ""
            for item in persistedItems {
                var record = PersistedTimelineItemRecord(
                    accountID: effectiveAccountID,
                    roomID: roomID,
                    itemID: item.itemID,
                    sortIndex: item.sortIndex,
                    payload: item.payload,
                    updatedAt: .now
                )
                try record.insert(db)
            }
        }

        await diagnostics.record(
            .debug,
            category: "Persistence",
            message: "Persisted room timeline snapshot",
            metadata: [
                "roomID": roomID,
                "itemCount": "\(items.count)"
            ]
        )
    }

    public func fetch(roomID: String) throws -> [PersistedTimelineItemRecord] {
        let accountID = self.accountID
        return try database.dbQueue.read { db in
            var request = PersistedTimelineItemRecord
                .filter(Column("roomID") == roomID)
                .order(Column("sortIndex").asc)

            if let accountID {
                request = request.filter(Column("accountID") == accountID)
            }

            return try request.fetchAll(db)
        }
    }
}
