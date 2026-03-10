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

@Test
func allRoomsExcludeRoomsAssignedToSpaces() async {
    let accountRoom = makeRoomSummary(
        roomID: "!general:test",
        name: "General",
        timestamp: Date(timeIntervalSince1970: 3_000)
    )
    let space = makeRoomSummary(
        roomID: "!space:test",
        name: "Work",
        timestamp: Date(timeIntervalSince1970: 2_000),
        roomKind: .space
    )
    let spacedRoom = makeRoomSummary(
        roomID: "!project:test",
        name: "Project",
        timestamp: Date(timeIntervalSince1970: 4_000),
        spaceIDs: [SpaceIdentifier(rawValue: "!space:test")]
    )
    let coordinator = SlidingSyncCoordinator(spaces: [], rooms: [accountRoom, space, spacedRoom])

    let accountRooms = await coordinator.roomSummaries(spaceID: nil)
    let spaces = await coordinator.spaceSummaries()

    #expect(accountRooms.map(\.roomID.rawValue) == ["!general:test"])
    #expect(spaces.map(\.spaceID.rawValue) == ["!space:test"])
    #expect(spaces.first?.roomIDs.map(\.rawValue) == ["!project:test"])
}

@Test
func selectedSpaceShowsJoinedRoomsBeforeNotJoinedPreviews() async {
    let spaceID = SpaceIdentifier(rawValue: "!space:test")
    let space = makeRoomSummary(
        roomID: spaceID.rawValue,
        name: "Work",
        timestamp: Date(timeIntervalSince1970: 1_000),
        roomKind: .space
    )
    let joinedRoom = makeRoomSummary(
        roomID: "!joined:test",
        name: "Joined Room",
        timestamp: Date(timeIntervalSince1970: 4_000),
        spaceIDs: [spaceID]
    )
    let previewRoom = makeRoomSummary(
        roomID: "!preview:test",
        name: "Preview Room",
        timestamp: .distantPast,
        membership: .notJoined,
        spaceIDs: [spaceID]
    )
    let coordinator = SlidingSyncCoordinator(spaces: [], rooms: [space, joinedRoom, previewRoom])

    let rooms = await coordinator.roomSummaries(spaceID: spaceID)

    #expect(rooms.map(\.roomID.rawValue) == ["!joined:test", "!preview:test"])
    #expect(rooms[0].membership == .joined)
    #expect(rooms[1].membership == .notJoined)
}

@Test
func discoveredNotJoinedSpacesStillAppearInSpacesList() async {
    let spaceID = SpaceIdentifier(rawValue: "!space:test")
    let discoveredSpace = makeRoomSummary(
        roomID: spaceID.rawValue,
        name: "Adult Rooms",
        timestamp: Date(timeIntervalSince1970: 1_000),
        roomKind: .space,
        membership: .notJoined
    )
    let childRoom = makeRoomSummary(
        roomID: "!child:test",
        name: "General",
        timestamp: Date(timeIntervalSince1970: 2_000),
        spaceIDs: [spaceID]
    )
    let coordinator = SlidingSyncCoordinator(spaces: [], rooms: [discoveredSpace, childRoom])

    let spaces = await coordinator.spaceSummaries()

    #expect(spaces.count == 1)
    #expect(spaces[0].spaceID == spaceID)
    #expect(spaces[0].roomIDs == [RoomIdentifier(rawValue: "!child:test")])
}

private func makeRoomSummary(
    roomID: String,
    name: String,
    timestamp: Date,
    roomKind: RoomSummaryKind = .room,
    membership: RoomMembership = .joined,
    spaceIDs: [SpaceIdentifier] = []
) -> RoomSummary {
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
        lastSenderDisplayName: name,
        roomKind: roomKind,
        membership: membership,
        spaceIDs: spaceIDs
    )
}
