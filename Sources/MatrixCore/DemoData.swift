import Foundation

enum DemoData {
    static func accountSummaries() -> [AccountSummary] {
        [
            AccountSummary(
                accountID: AccountIdentifier(rawValue: "acct-brandon"),
                displayName: "Brandon",
                userID: "@brandon:example.org",
                homeserver: URL(string: "https://matrix.example.org")!,
                avatarSymbolName: "person.crop.circle.fill"
            ),
            AccountSummary(
                accountID: AccountIdentifier(rawValue: "acct-ops"),
                displayName: "Ops",
                userID: "@ops:example.org",
                homeserver: URL(string: "https://ops.example.org")!,
                avatarSymbolName: "bolt.circle.fill"
            )
        ]
    }

    static func spaces(for accountID: AccountIdentifier) -> [SpaceSummary] {
        switch accountID.rawValue {
        case "acct-brandon":
            return [
                SpaceSummary(
                    spaceID: SpaceIdentifier(rawValue: "space-home"),
                    displayName: "Home",
                    unreadCount: 5,
                    roomIDs: [RoomIdentifier(rawValue: "!general:example.org"), RoomIdentifier(rawValue: "!design:example.org"), RoomIdentifier(rawValue: "!media:example.org")]
                ),
                SpaceSummary(
                    spaceID: SpaceIdentifier(rawValue: "space-build"),
                    displayName: "Build Farm",
                    unreadCount: 1,
                    roomIDs: [RoomIdentifier(rawValue: "!ops:example.org"), RoomIdentifier(rawValue: "!alerts:example.org")]
                )
            ]
        default:
            return [
                SpaceSummary(
                    spaceID: SpaceIdentifier(rawValue: "space-ops"),
                    displayName: "Operations",
                    unreadCount: 2,
                    roomIDs: [RoomIdentifier(rawValue: "!ops:example.org"), RoomIdentifier(rawValue: "!bridge:example.org")]
                )
            ]
        }
    }

    static func rooms(for accountID: AccountIdentifier) -> [RoomSummary] {
        let now = Date()
        return [
            RoomSummary(
                roomID: RoomIdentifier(rawValue: "!general:example.org"),
                displayName: "General",
                topic: "Main workspace chatter",
                lastMessagePreview: "Let’s keep the shell native and keep the main actor clean.",
                timestamp: now.addingTimeInterval(-120),
                unreadCount: 2,
                highlightCount: 0,
                isDirect: false,
                isEncrypted: true,
                lastSenderDisplayName: "Casey"
            ),
            RoomSummary(
                roomID: RoomIdentifier(rawValue: "!design:example.org"),
                displayName: "Design Review",
                topic: "Desktop layout and inspector experiments",
                lastMessagePreview: "The right panel should stay collapsible.",
                timestamp: now.addingTimeInterval(-900),
                unreadCount: 0,
                highlightCount: 0,
                isDirect: false,
                isEncrypted: true,
                lastSenderDisplayName: "Morgan"
            ),
            RoomSummary(
                roomID: RoomIdentifier(rawValue: "!media:example.org"),
                displayName: "Media Lab",
                topic: "Stress-testing image and video playback",
                lastMessagePreview: "VLC fallback handles the weird containers cleanly.",
                timestamp: now.addingTimeInterval(-2_500),
                unreadCount: 3,
                highlightCount: 1,
                isDirect: false,
                isEncrypted: true,
                lastSenderDisplayName: "Taylor"
            ),
            RoomSummary(
                roomID: RoomIdentifier(rawValue: "!ops:example.org"),
                displayName: "Ops",
                topic: "Deployments and alerting",
                lastMessagePreview: "Sliding sync cache warmed in 180ms.",
                timestamp: now.addingTimeInterval(-600),
                unreadCount: 1,
                highlightCount: 1,
                isDirect: false,
                isEncrypted: true,
                lastSenderDisplayName: "NOC Bot"
            ),
            RoomSummary(
                roomID: RoomIdentifier(rawValue: "!alerts:example.org"),
                displayName: "Alerts",
                topic: "Critical paging room",
                lastMessagePreview: "Queue drain recovered after network flap.",
                timestamp: now.addingTimeInterval(-1_800),
                unreadCount: 0,
                highlightCount: 0,
                isDirect: false,
                isEncrypted: false,
                lastSenderDisplayName: "Pager"
            ),
            RoomSummary(
                roomID: RoomIdentifier(rawValue: "!bridge:example.org"),
                displayName: "Bridge",
                topic: "Protocol bridge status",
                lastMessagePreview: "Cross-signing verification completed.",
                timestamp: now.addingTimeInterval(-3_200),
                unreadCount: 2,
                highlightCount: 0,
                isDirect: false,
                isEncrypted: true,
                lastSenderDisplayName: "Bridge Bot"
            )
        ]
    }

