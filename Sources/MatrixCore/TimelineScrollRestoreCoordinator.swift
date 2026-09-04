import Foundation

public enum TimelineViewportMutation: Equatable, Sendable {
    case timelineItemsChanged
    case mediaRowHeightsChanged
    case mediaProgressOnly
    case historyStatusOnly

    var requiresViewportRestore: Bool {
        switch self {
        case .timelineItemsChanged, .mediaRowHeightsChanged:
            true
        case .mediaProgressOnly, .historyStatusOnly:
            false
        }
    }
}

public struct TimelineScrollRestoreRequest: Equatable, Sendable {
    public let generation: UInt64
    public let anchor: TimelineScrollAnchor

    public init(generation: UInt64, anchor: TimelineScrollAnchor) {
        self.generation = generation
        self.anchor = anchor
    }
}

/// Coalesces adjacent timeline geometry changes into one stable-anchor restore.
/// Progress/banner updates do not mutate the viewport, and a new real geometry
/// change invalidates a previously queued restore without recapturing a transient
/// AppKit viewport position.
/// A staged table transaction that leaves an unchanged trailing portion of a
/// timeline in place. This covers history pages that recompact/replace one or
/// more *leading* presentation rows while retaining the reader's visible rows.
public struct TimelineTableUpdatePlan: Equatable, Sendable {
    public let deletedRows: IndexSet
    public let insertedRows: IndexSet
    public let reloadedRows: IndexSet

    public init(deletedRows: IndexSet, insertedRows: IndexSet, reloadedRows: IndexSet) {
        self.deletedRows = deletedRows
        self.insertedRows = insertedRows
        self.reloadedRows = reloadedRows
    }

    /// Derives one safe leading-row transaction from snapshots whose common
    /// suffix retains stable item identities. Equal identities with changed
    /// content are reloaded in place; unmatched leading rows are replaced.
    /// Returns nil when no stable suffix exists and a full snapshot reload is
    /// still required.
    public static func leadingMutation<Item: Equatable>(
        previousItems: [Item],
        currentItems: [Item],
        id: (Item) -> String
    ) -> TimelineTableUpdatePlan? {
        guard !previousItems.isEmpty, !currentItems.isEmpty else { return nil }

        var stableSuffixCount = 0
        while stableSuffixCount < previousItems.count,
              stableSuffixCount < currentItems.count,
              id(previousItems[previousItems.count - stableSuffixCount - 1]) ==
                id(currentItems[currentItems.count - stableSuffixCount - 1]) {
            stableSuffixCount += 1
        }
        guard stableSuffixCount > 0 else { return nil }

        let previousLeadingCount = previousItems.count - stableSuffixCount
        let currentLeadingCount = currentItems.count - stableSuffixCount
        let reloadedRows = IndexSet(
            (0..<stableSuffixCount).compactMap { offset in
                let previousIndex = previousLeadingCount + offset
                let currentIndex = currentLeadingCount + offset
                return previousItems[previousIndex] == currentItems[currentIndex]
                    ? nil
                    : currentIndex
            }
        )

        let deletedRows = IndexSet(integersIn: 0..<previousLeadingCount)
        let insertedRows = IndexSet(integersIn: 0..<currentLeadingCount)
        guard !deletedRows.isEmpty || !insertedRows.isEmpty || !reloadedRows.isEmpty else {
            return nil
        }
        return TimelineTableUpdatePlan(
            deletedRows: deletedRows,
            insertedRows: insertedRows,
            reloadedRows: reloadedRows
        )
    }
}

public struct TimelineScrollRestoreCoordinator: Sendable {
    private var nextGeneration: UInt64 = 0
    private var pendingAnchor: TimelineScrollAnchor?

    public init() {}

    public var currentGeneration: UInt64 { nextGeneration }

    public static func prependedRowIndexes<Item: Equatable>(
        previousItems: [Item],
        currentItems: [Item]
    ) -> IndexSet? {
        guard !previousItems.isEmpty,
              currentItems.count > previousItems.count,
              Array(currentItems.suffix(previousItems.count)) == previousItems else {
            return nil
        }
        return IndexSet(integersIn: 0..<(currentItems.count - previousItems.count))
    }

    /// The table still displays its previous snapshot until an insertion or reload.
    /// Capture a viewport anchor from that snapshot, rather than model items that
    /// have already received an older-history prepend.
    public static func itemAtVisibleRow<Item>(
        renderedItems: [Item],
        row: Int
    ) -> Item? {
        guard renderedItems.indices.contains(row) else { return nil }
        return renderedItems[row]
    }

    public mutating func begin(
        mutation: TimelineViewportMutation,
        capturedAnchor: TimelineScrollAnchor
    ) -> TimelineScrollRestoreRequest? {
        guard mutation.requiresViewportRestore else { return nil }
        nextGeneration += 1
        if pendingAnchor == nil {
            pendingAnchor = capturedAnchor
        }
        return TimelineScrollRestoreRequest(generation: nextGeneration, anchor: pendingAnchor!)
    }

    public func mayApply(_ request: TimelineScrollRestoreRequest) -> Bool {
        request.generation == nextGeneration && pendingAnchor == request.anchor
    }

    public mutating func takeAnchor(for request: TimelineScrollRestoreRequest) -> TimelineScrollAnchor? {
        guard mayApply(request) else { return nil }
        pendingAnchor = nil
        return request.anchor
    }

    @discardableResult
    public mutating func complete(_ request: TimelineScrollRestoreRequest) -> Bool {
        guard mayApply(request) else { return false }
        pendingAnchor = nil
        return true
    }

    public mutating func reset() {
        nextGeneration += 1
        pendingAnchor = nil
    }
}
