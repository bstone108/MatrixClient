import Foundation
@testable import MatrixCore
import Testing

@Test
func replaceRetainsPreviouslyKnownRoomsWhenSnapshotOmitsThem() async {
    let olderRoom = makeRoomSummary(
        roomID: "!older:test",
        name: "Older",
        timestamp: Date(timeIntervalSince1970: 1_000)
    )
    let newerRoom = makeRoomSummary(
        roomID: "!newer:test",
        name: "Newer",
        timestamp: Date(timeIntervalSince1970: 2_000)
    )
    let coordinator = SlidingSyncCoordinator(spaces: [], rooms: [olderRoom, newerRoom])

    let refreshedNewerRoom = makeRoomSummary(
        roomID: "!newer:test",
        name: "Newer Updated",
        timestamp: Date(timeIntervalSince1970: 3_000)
    )

    await coordinator.replace(spaces: [], rooms: [refreshedNewerRoom])
    let rooms = await coordinator.roomSummaries(spaceID: nil)

    #expect(rooms.count == 2)
    #expect(rooms.map(\.roomID.rawValue).contains("!older:test"))
    #expect(rooms.first?.roomID.rawValue == "!newer:test")
    #expect(rooms.first?.displayName == "Newer Updated")
}

@Test
func replaceDoesNotClearKnownRoomsOnEmptySnapshot() async {
    let room = makeRoomSummary(
        roomID: "!room:test",
        name: "Still Here",
        timestamp: Date(timeIntervalSince1970: 1_000)
    )
    let coordinator = SlidingSyncCoordinator(spaces: [], rooms: [room])

    await coordinator.replace(spaces: [], rooms: [])
    let rooms = await coordinator.roomSummaries(spaceID: nil)

    #expect(rooms.count == 1)
    #expect(rooms[0].roomID.rawValue == "!room:test")
}

private func makeRoomSummary(roomID: String, name: String, timestamp: Date) -> RoomSummary {
    RoomSummary(
        roomID: RoomIdentifier(rawValue: roomID),
        displayName: name,
        topic: "",
        lastMessagePreview: "",
        timestamp: timestamp,
        unreadCount: 0,
        highlightCount: 0,
        isDirect: false,
        isEncrypted: true,
        lastSenderDisplayName: name
    )
}
