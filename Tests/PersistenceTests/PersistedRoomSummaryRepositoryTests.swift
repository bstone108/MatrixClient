import Diagnostics
import Foundation
import Persistence
import Testing

@Test
func persistedRoomSummaryRepositoryReplacesSnapshotInOrder() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.persistence.roomsummary")
    let database = try AppDatabase(inMemory: diagnostics)
    let repository = PersistedRoomSummaryRepository(database: database, diagnostics: diagnostics, accountID: "acct-a")

    try await repository.replaceAll([
        PersistedRoomSummaryPayload(roomID: "!room-1:test", payload: Data("one".utf8)),
        PersistedRoomSummaryPayload(roomID: "!room-2:test", payload: Data("two".utf8))
    ])

    let initial = try await repository.fetchAll()
    #expect(Set(initial.map(\.roomID)) == Set(["!room-1:test", "!room-2:test"]))

    try await repository.replaceAll([
        PersistedRoomSummaryPayload(roomID: "!room-3:test", payload: Data("three".utf8))
    ])

    let replaced = try await repository.fetchAll()
    #expect(replaced.map(\.roomID) == ["!room-3:test"])
    #expect(String(data: replaced[0].payload, encoding: .utf8) == "three")
}

@Test
func persistedRoomSummaryRepositoryScopesSnapshotsByAccount() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.persistence.roomsummary.scope")
    let database = try AppDatabase(inMemory: diagnostics)
    let accountARepository = PersistedRoomSummaryRepository(database: database, diagnostics: diagnostics, accountID: "acct-a")
    let accountBRepository = PersistedRoomSummaryRepository(database: database, diagnostics: diagnostics, accountID: "acct-b")

    try await accountARepository.replaceAll([
        PersistedRoomSummaryPayload(roomID: "!room-a:test", payload: Data("A".utf8))
    ])
    try await accountBRepository.replaceAll([
        PersistedRoomSummaryPayload(roomID: "!room-b:test", payload: Data("B".utf8))
    ])

    let accountASummaries = try await accountARepository.fetchAll()
    let accountBSummaries = try await accountBRepository.fetchAll()

    #expect(accountASummaries.map(\.roomID) == ["!room-a:test"])
    #expect(accountBSummaries.map(\.roomID) == ["!room-b:test"])
}
