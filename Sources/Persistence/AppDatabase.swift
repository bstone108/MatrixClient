import Diagnostics
import Foundation
import GRDB

public final class AppDatabase: @unchecked Sendable {
    public let paths: AppPaths
    public let dbQueue: DatabaseQueue

    public init(paths: AppPaths, diagnostics: DiagnosticsService? = nil) throws {
        self.paths = paths
        self.dbQueue = try DatabaseQueue(path: paths.databaseURL.path)
        try migrator.migrate(dbQueue)
        if let diagnostics {
            Task {
                await diagnostics.record(
                    .info,
                    category: "Persistence",
                    message: "Opened application database",
                    metadata: ["path": paths.databaseURL.path]
                )
            }
        }
    }

    public convenience init(diagnostics: DiagnosticsService? = nil) throws {
        try self.init(paths: .default(), diagnostics: diagnostics)
    }

    public init(inMemory diagnostics: DiagnosticsService? = nil) throws {
        self.paths = AppPaths(applicationSupportURL: URL(fileURLWithPath: "/tmp"), databaseURL: URL(fileURLWithPath: ":memory:"))
        self.dbQueue = try DatabaseQueue()
        try migrator.migrate(dbQueue)
        if let diagnostics {
            Task {
                await diagnostics.record(.info, category: "Persistence", message: "Opened in-memory database")
            }
        }
    }

    private var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("createQueuedMessages") { db in
            try db.create(table: QueuedMessageRecord.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("accountID", .text).notNull()
                table.column("roomID", .text).notNull()
                table.column("transactionID", .text).notNull().unique(onConflict: .replace)
                table.column("senderID", .text).notNull()
                table.column("body", .text).notNull()
                table.column("createdAt", .datetime).notNull()
                table.column("updatedAt", .datetime).notNull()
                table.column("state", .text).notNull()
                table.column("eventID", .text)
                table.column("attemptCount", .integer).notNull().defaults(to: 0)
                table.column("errorDescription", .text)
            }
            try db.create(index: "queued_messages_pending_idx", on: QueuedMessageRecord.databaseTableName, columns: ["state", "createdAt"])
        }

        migrator.registerMigration("createPersistedTimelineItems") { db in
            try db.create(table: PersistedTimelineItemRecord.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("accountID", .text).notNull()
                table.column("roomID", .text).notNull()
                table.column("itemID", .text).notNull()
                table.column("sortIndex", .integer).notNull()
                table.column("payload", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "persisted_timeline_room_sort_idx",
                on: PersistedTimelineItemRecord.databaseTableName,
                columns: ["accountID", "roomID", "sortIndex"]
            )
        }

        migrator.registerMigration("createPersistedRoomSummaries") { db in
            try db.create(table: PersistedRoomSummaryRecord.databaseTableName) { table in
                table.autoIncrementedPrimaryKey("id")
                table.column("accountID", .text).notNull()
                table.column("roomID", .text).notNull()
                table.column("payload", .blob).notNull()
                table.column("updatedAt", .datetime).notNull()
            }
            try db.create(
                index: "persisted_room_summary_account_room_idx",
                on: PersistedRoomSummaryRecord.databaseTableName,
                columns: ["accountID", "roomID"],
                unique: true
            )
        }

        return migrator
    }
}
