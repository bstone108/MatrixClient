import Foundation
import MatrixCore
import Testing

@Test
func mentionMatcherDetectsMatrixMentionsAndRoomWidePings() {
    #expect(
        MatrixMentionMatcher.isMention(
            of: "@brandon:example.org",
            mentionedUserIDs: ["@brandon:example.org"],
            mentionsWholeRoom: false,
            body: "hello"
        )
    )
    #expect(
        MatrixMentionMatcher.isMention(
            of: "@brandon:example.org",
            mentionedUserIDs: [],
            mentionsWholeRoom: true,
            body: "@room meeting"
        )
    )
    #expect(
        MatrixMentionMatcher.isMention(
            of: "@brandon:example.org",
            mentionedUserIDs: [],
            mentionsWholeRoom: false,
            body: "Hey @brandon can you look?"
        )
    )
    #expect(
        !MatrixMentionMatcher.isMention(
            of: "@brandon:example.org",
            mentionedUserIDs: ["@casey:example.org"],
            mentionsWholeRoom: false,
            body: "no mention here"
        )
    )
}

@Test
func notificationModesHonorGlobalDesktopAndPerRoomMute() {
    #expect(
        MatrixMentionMatcher.shouldNotify(
            mode: .allMessages,
            desktopNotificationsEnabled: true,
            isMention: false
        )
    )
    #expect(
        !MatrixMentionMatcher.shouldNotify(
            mode: .mentionsOnly,
            desktopNotificationsEnabled: true,
            isMention: false
        )
    )
    #expect(
        MatrixMentionMatcher.shouldNotify(
            mode: .mentionsOnly,
            desktopNotificationsEnabled: true,
            isMention: true
        )
    )
    #expect(
        !MatrixMentionMatcher.shouldNotify(
            mode: .mute,
            desktopNotificationsEnabled: true,
            isMention: true
        )
    )
    #expect(
        !MatrixMentionMatcher.shouldNotify(
            mode: .allMessages,
            desktopNotificationsEnabled: false,
            isMention: true
        )
    )
}

@Test
func roomNotificationPreferenceStoreDefaultsToAllMessagesAndKeysByAccountAndRoom() {
    let defaults = UserDefaults(suiteName: "MatrixClient.RoomNotificationPreferenceTests")!
    defaults.removePersistentDomain(forName: "MatrixClient.RoomNotificationPreferenceTests")
    let store = RoomNotificationPreferenceStore(defaults: defaults)
    let account = AccountIdentifier(rawValue: "@brandon:example.org")
    let room = RoomIdentifier(rawValue: "!room:example.org")

    #expect(store.mode(accountID: account, roomID: room) == .allMessages)
    store.setMode(.mentionsOnly, accountID: account, roomID: room)
    #expect(store.mode(accountID: account, roomID: room) == .mentionsOnly)
    store.setMode(.mute, accountID: account, roomID: room)
    #expect(store.mode(accountID: account, roomID: room) == .mute)
    store.setMode(.allMessages, accountID: account, roomID: room)
    #expect(store.mode(accountID: account, roomID: room) == .allMessages)
    #expect(defaults.string(forKey: RoomNotificationPreferenceStore.defaultsKey(accountID: account, roomID: room)) == nil)
}
