import Foundation

/// Follow-mode for the room timeline: when locked, new messages keep the viewport
/// pinned to the latest item; when unlocked, live appends and history prepends
/// must not yank the user back down.
public struct TimelineLiveFollowPolicy: Equatable, Sendable {
    public private(set) var isFollowingLiveTraffic: Bool

    public init(isFollowingLiveTraffic: Bool = true) {
        self.isFollowingLiveTraffic = isFollowingLiveTraffic
    }

    /// Scrolling to the bottom auto-locks; any scroll away from the bottom unlocks.
    public mutating func applyUserScroll(isAtBottom: Bool) {
        isFollowingLiveTraffic = isAtBottom
    }

    public mutating func jumpToLatest() {
        isFollowingLiveTraffic = true
    }

    public mutating func resetForSelectedRoomChange() {
        isFollowingLiveTraffic = true
    }

    /// Live appends and older-history prepends may only pin the viewport when follow-mode is on.
    public var shouldPinViewportToLatestOnReload: Bool {
        isFollowingLiveTraffic
    }

    /// Hidden while locked to the bottom, while already at the bottom, or when there is nothing to jump to.
    public func shouldShowJumpToLatestControl(hasItems: Bool, isAtBottom: Bool) -> Bool {
        hasItems && !isFollowingLiveTraffic && !isAtBottom
    }
}