    static func roomDetails(for roomID: RoomIdentifier) -> RoomDetails {
        RoomDetails(
            roomID: roomID,
            displayName: roomName(roomID),
            topic: roomTopic(roomID),
            isEncrypted: roomID.rawValue != "!alerts:example.org",
            memberCount: Int.random(in: 8...42),
            pinnedMessages: [
                "Recovery key rotation checklist",
                "Spaces navigation polish notes"
            ]
        )
    }

    static func timelineSeed(for accountID: AccountIdentifier) -> [RoomIdentifier: [TimelineItem]] {
        let brandon = accountSummaries().first(where: { $0.accountID == accountID }) ?? accountSummaries()[0]
        let now = Date()

        func receipt(_ name: String, _ offset: TimeInterval) -> ReadReceipt {
            ReadReceipt(userID: "@\(name.lowercased()):example.org", displayName: name, readAt: now.addingTimeInterval(offset))
        }

        let rooms = Self.rooms(for: accountID)
        return Dictionary(uniqueKeysWithValues: rooms.map { room in
            let items = [
                TimelineItem(
                    id: "\(room.roomID.rawValue)-1",
                    roomID: room.roomID,
                    senderID: "@casey:example.org",
                    senderDisplayName: "Casey",
                    body: "Room bootstrap is seeded from a local sliding-sync style cache so the UI paints immediately.",
                    timestamp: now.addingTimeInterval(-3_600),
                    isOwnMessage: false,
                    isEncrypted: room.isEncrypted,
                    receipts: ReceiptSummary(sentAt: now.addingTimeInterval(-3_600), deliveredAt: now.addingTimeInterval(-3_590), readReceipts: [receipt("Morgan", -3_400)])
                ),
                TimelineItem(
                    id: "\(room.roomID.rawValue)-2",
                    roomID: room.roomID,
                    senderID: brandon.userID,
                    senderDisplayName: brandon.displayName,
                    body: "Send queue stays durable and never marks transient timeouts as user-facing failures.",
                    timestamp: now.addingTimeInterval(-2_400),
                    isOwnMessage: true,
                    isEncrypted: room.isEncrypted,
                    deliveryState: .echoed,
                    receipts: ReceiptSummary(
                        sentAt: now.addingTimeInterval(-2_400),
                        deliveredAt: now.addingTimeInterval(-2_398),
                        readReceipts: [receipt("Casey", -2_200), receipt("Morgan", -2_050)]
                    )
                ),
                TimelineItem(
                    id: "\(room.roomID.rawValue)-3",
                    roomID: room.roomID,
                    senderID: "@morgan:example.org",
                    senderDisplayName: "Morgan",
                    body: "Desktop shell should keep the timeline smooth even in large rooms.",
                    timestamp: now.addingTimeInterval(-600),
                    isOwnMessage: false,
                    isEncrypted: room.isEncrypted,
                    replyPreview: "Send queue stays durable",
                    threadReplyCount: 2,
                    receipts: ReceiptSummary(sentAt: now.addingTimeInterval(-600), deliveredAt: now.addingTimeInterval(-590), readReceipts: [])
                )
            ]
            return (room.roomID, items)
        })
    }

    private static func roomName(_ roomID: RoomIdentifier) -> String {
        rooms(for: AccountIdentifier(rawValue: "acct-brandon"))
            .first(where: { $0.roomID == roomID })?.displayName ?? "Room"
    }

    private static func roomTopic(_ roomID: RoomIdentifier) -> String {
        rooms(for: AccountIdentifier(rawValue: "acct-brandon"))
            .first(where: { $0.roomID == roomID })?.topic ?? "Topic"
    }
}
