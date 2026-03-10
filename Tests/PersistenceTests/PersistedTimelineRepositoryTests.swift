import Diagnostics
import Foundation
import Persistence
import Testing

@Test
func persistedTimelineRepositoryReplacesRoomSnapshotInOrder() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.persistence.timeline")
    let database = try AppDatabase(inMemory: diagnostics)
    let repository = PersistedTimelineRepository(database: database, diagnostics: diagnostics, accountID: "acct-a")

    try await repository.replace(
        roomID: "!room:test",
        items: [
            PersistedTimelinePayload(itemID: "evt-2", sortIndex: 1, payload: Data("second".utf8)),
            PersistedTimelinePayload(itemID: "evt-1", sortIndex: 0, payload: Data("first".utf8))
        ]
    )

    let initial = try await repository.fetch(roomID: "!room:test")
    #expect(initial.map(\.itemID) == ["evt-1", "evt-2"])
    #expect(String(data: initial[0].payload, encoding: .utf8) == "first")

    try await repository.replace(
        roomID: "!room:test",
        items: [
            PersistedTimelinePayload(itemID: "evt-3", sortIndex: 0, payload: Data("replacement".utf8))
        ]
    )

    let replaced = try await repository.fetch(roomID: "!room:test")
    #expect(replaced.map(\.itemID) == ["evt-3"])
    #expect(String(data: replaced[0].payload, encoding: .utf8) == "replacement")
}

@Test
func persistedTimelineRepositoryScopesSnapshotsByAccount() async throws {
    let diagnostics = DiagnosticsService(subsystem: "test.persistence.timeline.scope")
    let database = try AppDatabase(inMemory: diagnostics)
    let accountARepository = PersistedTimelineRepository(database: database, diagnostics: diagnostics, accountID: "acct-a")
    let accountBRepository = PersistedTimelineRepository(database: database, diagnostics: diagnostics, accountID: "acct-b")

    try await accountARepository.replace(
        roomID: "!room:test",
        items: [PersistedTimelinePayload(itemID: "evt-a", sortIndex: 0, payload: Data("A".utf8))]
    )
    try await accountBRepository.replace(
        roomID: "!room:test",
        items: [PersistedTimelinePayload(itemID: "evt-b", sortIndex: 0, payload: Data("B".utf8))]
    )

    let accountAItems = try await accountARepository.fetch(roomID: "!room:test")
    let accountBItems = try await accountBRepository.fetch(roomID: "!room:test")

    #expect(accountAItems.map(\.itemID) == ["evt-a"])
    #expect(accountBItems.map(\.itemID) == ["evt-b"])
}
