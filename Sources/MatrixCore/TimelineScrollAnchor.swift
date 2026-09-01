import Foundation

public struct TimelineScrollRow: Equatable, Sendable {
    public let id: String
    public let minY: CGFloat
    public let height: CGFloat

    public init(id: String, minY: CGFloat, height: CGFloat) {
        self.id = id
        self.minY = minY
        self.height = height
    }
}

public struct TimelineScrollAnchor: Equatable, Sendable {
    public let pinToLatest: Bool
    public let itemID: String?
    public let offsetInRow: CGFloat

    public init(pinToLatest: Bool, itemID: String?, offsetInRow: CGFloat) {
        self.pinToLatest = pinToLatest
        self.itemID = itemID
        self.offsetInRow = offsetInRow
    }

    public static func capture(
        isFollowingLatest: Bool,
        itemsEmpty: Bool,
        firstVisibleItemID: String?,
        firstVisibleRowMinY: CGFloat,
        visibleRectMinY: CGFloat
    ) -> TimelineScrollAnchor {
        if isFollowingLatest || itemsEmpty {
            return TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        }
        guard let firstVisibleItemID else {
            return TimelineScrollAnchor(pinToLatest: false, itemID: nil, offsetInRow: 0)
        }
        return TimelineScrollAnchor(
            pinToLatest: false,
            itemID: firstVisibleItemID,
            offsetInRow: firstVisibleRowMinY - visibleRectMinY
        )
    }

    /// Document-view origin.y that keeps either latest or the captured item/offset.
    /// Returns nil when the anchored item is missing so the viewport is left alone.
    public func targetOriginY(
        rows: [TimelineScrollRow],
        clipHeight: CGFloat,
        documentHeight: CGFloat
    ) -> CGFloat? {
        let maxOrigin = max(0, documentHeight - clipHeight)
        if pinToLatest {
            return maxOrigin
        }
        guard let itemID, let row = rows.first(where: { $0.id == itemID }) else {
            return nil
        }
        return min(max(row.minY - offsetInRow, 0), maxOrigin)
    }
}
