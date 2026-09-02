import Foundation
import MatrixCore
import Testing

@Suite("TimelineScrollAnchorTests")
struct TimelineScrollAnchorTests {
@Test
func liveAppendWhileReadingHistoryKeepsAnchoredItemOffset() {
    var follow = TimelineLiveFollowPolicy()
    follow.applyUserScroll(isAtBottom: false)
    #expect(!follow.shouldPinViewportToLatestOnReload)

    let before = TimelineScrollAnchor.capture(
        isFollowingLatest: follow.shouldPinViewportToLatestOnReload,
        itemsEmpty: false,
        firstVisibleItemID: "$mid",
        firstVisibleRowMinY: 400,
        visibleRectMinY: 380
    )
    #expect(!before.pinToLatest)
    #expect(before.itemID == "$mid")
    #expect(before.offsetInRow == 20)

    let afterRows = [
        TimelineScrollRow(id: "$old", minY: 0, height: 80),
        TimelineScrollRow(id: "$mid", minY: 400, height: 80),
        TimelineScrollRow(id: "$live", minY: 800, height: 80)
    ]
    let origin = before.targetOriginY(rows: afterRows, clipHeight: 300, documentHeight: 880)
    #expect(origin == 380)
}

@Test
func mediaHeightReflowKeepsReaderOnTheSameItem() {
    let anchor = TimelineScrollAnchor.capture(
        isFollowingLatest: false,
        itemsEmpty: false,
        firstVisibleItemID: "$photo",
        firstVisibleRowMinY: 200,
        visibleRectMinY: 190
    )
    let grownRows = [
        TimelineScrollRow(id: "$before", minY: 0, height: 80),
        TimelineScrollRow(id: "$photo", minY: 80, height: 260),
        TimelineScrollRow(id: "$after", minY: 340, height: 80)
    ]
    let origin = anchor.targetOriginY(rows: grownRows, clipHeight: 240, documentHeight: 420)
    #expect(origin == 70)
}

@Test
func olderHistoryInsertionKeepsViewportOnTheSameMessage() {
    let anchor = TimelineScrollAnchor.capture(
        isFollowingLatest: false,
        itemsEmpty: false,
        firstVisibleItemID: "$visible",
        firstVisibleRowMinY: 120,
        visibleRectMinY: 100
    )
    let prepended = [
        TimelineScrollRow(id: "$older-a", minY: 0, height: 90),
        TimelineScrollRow(id: "$older-b", minY: 90, height: 90),
        TimelineScrollRow(id: "$visible", minY: 300, height: 80),
        TimelineScrollRow(id: "$latest", minY: 380, height: 80)
    ]
    let origin = anchor.targetOriginY(rows: prepended, clipHeight: 200, documentHeight: 460)
    #expect(origin == 280)
}

@Test
func followingLatestPinsToBottomAfterAppend() {
    var follow = TimelineLiveFollowPolicy()
    follow.applyUserScroll(isAtBottom: true)
    let anchor = TimelineScrollAnchor.capture(
        isFollowingLatest: follow.shouldPinViewportToLatestOnReload,
        itemsEmpty: false,
        firstVisibleItemID: "$old-latest",
        firstVisibleRowMinY: 500,
        visibleRectMinY: 400
    )
    #expect(anchor.pinToLatest)

    let rows = [
        TimelineScrollRow(id: "$old-latest", minY: 500, height: 80),
        TimelineScrollRow(id: "$new-latest", minY: 900, height: 80)
    ]
    let origin = anchor.targetOriginY(rows: rows, clipHeight: 200, documentHeight: 980)
    #expect(origin == 780)
}

@Test
func repeatedReloadsKeepTheSameAnchoredOrigin() {
    let anchor = TimelineScrollAnchor.capture(
        isFollowingLatest: false,
        itemsEmpty: false,
        firstVisibleItemID: "$keep",
        firstVisibleRowMinY: 160,
        visibleRectMinY: 140
    )
    let firstReload = [
        TimelineScrollRow(id: "$older", minY: 0, height: 80),
        TimelineScrollRow(id: "$keep", minY: 240, height: 80),
        TimelineScrollRow(id: "$latest", minY: 320, height: 80)
    ]
    let secondReload = [
        TimelineScrollRow(id: "$older-a", minY: 0, height: 90),
        TimelineScrollRow(id: "$older-b", minY: 90, height: 90),
        TimelineScrollRow(id: "$keep", minY: 360, height: 80),
        TimelineScrollRow(id: "$live", minY: 440, height: 80)
    ]
    let firstOrigin = anchor.targetOriginY(rows: firstReload, clipHeight: 200, documentHeight: 400)
    let secondOrigin = anchor.targetOriginY(rows: secondReload, clipHeight: 200, documentHeight: 520)
    #expect(firstOrigin == 220)
    #expect(secondOrigin == 340)
}

@Test
func missingAnchorItemDoesNotYankViewport() {
    let anchor = TimelineScrollAnchor(
        pinToLatest: false,
        itemID: "$gone",
        offsetInRow: 12
    )
    let origin = anchor.targetOriginY(
        rows: [TimelineScrollRow(id: "$other", minY: 0, height: 80)],
        clipHeight: 200,
        documentHeight: 400
    )
    #expect(origin == nil)
}
}
