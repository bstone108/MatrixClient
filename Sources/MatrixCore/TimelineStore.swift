import Foundation

public actor TimelineStore {
    private var itemsByRoom: [RoomIdentifier: [TimelineItem]]
    private var broadcasters: [RoomIdentifier: AsyncBroadcaster<[TimelineItem]>] = [:]

    public init(seed: [RoomIdentifier: [TimelineItem]] = [:]) {
        itemsByRoom = seed
    }

    public func stream(for roomID: RoomIdentifier) -> AsyncStream<[TimelineItem]> {
        if broadcasters[roomID] == nil {
            broadcasters[roomID] = AsyncBroadcaster(initialValue: itemsByRoom[roomID, default: []])
        }
        return broadcasters[roomID]!.stream()
    }

    public func snapshot(for roomID: RoomIdentifier) -> [TimelineItem] {
        itemsByRoom[roomID, default: []]
    }

    public func replace(items: [TimelineItem], for roomID: RoomIdentifier) {
        itemsByRoom[roomID] = items
        if broadcasters[roomID] == nil {
            broadcasters[roomID] = AsyncBroadcaster(initialValue: items)
        } else {
            broadcasters[roomID]?.yield(items)
        }
    }

    public func clear(roomID: RoomIdentifier) {
        replace(items: [], for: roomID)
    }

    public func appendLocalMessage(
        roomID: RoomIdentifier,
        senderID: String,
        senderDisplayName: String,
        body: String,
        encrypted: Bool
    ) -> TimelineItem {
        let transactionID = EventTransactionIdentifier()
        let item = TimelineItem(
            id: transactionID.rawValue,
            roomID: roomID,
            senderID: senderID,
            senderDisplayName: senderDisplayName,
            body: body,
            timestamp: .now,
            isOwnMessage: true,
            isEncrypted: encrypted,
            deliveryState: .queued,
            receipts: ReceiptSummary(sentAt: nil, deliveredAt: nil, readReceipts: []),
            transactionID: transactionID
        )
        itemsByRoom[roomID, default: []].append(item)
        broadcasters[roomID]?.yield(itemsByRoom[roomID, default: []])
        return item
    }

    public func updateDeliveryState(
        roomID: RoomIdentifier,
        transactionID: EventTransactionIdentifier,
        state: MessageDeliveryState,
        eventID: String? = nil
    ) {
        guard var items = itemsByRoom[roomID] else { return }
        guard let index = items.firstIndex(where: { $0.transactionID == transactionID }) else { return }
        let current = items[index]
        items[index] = TimelineItem(
            id: eventID ?? current.id,
            roomID: current.roomID,
            senderID: current.senderID,
            senderDisplayName: current.senderDisplayName,
            body: current.body,
            timestamp: current.timestamp,
            kind: current.kind,
            media: current.media,
            status: current.status,
            isOwnMessage: current.isOwnMessage,
            isEncrypted: current.isEncrypted,
            isEdited: current.isEdited,
            replyPreview: current.replyPreview,
            threadReplyCount: current.threadReplyCount,
            deliveryState: state,
            receipts: ReceiptSummary(
                sentAt: state == .queued ? nil : current.timestamp,
                deliveredAt: (state == .accepted || state == .echoed) ? .now : nil,
                readReceipts: state == .echoed ? [ReadReceipt(userID: "@relay:server", displayName: "Sliding Sync", readAt: .now)] : current.receipts.readReceipts
            ),
            transactionID: current.transactionID,
            isDeleted: current.isDeleted,
            deletedAt: current.deletedAt
        )
        itemsByRoom[roomID] = items
        broadcasters[roomID]?.yield(items)
    }
}
