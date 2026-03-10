import Diagnostics
import Persistence
import Testing

@Test
func queuedMessageRepositoryPersistsAndUpdatesState() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.persistence")
    let database = try AppDatabase(inMemory: diagnostics)
    let repository = QueuedMessageRepository(database: database, diagnostics: diagnostics)

    let record = QueuedMessageRecord(
        accountID: "acct-test",
        roomID: "!room:test",
        transactionID: "txn-1",
        senderID: "@me:test",
        body: "Hello",
        state: "queued"
    )

    _ = try await repository.save(record)
    let pending = try await repository.fetchPending()
    #expect(pending.count == 1)
    #expect(pending.first?.body == "Hello")

    let updated = try await repository.updateState(
        transactionID: "txn-1",
        state: "echoed",
        eventID: "$evt",
        attemptCount: 2,
        errorDescription: nil
    )

    #expect(updated?.state == "echoed")
    #expect(updated?.eventID == "$evt")
    #expect(updated?.attemptCount == 2)
}

@Test
func queuedMessageRepositoryScopesPendingRecordsByAccount() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.persistence.scope")
    let database = try AppDatabase(inMemory: diagnostics)
    let accountARepository = QueuedMessageRepository(database: database, diagnostics: diagnostics, accountID: "acct-a")
    let accountBRepository = QueuedMessageRepository(database: database, diagnostics: diagnostics, accountID: "acct-b")

    _ = try await accountARepository.save(
        QueuedMessageRecord(
            accountID: "acct-a",
            roomID: "!room-a:test",
            transactionID: "txn-a",
            senderID: "@a:test",
            body: "A",
            state: "queued"
        )
    )
    _ = try await accountBRepository.save(
        QueuedMessageRecord(
            accountID: "acct-b",
            roomID: "!room-b:test",
            transactionID: "txn-b",
            senderID: "@b:test",
            body: "B",
            state: "queued"
        )
    )

    let accountAPending = try await accountARepository.fetchPending()
    let accountBPending = try await accountBRepository.fetchPending()

    #expect(accountAPending.count == 1)
    #expect(accountAPending.first?.accountID == "acct-a")
    #expect(accountBPending.count == 1)
    #expect(accountBPending.first?.accountID == "acct-b")
}
