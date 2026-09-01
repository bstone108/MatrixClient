import Foundation
import MatrixCore
import Testing

private func room(
    id: String,
    name: String,
    unread: Int,
    highlight: Int = 0,
    membership: RoomMembership = .joined,
    timestamp: Date
) -> RoomSummary {
    RoomSummary(
        roomID: RoomIdentifier(rawValue: id),
        displayName: name,
        topic: "",
        lastMessagePreview: "",
        timestamp: timestamp,
        unreadCount: unread,
        highlightCount: highlight,
        isDirect: false,
        isEncrypted: false,
        lastSenderDisplayName: "",
        membership: membership
    )
}

@Test
func unreadCountIsRenderedOnTheRoomNameWithAccessibleLabel() {
    let unread = room(id: "!a", name: "General", unread: 3, timestamp: Date(timeIntervalSince1970: 20))
    let read = room(id: "!b", name: "Design", unread: 0, timestamp: Date(timeIntervalSince1970: 30))

    #expect(RoomListPresentationPolicy.displayTitle(for: unread) == "General (3)")
    #expect(RoomListPresentationPolicy.accessibilityLabel(for: unread) == "General, 3 unread messages")
    #expect(RoomListPresentationPolicy.displayTitle(for: read) == "Design")
    #expect(RoomListPresentationPolicy.accessibilityLabel(for: read) == "Design")
}

@Test
func highlightOnlyRoomsUseTheLiveHighlightCountOnTheName() {
    let mentions = room(id: "!m", name: "Ops", unread: 0, highlight: 1, timestamp: Date(timeIntervalSince1970: 1))
    #expect(RoomListPresentationPolicy.hasUnread(mentions))
    #expect(RoomListPresentationPolicy.displayTitle(for: mentions) == "Ops (1)")
    #expect(RoomListPresentationPolicy.accessibilityLabel(for: mentions) == "Ops, 1 unread message")
}

@Test
func unreadJoinedRoomsSortAboveReadRoomsInTheApplicableList() {
    let olderUnread = room(id: "!u1", name: "Media", unread: 2, timestamp: Date(timeIntervalSince1970: 10))
    let newerRead = room(id: "!r1", name: "Alerts", unread: 0, timestamp: Date(timeIntervalSince1970: 50))
    let newerUnread = room(id: "!u2", name: "General", unread: 4, timestamp: Date(timeIntervalSince1970: 20))
    let sections = RoomListPresentationPolicy.sections(
        rooms: [newerRead, olderUnread, newerUnread],
        inSpace: false
    )

    #expect(sections.map(\.title) == ["Rooms"])
    #expect(sections[0].rooms.map(\.displayName) == ["General", "Media", "Alerts"])
}

@Test
func becomingReadMovesARoomBelowRemainingUnreadRooms() {
    let first = room(id: "!a", name: "General", unread: 2, timestamp: Date(timeIntervalSince1970: 30))
    let second = room(id: "!b", name: "Media", unread: 3, timestamp: Date(timeIntervalSince1970: 20))
    let before = RoomListPresentationPolicy.sorted([first, second], unreadFirst: true)
    #expect(before.map(\.displayName) == ["Media", "General"])

    let firstNowRead = room(id: "!a", name: "General", unread: 0, timestamp: Date(timeIntervalSince1970: 30))
    let after = RoomListPresentationPolicy.sorted([firstNowRead, second], unreadFirst: true)
    #expect(after.map(\.displayName) == ["Media", "General"])
    #expect(RoomListPresentationPolicy.displayTitle(for: after[0]) == "Media (3)")
    #expect(RoomListPresentationPolicy.displayTitle(for: after[1]) == "General")

    let bothRead = RoomListPresentationPolicy.sorted([
        firstNowRead,
        room(id: "!b", name: "Media", unread: 0, timestamp: Date(timeIntervalSince1970: 20))
    ], unreadFirst: true)
    #expect(bothRead.map(\.displayName) == ["General", "Media"])
}

@Test
func invitesStayFirstAndSpaceSectionTitlesArePreserved() {
    let invite = room(
        id: "!inv",
        name: "New Team",
        unread: 0,
        membership: .invited,
        timestamp: Date(timeIntervalSince1970: 5)
    )
    let unread = room(id: "!u", name: "Standup", unread: 1, timestamp: Date(timeIntervalSince1970: 8))
    let left = room(
        id: "!left",
        name: "Archive",
        unread: 0,
        membership: .left,
        timestamp: Date(timeIntervalSince1970: 1)
    )
    let sections = RoomListPresentationPolicy.sections(
        rooms: [left, unread, invite],
        inSpace: true
    )

    #expect(sections.map(\.kind) == [.invites, .rooms, .other])
    #expect(sections.map(\.title) == ["Invites", "Joined rooms", "Not joined"])
    #expect(sections[0].rooms.map(\.displayName) == ["New Team"])
    #expect(sections[1].rooms.map(\.displayName) == ["Standup"])
    #expect(RoomListPresentationPolicy.accessibilityLabel(for: invite) == "New Team, invited")
}
