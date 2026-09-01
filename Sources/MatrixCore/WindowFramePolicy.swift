import CoreGraphics
import Foundation

/// Keeps the main window inside a display's visible frame without resetting a
/// user-chosen size that already fits.
public enum WindowFramePolicy: Sendable {
    public static let defaultSize = CGSize(width: 1_680, height: 980)
    public static let minimumSize = CGSize(width: 960, height: 640)
    public static let collapsedThreshold = CGSize(width: 320, height: 240)
    public static let screenMargin: CGFloat = 40

    public static func isUsableSize(_ size: CGSize) -> Bool {
        size.width >= collapsedThreshold.width && size.height >= collapsedThreshold.height
    }

    public static func isFullyContained(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        frame.minX + 0.5 >= visibleFrame.minX
            && frame.minY + 0.5 >= visibleFrame.minY
            && frame.maxX <= visibleFrame.maxX + 0.5
            && frame.maxY <= visibleFrame.maxY + 0.5
            && frame.width <= visibleFrame.width + 0.5
            && frame.height <= visibleFrame.height + 0.5
    }

    /// Preserve a valid user frame; only rewrite when it is collapsed or off-screen.
    public static func shouldPreserveCurrentFrame(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        isUsableSize(frame.size) && isFullyContained(frame, in: visibleFrame)
    }

    public static func visibleFrame(containing frame: CGRect, screens: [CGRect]) -> CGRect? {
        guard !screens.isEmpty else { return nil }
        if let bestOverlap = screens.max(by: { intersectionArea($0, frame) < intersectionArea($1, frame) }),
           intersectionArea(bestOverlap, frame) > 0 {
            return bestOverlap
        }
        return screens.min { lhs, rhs in
            distanceSquared(center(of: frame), center(of: lhs)) < distanceSquared(center(of: frame), center(of: rhs))
        }
    }

    public static func sanitizedFrame(
        _ proposed: CGRect,
        visibleFrame: CGRect,
        centerIfNeeded: Bool
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return CGRect(origin: .zero, size: defaultSize)
        }

        let minWidth = min(minimumSize.width, visibleFrame.width)
        let minHeight = min(minimumSize.height, visibleFrame.height)
        let preferredWidth = isUsableSize(proposed.size) ? proposed.width : defaultSize.width
        let preferredHeight = isUsableSize(proposed.size) ? proposed.height : defaultSize.height
        let width = min(max(preferredWidth, minWidth), visibleFrame.width)
        let height = min(max(preferredHeight, minHeight), visibleFrame.height)

        var originX = proposed.origin.x
        var originY = proposed.origin.y
        if centerIfNeeded && !isUsableSize(proposed.size) {
            originX = visibleFrame.midX - (width / 2)
            originY = visibleFrame.midY - (height / 2)
        }

        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - width
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - height
        originX = maxX >= minX ? min(max(originX, minX), maxX) : minX
        originY = maxY >= minY ? min(max(originY, minY), maxY) : minY

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    public static func clampedMinimumSize(within visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(minimumSize.width, max(1, visibleFrame.width)),
            height: min(minimumSize.height, max(1, visibleFrame.height))
        )
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, !intersection.isInfinite else { return 0 }
        return max(0, intersection.width) * max(0, intersection.height)
    }

    private static func center(of rect: CGRect) -> CGPoint {
        CGPoint(x: rect.midX, y: rect.midY)
    }

    private static func distanceSquared(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }
}
