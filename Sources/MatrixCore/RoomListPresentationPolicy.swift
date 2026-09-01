import Foundation

public enum RoomListSectionKind: Equatable, Sendable {
    case invites
    case rooms
    case other
}

public struct RoomListSection: Equatable, Sendable {
    public let kind: RoomListSectionKind
    public let title: String
    public let rooms: [RoomSummary]

    public init(kind: RoomListSectionKind, title: String, rooms: [RoomSummary]) {
        self.kind = kind
        self.title = title
        self.rooms = rooms
    }
}

/// Room-list titles, accessibility strings, and unread-first ordering.
public enum RoomListPresentationPolicy: Sendable {
    public static func hasUnread(_ room: RoomSummary) -> Bool {
        room.membership == .joined && visibleUnreadCount(for: room) > 0
    }

    public static func visibleUnreadCount(for room: RoomSummary) -> Int {
        max(room.unreadCount, room.highlightCount)
    }

    /// Unread count is part of the room name, not only a trailing badge.
    public static func displayTitle(for room: RoomSummary) -> String {
        let count = visibleUnreadCount(for: room)
        guard room.membership == .joined, count > 0 else {
            return room.displayName
        }
        return "\(room.displayName) (\(count))"
    }

    public static func accessibilityLabel(for room: RoomSummary) -> String {
        let count = visibleUnreadCount(for: room)
        if room.membership == .joined, count > 0 {
            let noun = count == 1 ? "unread message" : "unread messages"
            return "\(room.displayName), \(count) \(noun)"
        }
        switch room.membership {
        case .invited:
            return "\(room.displayName), invited"
        case .notJoined:
            return "\(room.displayName), not joined"
        case .left:
            return "\(room.displayName), left"
        case .joined:
            return room.displayName
        }
    }

    public static func sections(rooms: [RoomSummary], inSpace: Bool) -> [RoomListSection] {
        let invites = sorted(rooms.filter { $0.membership == .invited }, unreadFirst: false)
        let joined = sorted(rooms.filter { $0.membership == .joined }, unreadFirst: true)
        let other = sorted(
            rooms.filter { $0.membership != .joined && $0.membership != .invited },
            unreadFirst: false
        )

        var sections: [RoomListSection] = []
        if !invites.isEmpty {
            sections.append(RoomListSection(kind: .invites, title: "Invites", rooms: invites))
        }
        if !joined.isEmpty {
            sections.append(RoomListSection(
                kind: .rooms,
                title: inSpace ? "Joined rooms" : "Rooms",
                rooms: joined
            ))
        }
        if !other.isEmpty {
            sections.append(RoomListSection(
                kind: .other,
                title: inSpace ? "Not joined" : "Other",
                rooms: other
            ))
        }
        return sections
    }

    public static func sorted(_ rooms: [RoomSummary], unreadFirst: Bool) -> [RoomSummary] {
        rooms.sorted { lhs, rhs in
            if unreadFirst {
                let leftUnread = hasUnread(lhs)
                let rightUnread = hasUnread(rhs)
                if leftUnread != rightUnread {
                    return leftUnread && !rightUnread
                }
                if leftUnread, rightUnread {
                    let leftCount = visibleUnreadCount(for: lhs)
                    let rightCount = visibleUnreadCount(for: rhs)
                    if leftCount != rightCount {
                        return leftCount > rightCount
                    }
                }
            }
            if lhs.timestamp != rhs.timestamp {
                return lhs.timestamp > rhs.timestamp
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }
}
