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
    func statusAndProgressUpdatesDoNotCompeteWithAnInFlightTimelineRestore() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let timeline = try #require(coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        ))

        #expect(coordinator.begin(
            mutation: .historyStatusOnly,
            capturedAnchor: readerAnchor
        ) == nil)
        #expect(coordinator.begin(
            mutation: .mediaProgressOnly,
            capturedAnchor: readerAnchor
        ) == nil)
        #expect(coordinator.mayApply(timeline))
    }

    @Test
    func newerGeometryChangeSupersedesEarlierDeferredRestoreButKeepsOriginalAnchor() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let history = try #require(coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        ))

        let media = try #require(coordinator.begin(
            mutation: .mediaRowHeightsChanged,
            capturedAnchor: TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        ))

        #expect(!coordinator.mayApply(history))
        #expect(coordinator.mayApply(media))
        #expect(media.anchor == readerAnchor)
    }

    @Test
    func completingLatestRestoreReleasesTheAnchorForTheNextUserVisibleMutation() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let first = try #require(coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        ))
        #expect(coordinator.complete(first))

        let latestAnchor = TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        let next = try #require(coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: latestAnchor
        ))
        #expect(next.anchor == latestAnchor)
    }
}
