import Foundation
import MatrixCore
import Testing

@Suite("TimelineScrollRestoreCoordinatorTests")
struct TimelineScrollRestoreCoordinatorTests {
    private let readerAnchor = TimelineScrollAnchor(
        pinToLatest: false,
        itemID: "$reader-anchor",
        offsetInRow: 18
    )

    @Test
    func statusAndProgressUpdatesDoNotCompeteWithAnInFlightTimelineRestore() {
        var coordinator = TimelineScrollRestoreCoordinator()
        let timeline = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        #require(timeline != nil)

        #expect(coordinator.begin(
            mutation: .historyStatusOnly,
            capturedAnchor: readerAnchor
        ) == nil)
        #expect(coordinator.begin(
            mutation: .mediaProgressOnly,
            capturedAnchor: readerAnchor
        ) == nil)
        #expect(coordinator.mayApply(timeline!))
    }

    @Test
    func newerGeometryChangeSupersedesEarlierDeferredRestoreButKeepsOriginalAnchor() {
        var coordinator = TimelineScrollRestoreCoordinator()
        let history = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        #require(history != nil)

        let media = coordinator.begin(
            mutation: .mediaRowHeightsChanged,
            capturedAnchor: TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        )
        #require(media != nil)

        #expect(!coordinator.mayApply(history!))
        #expect(coordinator.mayApply(media!))
        #expect(media!.anchor == readerAnchor)
    }

    @Test
    func completingLatestRestoreReleasesTheAnchorForTheNextUserVisibleMutation() {
        var coordinator = TimelineScrollRestoreCoordinator()
        let first = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        #require(first != nil)
        #expect(coordinator.complete(first!))

        let latestAnchor = TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        let next = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: latestAnchor
        )
        #require(next != nil)
        #expect(next!.anchor == latestAnchor)
    }
}
