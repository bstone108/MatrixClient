import Foundation
@testable import MatrixCore
import Testing

@Test
func initialSDKWindowRetainsOlderPersistedTimelineItems() {
    let roomID = RoomIdentifier(rawValue: "!room:test")
    let cachedOlder = TimelineItem(
        id: "$cached-older:test",
        roomID: roomID,
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "cached older",
        timestamp: Date(timeIntervalSince1970: 100),
        isOwnMessage: false,
        isEncrypted: true
    )
    let cachedLatest = TimelineItem(
        id: "$cached-latest:test",
        roomID: roomID,
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "cached latest",
        timestamp: Date(timeIntervalSince1970: 200),
        isOwnMessage: false,
        isEncrypted: true
    )
    let sdkWindowLatest = TimelineItem(
        id: "$cached-latest:test",
        roomID: roomID,
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "SDK latest",
        timestamp: Date(timeIntervalSince1970: 200),
        isOwnMessage: false,
        isEncrypted: true
    )

    let merged = TimelineItemReconciler.mergedInitialSDKWindow(
        sdkItems: [sdkWindowLatest],
        cachedDisplayItems: [cachedOlder, cachedLatest]
    )

    #expect(merged.map(\.id) == ["$cached-older:test", "$cached-latest:test"])
    #expect(merged.last?.body == "SDK latest")
}

@Test
func paginatedOlderEventStaysBeforeLatestAfterHistoryMerge() {
    let roomID = RoomIdentifier(rawValue: "!room:test")
    let latest = TimelineItem(
        id: "$latest:test",
        roomID: roomID,
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "latest",
        timestamp: Date(timeIntervalSince1970: 200),
        isOwnMessage: false,
        isEncrypted: true
    )
    let paginatedOlder = TimelineItem(
        id: "$older:test",
        roomID: roomID,
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "older",
        timestamp: Date(timeIntervalSince1970: 100),
        isOwnMessage: false,
        isEncrypted: true
    )

    let merged = TimelineItemReconciler.chronologicallyOrdered(
        TimelineItemReconciler.deduplicated([latest, paginatedOlder, latest])
    )

    #expect(merged.map(\.id) == ["$older:test", "$latest:test"])
}

@Test
func remoteEchoReplacesQueuedLocalEchoUsingTransactionID() {
    let transactionID = EventTransactionIdentifier(rawValue: "txn-123")
    let queued = TimelineItem(
        id: transactionID.rawValue,
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "hello",
        timestamp: .now,
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .queued,
        transactionID: transactionID
    )
    let remote = TimelineItem(
        id: "$event:test",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "hello",
        timestamp: .now,
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .accepted,
        receipts: ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: []),
        transactionID: transactionID
    )

    let reconciled = TimelineItemReconciler.deduplicated([queued, remote])

    #expect(reconciled.count == 1)
    #expect(reconciled[0].id == "$event:test")
    #expect(reconciled[0].deliveryState == .accepted)
}

@Test
func redactionKeepsExistingBodyAndMediaUntilRetentionDropsIt() {
    let existing = TimelineItem(
        id: "$event:test",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "Keep me",
        timestamp: .now,
        isOwnMessage: false,
        isEncrypted: true
    )
    let redacted = TimelineItem(
        id: "$event:test",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@alice:test",
        senderDisplayName: "Alice",
        body: "Message removed",
        timestamp: .now,
        isOwnMessage: false,
        isEncrypted: true,
        isDeleted: true,
        deletedAt: .now
    )

    let merged = TimelineItemReconciler.merge(redacted, into: [existing])

    #expect(merged.isDeleted)
    #expect(merged.body == "Keep me")
}

@Test
func remoteEchoReplacesQueuedLocalEchoUsingOwnMessageHeuristics() {
    let timestamp = Date()
    let localEcho = TimelineItem(
        id: "local-echo",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "same text",
        timestamp: timestamp,
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .queued,
        transactionID: nil
    )
    let remote = TimelineItem(
        id: "$event:test",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "same text",
        timestamp: timestamp.addingTimeInterval(1),
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .accepted,
        receipts: ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: []),
        transactionID: nil
    )

    let reconciled = TimelineItemReconciler.deduplicated([localEcho, remote])

    #expect(reconciled.count == 1)
    #expect(reconciled[0].id == "$event:test")
    #expect(reconciled[0].deliveryState == .accepted)
}

