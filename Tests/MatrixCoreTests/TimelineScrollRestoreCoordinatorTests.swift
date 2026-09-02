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
        let timelineOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        let timeline = try #require(timelineOptional)

        let historyStatusRequest = coordinator.begin(
            mutation: .historyStatusOnly,
            capturedAnchor: readerAnchor
        )
        #expect(historyStatusRequest == nil)
        let mediaProgressRequest = coordinator.begin(
            mutation: .mediaProgressOnly,
            capturedAnchor: readerAnchor
        )
        #expect(mediaProgressRequest == nil)
        #expect(coordinator.mayApply(timeline))
    }

    @Test
    func newerGeometryChangeSupersedesEarlierDeferredRestoreButKeepsOriginalAnchor() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let historyOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        let history = try #require(historyOptional)

        let mediaOptional = coordinator.begin(
            mutation: .mediaRowHeightsChanged,
            capturedAnchor: TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        )
        let media = try #require(mediaOptional)

        #expect(!coordinator.mayApply(history))
        #expect(coordinator.mayApply(media))
        #expect(media.anchor == readerAnchor)
    }

    @Test
    func roomChangeInvalidatesPendingAnchorBeforeTheNextRoomBeginsItsRestore() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let roomAOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        let roomARequest = try #require(roomAOptional)

        coordinator.reset()

        let roomBAnchor = TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        let roomBOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: roomBAnchor
        )
        let roomBRequest = try #require(roomBOptional)

        #expect(!coordinator.mayApply(roomARequest))
        #expect(coordinator.mayApply(roomBRequest))
        #expect(roomBRequest.anchor == roomBAnchor)
    }

    @Test
    func completingLatestRestoreReleasesTheAnchorForTheNextUserVisibleMutation() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let firstOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        let first = try #require(firstOptional)
        let didComplete = coordinator.complete(first)
        #expect(didComplete)

        let latestAnchor = TimelineScrollAnchor(pinToLatest: true, itemID: nil, offsetInRow: 0)
        let nextOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: latestAnchor
        )
        let next = try #require(nextOptional)
        #expect(next.anchor == latestAnchor)
    }
}
