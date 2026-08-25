import Foundation
import MatrixCore
import Testing

@Test
func timelinePaginationPolicyFillsUntilAtLeastOneHundredItems() {
    #expect(TimelinePaginationPolicy.initialPageSize == 200)
    #expect(TimelinePaginationPolicy.additionalPageSize == 50)
    #expect(TimelinePaginationPolicy.shouldFillToMinimum(loadedCount: 40, reachedStart: false))
    #expect(!TimelinePaginationPolicy.shouldFillToMinimum(loadedCount: 40, reachedStart: true))
    #expect(!TimelinePaginationPolicy.shouldFillToMinimum(loadedCount: 100, reachedStart: false))
}

@Test
func timelinePaginationPolicyRequestsScrollBackWhenFewerThanOneHundredItemsAboveViewport() {
    #expect(
        TimelinePaginationPolicy.shouldLoadOlderWhileScrolling(
            itemsAboveViewport: 12,
            reachedStart: false,
            isLoading: false
        )
    )
    #expect(
        !TimelinePaginationPolicy.shouldLoadOlderWhileScrolling(
            itemsAboveViewport: 12,
            reachedStart: false,
            isLoading: true
        )
    )
    #expect(
        !TimelinePaginationPolicy.shouldLoadOlderWhileScrolling(
            itemsAboveViewport: 120,
            reachedStart: false,
            isLoading: false
        )
    )
}
