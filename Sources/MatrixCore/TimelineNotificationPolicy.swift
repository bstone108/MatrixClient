import Foundation

public enum TimelineEventVisibility: Sendable {
    case messageLike
    case membership
    case state
    case failedToParseState
}

/// Matrix state is applied to room/session state but is not conversational timeline content.
public enum TimelineEventVisibilityPolicy: Sendable {
    public static func shouldRender(_ event: TimelineEventVisibility) -> Bool {
        switch event {
        case .state, .failedToParseState:
            false
        case .messageLike, .membership:
            true
        }
    }
}

/// History snapshots must not notify; only messages that arrive after a room is primed should.
public enum TimelineNotificationPolicy: Sendable {
    public static func isNotifiableIncomingMessage(_ item: TimelineItem) -> Bool {
        item.kind == .message &&
            !item.isOwnMessage &&
            item.id.hasPrefix("$") &&
            !item.isDeleted
    }

    /// New incoming messages in `currentItems` that should produce a banner.
    /// Returns an empty list for the first snapshot (no previous items and no last-seen ID in the current list).
    public static func incomingMessagesToNotify(
        previousItems: [TimelineItem],
        currentItems: [TimelineItem],
        lastSeenEventID: String?
    ) -> [TimelineItem] {
        if let lastSeenEventID,
           let lastSeenIndex = currentItems.lastIndex(where: { $0.id == lastSeenEventID }) {
            return currentItems.suffix(from: lastSeenIndex + 1).filter(isNotifiableIncomingMessage)
        }

        let previousIDs = Set(previousItems.map(\.id))
        guard !previousIDs.isEmpty else {
            return []
        }
        return currentItems.filter { item in
            !previousIDs.contains(item.id) && isNotifiableIncomingMessage(item)
        }
    }

    /// Suppress banners only when the user is actively looking at that room's timeline.
    public static func shouldSuppressFrontmostRoom(
        appIsActive: Bool,
        isViewingTimeline: Bool,
        selectedAccountID: AccountIdentifier?,
        selectedRoomID: RoomIdentifier?,
        eventAccountID: AccountIdentifier,
        eventRoomID: RoomIdentifier
    ) -> Bool {
        guard appIsActive, isViewingTimeline else { return false }
        guard let selectedAccountID, let selectedRoomID else { return false }
        return selectedAccountID == eventAccountID && selectedRoomID == eventRoomID
    }
}
