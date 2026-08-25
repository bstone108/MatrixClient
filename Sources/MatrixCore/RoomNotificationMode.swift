import Foundation

public enum RoomNotificationMode: String, Codable, CaseIterable, Sendable {
    case allMessages
    case mentionsOnly
    case mute

    public var title: String {
        switch self {
        case .allMessages:
            return "All Messages"
        case .mentionsOnly:
            return "Mentions Only"
        case .mute:
            return "Mute"
        }
    }

    public var shortLabel: String? {
        switch self {
        case .allMessages:
            return nil
        case .mentionsOnly:
            return "Mentions"
        case .mute:
            return "Muted"
        }
    }
}

public enum MatrixMentionMatcher: Sendable {
    public static func isMention(
        of userID: String,
        mentionedUserIDs: [String],
        mentionsWholeRoom: Bool,
        body: String
    ) -> Bool {
        if mentionsWholeRoom {
            return true
        }
        if mentionedUserIDs.contains(where: { $0.caseInsensitiveCompare(userID) == .orderedSame }) {
            return true
        }
        return bodyLooksLikeMention(body: body, userID: userID)
    }

    public static func shouldNotify(
        mode: RoomNotificationMode,
        desktopNotificationsEnabled: Bool,
        isMention: Bool
    ) -> Bool {
        guard desktopNotificationsEnabled else { return false }
        switch mode {
        case .allMessages:
            return true
        case .mentionsOnly:
            return isMention
        case .mute:
            return false
        }
    }

    public static func bodyLooksLikeMention(body: String, userID: String) -> Bool {
        let lowered = body.lowercased()
        let loweredUserID = userID.lowercased()
        if lowered.contains(loweredUserID) {
            return true
        }
        let localPart = loweredUserID.split(separator: ":").first.map(String.init) ?? loweredUserID
        let mentionToken = localPart.hasPrefix("@") ? localPart : "@\(localPart)"
        return lowered.split { !$0.isLetter && $0 != "@" && $0 != ":" && $0 != "." && $0 != "_" }.contains { token in
            token == mentionToken || token == localPart
        }
    }
}

public struct RoomNotificationPreferenceStore {
    public static let keyPrefix = "Workspace.notifications.roomMode."

    public static func defaultsKey(accountID: AccountIdentifier, roomID: RoomIdentifier) -> String {
        "\(keyPrefix)\(accountID.rawValue)|\(roomID.rawValue)"
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func mode(accountID: AccountIdentifier, roomID: RoomIdentifier) -> RoomNotificationMode {
        let key = Self.defaultsKey(accountID: accountID, roomID: roomID)
        guard let raw = defaults.string(forKey: key),
              let mode = RoomNotificationMode(rawValue: raw) else {
            return .allMessages
        }
        return mode
    }

    public func setMode(_ mode: RoomNotificationMode, accountID: AccountIdentifier, roomID: RoomIdentifier) {
        let key = Self.defaultsKey(accountID: accountID, roomID: roomID)
        if mode == .allMessages {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(mode.rawValue, forKey: key)
        }
    }
}
