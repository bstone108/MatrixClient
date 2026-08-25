import Foundation
import MatrixCore
import Testing

@Test
func timelineFollowStartsLockedAndHidesJumpControlAtBottom() {
    let policy = TimelineLiveFollowPolicy()
    #expect(policy.isFollowingLiveTraffic)
    #expect(policy.shouldPinViewportToLatestOnReload)
    #expect(!policy.shouldShowJumpToLatestControl(hasItems: true, isAtBottom: true))
    #expect(!policy.shouldShowJumpToLatestControl(hasItems: true, isAtBottom: false))
    #expect(!policy.shouldShowJumpToLatestControl(hasItems: false, isAtBottom: false))
}

@Test
func scrollingUpUnlocksFollowAndShowsJumpControl() {
    var policy = TimelineLiveFollowPolicy()
    policy.applyUserScroll(isAtBottom: false)
    #expect(!policy.isFollowingLiveTraffic)
    #expect(!policy.shouldPinViewportToLatestOnReload)
    #expect(policy.shouldShowJumpToLatestControl(hasItems: true, isAtBottom: false))
}

@Test
func scrollingToBottomRelocksFollowAndHidesJumpControl() {
    var policy = TimelineLiveFollowPolicy()
    policy.applyUserScroll(isAtBottom: false)
    policy.applyUserScroll(isAtBottom: true)
    #expect(policy.isFollowingLiveTraffic)
    #expect(policy.shouldPinViewportToLatestOnReload)
    #expect(!policy.shouldShowJumpToLatestControl(hasItems: true, isAtBottom: true))
}

@Test
func jumpToLatestLocksFollowEvenIfViewportHasNotSettled() {
    var policy = TimelineLiveFollowPolicy()
    policy.applyUserScroll(isAtBottom: false)
    policy.jumpToLatest()
    #expect(policy.isFollowingLiveTraffic)
    #expect(policy.shouldPinViewportToLatestOnReload)
    #expect(!policy.shouldShowJumpToLatestControl(hasItems: true, isAtBottom: false))
}

@Test
func roomChangeRelocksFollow() {
    var policy = TimelineLiveFollowPolicy()
    policy.applyUserScroll(isAtBottom: false)
    policy.resetForSelectedRoomChange()
    #expect(policy.isFollowingLiveTraffic)
    #expect(policy.shouldPinViewportToLatestOnReload)
}

@Test
func unlockedFollowDoesNotPinOnHistoryPrependOrLiveAppend() {
    var policy = TimelineLiveFollowPolicy()
    policy.applyUserScroll(isAtBottom: false)
    #expect(!policy.shouldPinViewportToLatestOnReload)
    #expect(policy.shouldShowJumpToLatestControl(hasItems: true, isAtBottom: false))
}
