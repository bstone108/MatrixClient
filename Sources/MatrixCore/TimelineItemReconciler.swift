import Foundation

enum TimelineItemReconciler {
    static func merge(_ incoming: TimelineItem, into existingItems: [TimelineItem]) -> TimelineItem {
        guard let existingItem = matchingExistingItem(for: incoming, in: existingItems) else {
            return incoming
        }

        return merged(existing: existingItem, incoming: incoming)
    }

    static func deduplicated(_ items: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return [] }

        var result: [TimelineItem] = []
        var indexByID: [String: Int] = [:]
        var indexByTransactionID: [EventTransactionIdentifier: Int] = [:]

        for item in items {
            let matchingIndex = indexByID[item.id]
                ?? item.transactionID.flatMap { indexByTransactionID[$0] }
                ?? heuristicMatchIndex(for: item, in: result)

            if let matchingIndex {
                let mergedItem = merged(existing: result[matchingIndex], incoming: item)
                result[matchingIndex] = mergedItem
                indexByID[mergedItem.id] = matchingIndex
                if let transactionID = mergedItem.transactionID {
                    indexByTransactionID[transactionID] = matchingIndex
                }
            } else {
                let nextIndex = result.count
                result.append(item)
                indexByID[item.id] = nextIndex
                if let transactionID = item.transactionID {
                    indexByTransactionID[transactionID] = nextIndex
                }
            }
        }

