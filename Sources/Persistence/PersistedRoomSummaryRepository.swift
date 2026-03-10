import Diagnostics
import Foundation
import GRDB

public actor PersistedRoomSummaryRepository {
    private let database: AppDatabase
    private let diagnostics: DiagnosticsService
    private let accountID: String?

    public init(database: AppDatabase, diagnostics: DiagnosticsService, accountID: String? = nil) {
        self.database = database
        self.diagnostics = diagnostics
        self.accountID = accountID
    }

    public func replaceAll(_ payloads: [PersistedRoomSummaryPayload]) async throws {
        guard !payloads.isEmpty else { return }

        let accountID = self.accountID ?? ""

        try await database.dbQueue.write { db in
            try PersistedRoomSummaryRecord
                .filter(Column("accountID") == accountID)
                .deleteAll(db)

            for payload in payloads {
                var record = PersistedRoomSummaryRecord(
                    accountID: accountID,
                    roomID: payload.roomID,
                    payload: payload.payload,
                    updatedAt: .now
                )
                try record.insert(db)
            }
        }

        await diagnostics.record(
            .debug,
            category: "Persistence",
            message: "Persisted room summary snapshot",
            metadata: [
                "accountID": accountID,
                "roomCount": "\(payloads.count)"
            ]
        )
    }

    public func fetchAll() throws -> [PersistedRoomSummaryPayload] {
        let accountID = self.accountID ?? ""
        let records = try database.dbQueue.read { db in
            try PersistedRoomSummaryRecord
                .filter(Column("accountID") == accountID)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        }

        return records.map {
            PersistedRoomSummaryPayload(roomID: $0.roomID, payload: $0.payload)
        }
    }
}

public struct PersistedRoomSummaryPayload: Sendable {
    public let roomID: String
    public let payload: Data

    public init(roomID: String, payload: Data) {
        self.roomID = roomID
        self.payload = payload
    }
}
