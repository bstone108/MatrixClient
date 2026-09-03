import Foundation
import MatrixCore
import Testing

private func message(
    id: String,
    own: Bool = false,
    timestamp: TimeInterval = 1
) -> TimelineItem {
    TimelineItem(
        id: id,
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: own ? "@me:test" : "@alice:test",
        senderDisplayName: own ? "Me" : "Alice",
        body: id,
        timestamp: Date(timeIntervalSince1970: timestamp),
        isOwnMessage: own,
        isEncrypted: true
    )
}

@Test
func timelineNotificationPolicyIgnoresFirstSnapshotWithoutLastSeen() {
    let history = [message(id: "$a"), message(id: "$b")]
    #expect(
        TimelineNotificationPolicy.incomingMessagesToNotify(
            previousItems: [],
            currentItems: history,
            lastSeenEventID: nil
        ).isEmpty
    )
}

@Test
func timelineNotificationPolicyNotifiesForItemsAfterLastSeen() {
    let previous = [message(id: "$a"), message(id: "$b")]
    let current = previous + [message(id: "$c", timestamp: 3)]
    let newItems = TimelineNotificationPolicy.incomingMessagesToNotify(
        previousItems: previous,
        currentItems: current,
        lastSeenEventID: "$b"
    )
    #expect(newItems.map(\.id) == ["$c"])
}

@Test
func timelineNotificationPolicyDoesNotNotifyForOwnMessagesOrHistoryPrepends() {
    let previous = [message(id: "$b")]
    let current = [message(id: "$older", timestamp: 0), message(id: "$b"), message(id: "txn-local", own: true)]
    #expect(
        TimelineNotificationPolicy.incomingMessagesToNotify(
            previousItems: previous,
            currentItems: current,
            lastSeenEventID: "$b"
        ).isEmpty
    )
}

@Test
func timelineNotificationPolicyUsesPreviousSnapshotWhenLastSeenLeavesTheWindow() {
    let previous = [message(id: "$old-window"), message(id: "$kept")]
    let current = [message(id: "$kept"), message(id: "$live", timestamp: 3)]
    let newItems = TimelineNotificationPolicy.incomingMessagesToNotify(
        previousItems: previous,
        currentItems: current,
        lastSeenEventID: "$old-window"
    )
    #expect(newItems.map(\.id) == ["$live"])
}

@Test
func frontmostSuppressionRequiresActiveTimelineForThatRoom() {
    let account = AccountIdentifier(rawValue: "@brandon:example.org")
    let room = RoomIdentifier(rawValue: "!room:example.org")
    let otherRoom = RoomIdentifier(rawValue: "!other:example.org")

    #expect(
        !TimelineNotificationPolicy.shouldSuppressFrontmostRoom(
            appIsActive: true,
            isViewingTimeline: true,
            selectedAccountID: account,
            selectedRoomID: room,
            eventAccountID: account,
            eventRoomID: otherRoom
        )
    )
    #expect(
        TimelineNotificationPolicy.shouldSuppressFrontmostRoom(
            appIsActive: true,
            isViewingTimeline: true,
            selectedAccountID: account,
            selectedRoomID: room,
            eventAccountID: account,
            eventRoomID: room
        )
    )
    #expect(
        !TimelineNotificationPolicy.shouldSuppressFrontmostRoom(
            appIsActive: true,
            isViewingTimeline: false,
            selectedAccountID: account,
            selectedRoomID: room,
            eventAccountID: account,
            eventRoomID: room
        )
    )
    #expect(
        !TimelineNotificationPolicy.shouldSuppressFrontmostRoom(
            appIsActive: false,
            isViewingTimeline: true,
            selectedAccountID: account,
            selectedRoomID: room,
            eventAccountID: account,
            eventRoomID: room
        )
    )
    #expect(
        !TimelineNotificationPolicy.shouldSuppressFrontmostRoom(
            appIsActive: true,
            isViewingTimeline: true,
            selectedAccountID: nil,
            selectedRoomID: nil,
            eventAccountID: account,
            eventRoomID: room
        )
    )
}

@Test
func timelineEventVisibilityHidesGenericAndUnparseableStateEvents() {
    #expect(!TimelineEventVisibilityPolicy.shouldRender(.state))
    #expect(!TimelineEventVisibilityPolicy.shouldRender(.failedToParseState))
    #expect(TimelineEventVisibilityPolicy.shouldRender(.messageLike))
    #expect(TimelineEventVisibilityPolicy.shouldRender(.membership))
}
