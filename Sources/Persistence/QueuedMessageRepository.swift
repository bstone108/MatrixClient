import Diagnostics
import Foundation
import GRDB

public enum QueuedMessageRepositoryError: Error, LocalizedError {
    case accountScopeMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .accountScopeMismatch(let expected, let actual):
            "Queued message account scope mismatch. Expected \(expected), received \(actual)."
        }
    }
}

public actor QueuedMessageRepository {
    private let database: AppDatabase
    private let diagnostics: DiagnosticsService
    private let accountID: String?

    public init(database: AppDatabase, diagnostics: DiagnosticsService, accountID: String? = nil) {
        self.database = database
        self.diagnostics = diagnostics
        self.accountID = accountID
    }

    public func save(_ record: QueuedMessageRecord) async throws -> QueuedMessageRecord {
        if let accountID, record.accountID != accountID {
            throw QueuedMessageRepositoryError.accountScopeMismatch(expected: accountID, actual: record.accountID)
        }
        let copy = try await database.dbQueue.write { db in
            var copy = record
            copy.updatedAt = .now
            try copy.save(db)
            return copy
        }
        await diagnostics.record(
            .debug,
            category: "SendQueue",
            message: "Persisted queued message",
            metadata: ["transactionID": copy.transactionID, "state": copy.state]
        )
        return copy
    }

    public func fetchAll() throws -> [QueuedMessageRecord] {
        let accountID = self.accountID
        return try database.dbQueue.read { db in
            try Self.scopedRequest(accountID: accountID)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetchPending() throws -> [QueuedMessageRecord] {
        let accountID = self.accountID
        return try database.dbQueue.read { db in
            try Self.scopedRequest(accountID: accountID)
                .filter((Column("state") == "queued") || (Column("state") == "sending"))
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    public func fetch(transactionID: String) throws -> QueuedMessageRecord? {
        let accountID = self.accountID
        return try database.dbQueue.read { db in
            try Self.scopedRequest(accountID: accountID)
                .filter(Column("transactionID") == transactionID)
                .fetchOne(db)
        }
    }

    public func updateState(
        transactionID: String,
        state: String,
        eventID: String? = nil,
        attemptCount: Int? = nil,
        errorDescription: String? = nil
    ) async throws -> QueuedMessageRecord? {
        let accountID = self.accountID
        return try await database.dbQueue.write { db in
            guard var record = try Self.scopedRequest(accountID: accountID)
                .filter(Column("transactionID") == transactionID)
                .fetchOne(db) else {
                return nil as QueuedMessageRecord?
            }
            record.state = state
            record.updatedAt = .now
            record.eventID = eventID ?? record.eventID
            record.attemptCount = attemptCount ?? record.attemptCount
            record.errorDescription = errorDescription
            try record.update(db)
            return record
        }
    }

    private static func scopedRequest(accountID: String?) -> QueryInterfaceRequest<QueuedMessageRecord> {
        var request = QueuedMessageRecord.all()
        if let accountID {
            request = request.filter(Column("accountID") == accountID)
        }
        return request
    }
}
