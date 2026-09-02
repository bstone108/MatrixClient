import Foundation

/// Room chrome starts collapsed (name only). The name/header toggles the topic.
public enum RoomHeaderExpansionPolicy: Sendable {
    public static let defaultExpanded = false

    public static func expandedAfterToggle(_ isExpanded: Bool) -> Bool {
        !isExpanded
    }

    public static func expandedAfterRoomChange() -> Bool {
        false
    }

    public static func subtitle(for membership: RoomMembership, topic: String) -> String {
        switch membership {
        case .notJoined:
            return topic.isEmpty ? "Not joined" : "Not joined  •  \(topic)"
        case .invited:
            return topic.isEmpty ? "Invited" : "Invited  •  \(topic)"
        case .left:
            return "You left this room"
        case .joined:
            return topic
        }
    }

    public static func showsSubtitle(isExpanded: Bool, subtitle: String) -> Bool {
        isExpanded && !subtitle.isEmpty
    }

    public static func accessibilityLabel(roomName: String, isExpanded: Bool, canRevealSubtitle: Bool) -> String {
        guard canRevealSubtitle else { return roomName }
        if isExpanded {
            return "\(roomName), expanded. Hide room topic."
        }
        return "\(roomName), collapsed. Show room topic."
    }

    public static func accessibilityHelp(canRevealSubtitle: Bool) -> String? {
        canRevealSubtitle ? "Show or hide the room topic" : nil
    }
}