        return result
    }

    /// The SDK window and retained app history can overlap. Newly paginated
    /// older events must remain before the latest event after that overlap is
    /// deduplicated, regardless of whether the SDK delivered them via
    /// `pushFront` or `insert`.
    static func chronologicallyOrdered(_ items: [TimelineItem]) -> [TimelineItem] {
        items.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The first SDK callback commonly contains only its bounded live window.
    /// Keep older locally persisted display rows until SDK pagination catches
    /// up, while allowing the SDK copy of an overlapping event to refresh it.
    static func mergedInitialSDKWindow(
        sdkItems: [TimelineItem],
        cachedDisplayItems: [TimelineItem]
    ) -> [TimelineItem] {
        chronologicallyOrdered(deduplicated(cachedDisplayItems + sdkItems))
    }

    static func normalizedReadReceipts(in items: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return [] }

        var latestReceiptPlacementByUserID: [String: Int] = [:]
        var latestReceiptByUserID: [String: ReadReceipt] = [:]

        for (index, item) in items.enumerated() where item.kind == .message && item.isOwnMessage {
            for receipt in item.receipts.readReceipts {
                latestReceiptPlacementByUserID[receipt.userID] = index
                latestReceiptByUserID[receipt.userID] = receipt
            }
        }

        guard !latestReceiptPlacementByUserID.isEmpty else {
            return items.map { item in
                guard item.kind == .message && item.isOwnMessage else { return item }
                return itemWithNormalizedReceipts(item, readReceipts: [])
            }
        }

        var receiptsByIndex: [Int: [ReadReceipt]] = [:]
        for (userID, index) in latestReceiptPlacementByUserID {
            guard let receipt = latestReceiptByUserID[userID] else { continue }
            receiptsByIndex[index, default: []].append(receipt)
        }

        return items.enumerated().map { index, item in
            guard item.kind == .message && item.isOwnMessage else { return item }
            let normalizedReceipts = sortedReceipts(receiptsByIndex[index] ?? [])
            return itemWithNormalizedReceipts(item, readReceipts: normalizedReceipts)
        }
    }

    static func repairedPendingRemoteEchoes(in items: [TimelineItem]) -> [TimelineItem] {
        guard !items.isEmpty else { return [] }

        var mergedIndices: Set<Int> = []
        var result = items

        for localIndex in result.indices {
            let localItem = result[localIndex]
            guard isLocallyPendingOwnMessage(localItem) else { continue }
            guard let remoteIndex = matchingRemoteEchoIndex(for: localItem, in: result, excluding: mergedIndices) else {
                continue
            }

            let remoteItem = result[remoteIndex]
            result[localIndex] = merged(existing: localItem, incoming: remoteItem)
            mergedIndices.insert(remoteIndex)
        }

        guard !mergedIndices.isEmpty else { return result }

        return result.enumerated().compactMap { index, item in
            mergedIndices.contains(index) ? nil : item
        }
    }

    private static func matchingExistingItem(for item: TimelineItem, in items: [TimelineItem]) -> TimelineItem? {
        if let transactionID = item.transactionID,
           let match = items.last(where: { $0.transactionID == transactionID }) {
            return match
        }

        if let exactMatch = items.last(where: { $0.id == item.id }) {
            return exactMatch
        }

        if let matchIndex = heuristicMatchIndex(for: item, in: items) {
            return items[matchIndex]
        }

        return nil
    }

    private static func heuristicMatchIndex(for item: TimelineItem, in items: [TimelineItem]) -> Int? {
        guard shouldUseLocalEchoHeuristic(for: item) else { return nil }

        for index in items.indices.reversed() {
            if shouldHeuristicallyMerge(existing: items[index], incoming: item) {
                return index
            }
        }

        return nil
    }

    private static func shouldUseLocalEchoHeuristic(for item: TimelineItem) -> Bool {
        item.kind == .message && item.isOwnMessage
    }

    private static func isLocallyPendingOwnMessage(_ item: TimelineItem) -> Bool {
        item.kind == .message &&
            item.isOwnMessage &&
            !item.id.hasPrefix("$") &&
            (item.deliveryState == .queued || item.deliveryState == .sending)
    }

    private static func shouldHeuristicallyMerge(existing: TimelineItem, incoming: TimelineItem) -> Bool {
        guard existing.kind == .message,
              incoming.kind == .message,
              existing.roomID == incoming.roomID,
              existing.senderID == incoming.senderID,
              existing.isOwnMessage,
              incoming.isOwnMessage,
              contentSignature(for: existing) == contentSignature(for: incoming),
              timestampsAreClose(existing.timestamp, incoming.timestamp) else {
            return false
        }

        let existingHasRemoteID = existing.id.hasPrefix("$")
        let incomingHasRemoteID = incoming.id.hasPrefix("$")
        guard existingHasRemoteID != incomingHasRemoteID else {
            return false
        }

        return isPendingLocalEcho(existing) || isPendingLocalEcho(incoming)
    }

    private static func isPendingLocalEcho(_ item: TimelineItem) -> Bool {
        guard !item.id.hasPrefix("$") else { return false }
        switch item.deliveryState {
        case .queued, .sending, .none:
            return true
        case .echoed, .permanentFailure:
            return false
        case .accepted:
            return false
        }
    }

    private static func matchingRemoteEchoIndex(
        for localItem: TimelineItem,
        in items: [TimelineItem],
        excluding mergedIndices: Set<Int>
    ) -> Int? {
        var bestIndex: Int?
        var bestScore = Int.min

        for index in items.indices where !mergedIndices.contains(index) {
            let candidate = items[index]
            guard candidate.kind == .message,
                  candidate.isOwnMessage,
                  candidate.id.hasPrefix("$"),
                  candidate.roomID == localItem.roomID,
                  candidate.senderID == localItem.senderID,
                  !candidate.isDeleted,
                  timestampsAreClose(localItem.timestamp, candidate.timestamp) else {
                continue
            }

            let score = contentSimilarityScore(localItem, candidate)
            guard score > bestScore else { continue }
            bestScore = score
            bestIndex = index
        }

        return bestScore >= 50 ? bestIndex : nil
    }

    private static func contentSimilarityScore(_ lhs: TimelineItem, _ rhs: TimelineItem) -> Int {
        var score = 0

        if normalizedBody(lhs.body) == normalizedBody(rhs.body) {
            score += 60
        }
        if normalizedBody(lhs.replyPreview ?? "") == normalizedBody(rhs.replyPreview ?? "") {
            score += 15
        }
        if mediaSignature(lhs) == mediaSignature(rhs) {
            score += 40
        }
        if lhs.media == nil, rhs.media == nil {
            score += 10
        }
        if lhs.isEncrypted == rhs.isEncrypted {
            score += 5
        }
        score -= Int(abs(lhs.timestamp.timeIntervalSince(rhs.timestamp)))
        return score
    }

    private static func mediaSignature(_ item: TimelineItem) -> String {
        item.media.map {
            "\($0.kind.rawValue)|\($0.sourceURL)|\($0.thumbnailSourceURL ?? "")|\($0.filename ?? "")"
        } ?? ""
    }

    private static func normalizedBody(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\r\n", with: "\n")
    }

    private static func contentSignature(for item: TimelineItem) -> String {
        let mediaSignature = item.media.map {
            "\($0.kind.rawValue)|\($0.sourceURL)|\($0.filename ?? "")"
        } ?? ""
        let statusSignature = item.status.map {
            "\($0.actorID)|\($0.actorDisplayName)|\($0.action.rawValue)"
        } ?? ""
        return [
            item.body,
            item.replyPreview ?? "",
            mediaSignature,
            statusSignature,
            item.isDeleted ? "deleted" : "live"
        ].joined(separator: "|")
    }

    private static func timestampsAreClose(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) <= 600
    }

    private static func merged(existing: TimelineItem, incoming: TimelineItem) -> TimelineItem {
        let primary = preferredAuthoritativeItem(existing: existing, incoming: incoming)
        let secondary = primary == existing ? incoming : existing

        let effectiveReceipts: ReceiptSummary
        if incoming.receipts.readReceipts.isEmpty, !existing.receipts.readReceipts.isEmpty {
            effectiveReceipts = existing.receipts
        } else {
            effectiveReceipts = incoming.receipts
        }

        let effectiveEventID: String?
        if incoming.id.hasPrefix("$") {
            effectiveEventID = incoming.id
        } else if existing.id.hasPrefix("$") {
            effectiveEventID = existing.id
        } else {
            effectiveEventID = nil
        }

        let effectiveDeliveryState = MessageDeliveryState.reconciled(
            mappedState: preferredDeliveryState(primary: primary, secondary: secondary),
            isOwnMessage: primary.isOwnMessage || secondary.isOwnMessage,
            eventID: effectiveEventID,
            hasReadReceipts: !effectiveReceipts.readReceipts.isEmpty
        )

        guard incoming.isDeleted else {
            return TimelineItem(
                id: primary.id,
                roomID: primary.roomID,
                senderID: primary.senderID,
                senderDisplayName: primary.senderDisplayName,
                body: primary.body,
                timestamp: primary.timestamp,
                kind: primary.kind,
                media: primary.media,
                status: primary.status,
                isOwnMessage: primary.isOwnMessage,
                isEncrypted: primary.isEncrypted,
                isEdited: primary.isEdited || secondary.isEdited,
                replyPreview: primary.replyPreview ?? secondary.replyPreview,
                threadReplyCount: max(primary.threadReplyCount, secondary.threadReplyCount),
                deliveryState: effectiveDeliveryState,
                receipts: effectiveReceipts,
                transactionID: primary.transactionID ?? secondary.transactionID,
                isDeleted: false,
                deletedAt: nil,
                isMention: primary.isMention || secondary.isMention
            )
        }

        return TimelineItem(
            id: incoming.id,
            roomID: existing.roomID,
            senderID: existing.senderID,
            senderDisplayName: existing.senderDisplayName,
            body: existing.body,
            timestamp: existing.timestamp,
            kind: existing.kind,
            media: existing.media,
            status: existing.status,
            isOwnMessage: existing.isOwnMessage,
            isEncrypted: existing.isEncrypted,
            isEdited: existing.isEdited,
            replyPreview: existing.replyPreview,
            threadReplyCount: existing.threadReplyCount,
            deliveryState: effectiveDeliveryState,
            receipts: effectiveReceipts,
            transactionID: existing.transactionID ?? incoming.transactionID,
            isDeleted: true,
            deletedAt: incoming.deletedAt ?? existing.deletedAt ?? .now,
            isMention: existing.isMention || incoming.isMention
        )
    }

    private static func preferredAuthoritativeItem(existing: TimelineItem, incoming: TimelineItem) -> TimelineItem {
        let existingRank = authorityRank(for: existing)
        let incomingRank = authorityRank(for: incoming)
        if incomingRank >= existingRank {
            return incoming
        }
        return existing
    }

    private static func authorityRank(for item: TimelineItem) -> Int {
        var rank = 0
        if item.id.hasPrefix("$") {
            rank += 100
        }
        if item.transactionID != nil {
            rank += 10
        }
        rank += deliveryRank(for: item.deliveryState)
        rank += item.receipts.readReceipts.isEmpty ? 0 : 50
        return rank
    }

    private static func deliveryRank(for state: MessageDeliveryState?) -> Int {
        switch state {
        case .echoed:
            return 40
        case .accepted:
            return 30
        case .sending:
            return 20
        case .queued:
            return 10
        case .permanentFailure:
            return 5
        case .none:
            return 0
        }
    }

    private static func preferredDeliveryState(primary: TimelineItem, secondary: TimelineItem) -> MessageDeliveryState? {
        let primaryRank = deliveryRank(for: primary.deliveryState)
        let secondaryRank = deliveryRank(for: secondary.deliveryState)
        return primaryRank >= secondaryRank ? primary.deliveryState ?? secondary.deliveryState : secondary.deliveryState
    }

    private static func itemWithNormalizedReceipts(_ item: TimelineItem, readReceipts: [ReadReceipt]) -> TimelineItem {
        let normalizedSummary = ReceiptSummary(
            sentAt: item.receipts.sentAt,
            deliveredAt: item.receipts.deliveredAt,
            readReceipts: readReceipts
        )

        let normalizedDeliveryState: MessageDeliveryState?
        if !readReceipts.isEmpty {
            normalizedDeliveryState = .echoed
        } else if item.deliveryState == .echoed, item.isOwnMessage, item.id.hasPrefix("$") {
            normalizedDeliveryState = .accepted
        } else {
            normalizedDeliveryState = item.deliveryState
        }

        return TimelineItem(
            id: item.id,
            roomID: item.roomID,
            senderID: item.senderID,
            senderDisplayName: item.senderDisplayName,
            body: item.body,
            timestamp: item.timestamp,
            kind: item.kind,
            media: item.media,
            status: item.status,
            isOwnMessage: item.isOwnMessage,
            isEncrypted: item.isEncrypted,
            isEdited: item.isEdited,
            replyPreview: item.replyPreview,
            threadReplyCount: item.threadReplyCount,
            deliveryState: normalizedDeliveryState,
            receipts: normalizedSummary,
            transactionID: item.transactionID,
            isDeleted: item.isDeleted,
            deletedAt: item.deletedAt,
            isMention: item.isMention
        )
    }

    private static func sortedReceipts(_ receipts: [ReadReceipt]) -> [ReadReceipt] {
        receipts.sorted {
            switch ($0.readAt, $1.readAt) {
            case let (lhs?, rhs?):
                return lhs < rhs
            case (.none, .some):
                return false
            case (.some, .none):
                return true
            case (.none, .none):
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }
}
