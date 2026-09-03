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
public struct TimelineScrollRestoreCoordinator: Sendable {
    private var nextGeneration: UInt64 = 0
    private var pendingAnchor: TimelineScrollAnchor?

    public init() {}

    public var currentGeneration: UInt64 { nextGeneration }

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

    @discardableResult
    public mutating func perform(
        _ request: TimelineScrollRestoreRequest,
        restore: (TimelineScrollAnchor) -> Void
    ) -> Bool {
        guard mayApply(request) else { return false }
        restore(request.anchor)
        pendingAnchor = nil
        return true
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
