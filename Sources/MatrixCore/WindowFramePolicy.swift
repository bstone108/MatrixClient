import CoreGraphics
import Foundation

/// Why a frame is being reconsidered. Content-driven reasons must never
/// change a valid user-chosen size.
public enum WindowFrameAdjustmentReason: String, Equatable, Sendable {
    case userInteraction
    case roomContent
    case headerExpansion
    case unreadList
    case sessionPresentation
    case splitView
    case textLayout
    case screenChange
    case recovery
}

extension WindowFrameAdjustmentReason {
    public var isContentDriven: Bool {
        switch self {
        case .roomContent, .headerExpansion, .unreadList, .sessionPresentation, .splitView, .textLayout:
            return true
        case .userInteraction, .screenChange, .recovery:
            return false
        }
    }
}

/// Keeps the main window inside a display's visible frame.
///
/// A valid user size is never replaced because room content, the topic header,
/// unread/list updates, session presentation, split views, or text layout
/// changed. The only automatic size changes are: recover an absurd/corrupt
/// frame (for example 2×2), or shrink a frame that cannot fit on the selected
/// display so the window never extends off-screen.
public enum WindowFramePolicy: Sendable {
    public static let defaultSize = CGSize(width: 1_680, height: 980)
    public static let recoverySize = defaultSize
    /// Only frames smaller than this are treated as corrupt and recovered.
    public static let absurdSizeThreshold = CGSize(width: 8, height: 8)
    public static let screenMargin: CGFloat = 40

    public static func isAbsurdSize(_ size: CGSize) -> Bool {
        size.width < absurdSizeThreshold.width || size.height < absurdSizeThreshold.height
    }

    public static func isUsableSize(_ size: CGSize) -> Bool {
        !isAbsurdSize(size)
    }

    public static func isFullyContained(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        frame.minX + 0.5 >= visibleFrame.minX
            && frame.minY + 0.5 >= visibleFrame.minY
            && frame.maxX <= visibleFrame.maxX + 0.5
            && frame.maxY <= visibleFrame.maxY + 0.5
            && frame.width <= visibleFrame.width + 0.5
            && frame.height <= visibleFrame.height + 0.5
    }

    public static func shouldPreserveCurrentFrame(_ frame: CGRect, in visibleFrame: CGRect) -> Bool {
        isUsableSize(frame.size) && isFullyContained(frame, in: visibleFrame)
    }

    public static func allowsContentDrivenSizeChange(from: CGSize, to: CGSize) -> Bool {
        _ = from
        _ = to
        return false
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

    /// Resolve a window frame. `current` is the last valid (or present) frame;
    /// `proposed` is what layout/AppKit/the user asked for.
    public static func resolvedFrame(
        current: CGRect,
        proposed: CGRect,
        visibleFrame: CGRect,
        reason: WindowFrameAdjustmentReason
    ) -> CGRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else {
            return CGRect(origin: .zero, size: recoverySize)
        }

        if isAbsurdSize(current.size), isAbsurdSize(proposed.size) {
            return recoveryFrame(in: visibleFrame)
        }

        let source: CGRect
        if reason.isContentDriven {
            source = isUsableSize(current.size) ? current : proposed
        } else if reason == .userInteraction {
            source = proposed
        } else if reason == .screenChange {
            source = isUsableSize(current.size) ? current : proposed
        } else {
            source = isUsableSize(proposed.size) ? proposed : current
        }

        if isAbsurdSize(source.size) {
            return recoveryFrame(in: visibleFrame)
        }

        var width = source.width
        var height = source.height
        if reason.isContentDriven, isUsableSize(current.size) {
            width = current.width
            height = current.height
        }

        width = min(width, visibleFrame.width)
        height = min(height, visibleFrame.height)

        var originX = source.origin.x
        var originY = source.origin.y
        let minX = visibleFrame.minX
        let maxX = visibleFrame.maxX - width
        let minY = visibleFrame.minY
        let maxY = visibleFrame.maxY - height
        originX = maxX >= minX ? min(max(originX, minX), maxX) : minX
        originY = maxY >= minY ? min(max(originY, minY), maxY) : minY

        return CGRect(x: originX, y: originY, width: width, height: height)
    }

    /// Persist restore and other single-rect sanitization: keep a valid size,
    /// move/shrink only to stay inside `visibleFrame`.
    public static func sanitizedFrame(
        _ proposed: CGRect,
        visibleFrame: CGRect,
        centerIfNeeded: Bool
    ) -> CGRect {
        _ = centerIfNeeded
        return resolvedFrame(
            current: proposed,
            proposed: proposed,
            visibleFrame: visibleFrame,
            reason: .userInteraction
        )
    }

    public static func recoveryFrame(in visibleFrame: CGRect) -> CGRect {
        let width = min(recoverySize.width, max(1, visibleFrame.width))
        let height = min(recoverySize.height, max(1, visibleFrame.height))
        return CGRect(
            x: visibleFrame.midX - (width / 2),
            y: visibleFrame.midY - (height / 2),
            width: width,
            height: height
        )
    }

    public static func windowMinimumSize(within visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: min(absurdSizeThreshold.width, max(1, visibleFrame.width)),
            height: min(absurdSizeThreshold.height, max(1, visibleFrame.height))
        )
    }

    public static func windowMaximumSize(within visibleFrame: CGRect) -> CGSize {
        CGSize(
            width: max(absurdSizeThreshold.width, visibleFrame.width),
            height: max(absurdSizeThreshold.height, visibleFrame.height)
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
