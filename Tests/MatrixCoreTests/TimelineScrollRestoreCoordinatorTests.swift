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
    func unchangedSuffixUsesANoAnimationTopRowInsertion() {
        let insertedRows = TimelineScrollRestoreCoordinator.prependedRowIndexes(
            previousItems: ["visible", "latest"],
            currentItems: ["older-a", "older-b", "visible", "latest"]
        )

        #expect(insertedRows == IndexSet([0, 1]))
        #expect(TimelineScrollRestoreCoordinator.prependedRowIndexes(
            previousItems: ["visible", "latest"],
            currentItems: ["visible", "changed-latest"]
        ) == nil)
    }

    @Test
    func visibleRowUsesThePreviouslyRenderedItemDuringAPrepend() {
        let previousRows = ["visible", "latest"]
        let incomingRows = ["older-a", "older-b", "visible", "latest"]

        let visibleItem = TimelineScrollRestoreCoordinator.itemAtVisibleRow(
            renderedItems: previousRows,
            row: 0
        )

        #expect(visibleItem == "visible")
        #expect(visibleItem != incomingRows[0])
    }

    @Test
    func mediaPreviewHeightUpdatesOnlyInvalidateRowsThatAreVisible() {
        struct Row {
            let id: String
            let previewIsAvailable: Bool
        }

        let rows = [
            Row(id: "above", previewIsAvailable: true),
            Row(id: "visible", previewIsAvailable: true),
            Row(id: "below", previewIsAvailable: true)
        ]

        let invalidatedRows = TimelineMediaHeightUpdatePlan.visibleChangedRows(
            items: rows,
            visibleRows: IndexSet(integer: 1),
            appliedPreviewAvailabilityByItemID: [
                "above": false,
                "visible": false,
                "below": false
            ],
            id: \.id,
            previewIsAvailable: \.previewIsAvailable
        )

        #expect(invalidatedRows == IndexSet(integer: 1))
    }

    @Test
    func appendingLatestMessageUsesTrailingInsertionInsteadOfReloadingTheWholeTimeline() {
        struct Row: Equatable {
            let id: String
            let body: String
        }

        let previousRows = [
            Row(id: "older", body: "Older message"),
            Row(id: "latest", body: "Current newest message")
        ]
        let currentRows = previousRows + [
            Row(id: "newest", body: "Incoming newest message")
        ]

        let plan = TimelineTableUpdatePlan.mutation(
            previousItems: previousRows,
            currentItems: currentRows,
            id: \.id
        )

        #expect(plan == TimelineTableUpdatePlan(
            deletedRows: [],
            insertedRows: IndexSet(integer: 2),
            reloadedRows: []
        ))
    }

    @Test
    func boundaryStatusRecompactionUsesLeadingRowReplacementInsteadOfReloadingTheWholeTimeline() {
        struct Row: Equatable {
            let id: String
            let body: String
        }

        let previousRows = [
            Row(id: "status-a-b", body: "A and B changed the room"),
            Row(id: "visible", body: "Keep this message at its exact viewport offset"),
            Row(id: "latest", body: "Latest message")
        ]
        let currentRows = [
            Row(id: "older-status-c", body: "C changed the room"),
            Row(id: "status-c-b", body: "C, A and B changed the room"),
            Row(id: "visible", body: "Keep this message at its exact viewport offset"),
            Row(id: "latest", body: "Latest message")
        ]

        let plan = TimelineTableUpdatePlan.leadingMutation(
            previousItems: previousRows,
            currentItems: currentRows,
            id: \.id
        )

        #expect(plan == TimelineTableUpdatePlan(
            deletedRows: IndexSet(integer: 0),
            insertedRows: IndexSet(integersIn: 0..<2),
            reloadedRows: []
        ))
    }

    @Test
    func restoringAValidRequestExecutesTheAnchorInTheCurrentLayoutPass() throws {
        var coordinator = TimelineScrollRestoreCoordinator()
        let requestOptional = coordinator.begin(
            mutation: .timelineItemsChanged,
            capturedAnchor: readerAnchor
        )
        let request = try #require(requestOptional)
        let restoredAnchor = coordinator.takeAnchor(for: request)

        #expect(restoredAnchor == readerAnchor)
        #expect(!coordinator.mayApply(request))
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
