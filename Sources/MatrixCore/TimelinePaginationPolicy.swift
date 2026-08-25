import Foundation

public enum TimelineHistoryStatus: Equatable, Sendable {
    case idle
    case loadingOlder
    case noMoreHistory
    case failed(String)

    public var bannerText: String? {
        switch self {
        case .idle:
            return nil
        case .loadingOlder:
            return "Loading earlier messages…"
        case .noMoreHistory:
            return "No more history"
        case let .failed(message):
            return message
        }
    }
}

public enum TimelinePaginationPolicy: Sendable {
    public static let initialPageSize: UInt16 = 200
    public static let additionalPageSize: UInt16 = 50
    public static let minimumFilledCount = 100
    public static let scrollBackThreshold = 100

    public static func shouldFillToMinimum(loadedCount: Int, reachedStart: Bool) -> Bool {
        !reachedStart && loadedCount < minimumFilledCount
    }

    public static func shouldLoadOlderWhileScrolling(
        itemsAboveViewport: Int,
        reachedStart: Bool,
        isLoading: Bool
    ) -> Bool {
        !reachedStart && !isLoading && itemsAboveViewport < scrollBackThreshold
    }
}