@Test
func authoritativeRemoteEchoWinsIfLocalEchoArrivesLater() {
    let timestamp = Date()
    let remote = TimelineItem(
        id: "$event:test",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "same text",
        timestamp: timestamp,
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .accepted,
        receipts: ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: [])
    )
    let localEcho = TimelineItem(
        id: "local-echo",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "same text",
        timestamp: timestamp.addingTimeInterval(2),
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .sending
    )

    let reconciled = TimelineItemReconciler.deduplicated([remote, localEcho])

    #expect(reconciled.count == 1)
    #expect(reconciled[0].id == "$event:test")
    #expect(reconciled[0].deliveryState == .accepted)
}

@Test
func pendingOwnMessageIsUpgradedWhenRemoteEchoDiffersSlightly() {
    let timestamp = Date()
    let localEcho = TimelineItem(
        id: "local-echo",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "hello  ",
        timestamp: timestamp,
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .sending,
        transactionID: EventTransactionIdentifier(rawValue: "txn-1")
    )
    let remote = TimelineItem(
        id: "$event:test",
        roomID: RoomIdentifier(rawValue: "!room:test"),
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "hello",
        timestamp: timestamp.addingTimeInterval(2),
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .accepted
    )

    let repaired = TimelineItemReconciler.repairedPendingRemoteEchoes(in: [localEcho, remote])

    #expect(repaired.count == 1)
    #expect(repaired[0].id == "$event:test")
    #expect(repaired[0].deliveryState == .accepted)
}

@Test
func normalizedReadReceiptsKeepOnlyLatestMessagePerReader() {
    let roomID = RoomIdentifier(rawValue: "!room:test")
    let oldItem = TimelineItem(
        id: "$event-1:test",
        roomID: roomID,
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "older",
        timestamp: Date(timeIntervalSince1970: 100),
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .echoed,
        receipts: ReceiptSummary(
            sentAt: nil,
            deliveredAt: nil,
            readReceipts: [ReadReceipt(userID: "@alice:test", displayName: "Alice", readAt: Date(timeIntervalSince1970: 101))]
        )
    )
    let newItem = TimelineItem(
        id: "$event-2:test",
        roomID: roomID,
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "newer",
        timestamp: Date(timeIntervalSince1970: 200),
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .accepted,
        receipts: ReceiptSummary(
            sentAt: nil,
            deliveredAt: nil,
            readReceipts: [ReadReceipt(userID: "@alice:test", displayName: "Alice", readAt: Date(timeIntervalSince1970: 201))]
        )
    )

    let normalized = TimelineItemReconciler.normalizedReadReceipts(in: [oldItem, newItem])

    #expect(normalized[0].receipts.readReceipts.isEmpty)
    #expect(normalized[0].deliveryState == .accepted)
    #expect(normalized[1].receipts.readReceipts.map(\.userID) == ["@alice:test"])
    #expect(normalized[1].deliveryState == .echoed)
}

@Test
func normalizedReadReceiptsRemovesDuplicateReadersOnSameEvent() {
    let roomID = RoomIdentifier(rawValue: "!room:test")
    let duplicated = TimelineItem(
        id: "$event:test",
        roomID: roomID,
        senderID: "@me:test",
        senderDisplayName: "Me",
        body: "hello",
        timestamp: Date(timeIntervalSince1970: 100),
        isOwnMessage: true,
        isEncrypted: true,
        deliveryState: .echoed,
        receipts: ReceiptSummary(
            sentAt: nil,
            deliveredAt: nil,
            readReceipts: [
                ReadReceipt(userID: "@alice:test", displayName: "Alice", readAt: Date(timeIntervalSince1970: 101)),
                ReadReceipt(userID: "@alice:test", displayName: "Alice", readAt: Date(timeIntervalSince1970: 102)),
                ReadReceipt(userID: "@bob:test", displayName: "Bob", readAt: nil)
            ]
        )
    )

    let normalized = TimelineItemReconciler.normalizedReadReceipts(in: [duplicated])

    #expect(normalized[0].receipts.readReceipts.count == 2)
    #expect(Set(normalized[0].receipts.readReceipts.map(\.userID)) == Set(["@alice:test", "@bob:test"]))
}
