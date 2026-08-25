import CoreGraphics
import Foundation

/// Layout math for the media preview window.
///
/// The viewer owns the size: native image pixels are only an aspect ratio.
/// The window is fitted inside `visibleFrame` (minus a margin) and never
/// grown to the source pixel width. Clamping preserves that aspect so the
/// content view is not a wider box than the picture.
public enum MediaPreviewLayout: Sendable {
    public static let defaultContentSize = CGSize(width: 1_080, height: 760)
    public static let minimumContentSize = CGSize(width: 420, height: 320)
    public static let screenMargin: CGFloat = 24

    public static func maximumFrame(in visibleFrame: CGRect) -> CGRect {
        let constrained = visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        if constrained.width > 0, constrained.height > 0 {
            return constrained
        }
        return visibleFrame
    }

    public static func clampedMinimumContentSize(within maximumContentSize: CGSize) -> CGSize {
        CGSize(
            width: min(minimumContentSize.width, max(1, maximumContentSize.width)),
            height: min(minimumContentSize.height, max(1, maximumContentSize.height))
        )
    }

    /// Aspect-fit `preferred` into the default viewer, then into `maximumContentSize`.
    /// Upscales small pictures so they fill the viewer; never exceeds the cap, so a
    /// 4000px-wide original cannot blow the window out to native pixels.
    public static func fittedContentSize(preferred: CGSize, within maximumContentSize: CGSize) -> CGSize {
        let box = CGSize(
            width: min(defaultContentSize.width, max(1, maximumContentSize.width)),
            height: min(defaultContentSize.height, max(1, maximumContentSize.height))
        )
        return aspectFittedSize(preferred, within: box, allowUpscale: true)
    }

    public static func aspectFittedSize(_ preferred: CGSize, within bounds: CGSize, allowUpscale: Bool) -> CGSize {
        guard preferred.width > 0, preferred.height > 0 else {
            return CGSize(width: max(1, bounds.width), height: max(1, bounds.height))
        }
        guard bounds.width > 0, bounds.height > 0 else {
            return CGSize(width: 1, height: 1)
        }

        let scale = min(bounds.width / preferred.width, bounds.height / preferred.height)
        let applied = allowUpscale ? scale : min(1, scale)
        return CGSize(
            width: max(1, floor(preferred.width * applied)),
            height: max(1, floor(preferred.height * applied))
        )
    }

    public static func centeredFrame(size: CGSize, within bounds: CGRect) -> CGRect {
        CGRect(
            x: bounds.midX - (size.width / 2),
            y: bounds.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    /// Keep `frame` inside `maximumFrame`. If it is too large, scale it down
    /// while preserving `aspect` (or the current size if aspect is unknown)
    /// instead of independently clipping width and height — that independent
    /// clip is what produced a wide box and grey side gutters.
    public static func clampedFrame(_ frame: CGRect, within maximumFrame: CGRect, aspect: CGSize?) -> CGRect {
        var size = frame.size
        if size.width > maximumFrame.width || size.height > maximumFrame.height {
            size = aspectFittedSize(aspect ?? size, within: maximumFrame.size, allowUpscale: false)
        }
        size.width = min(max(1, size.width), maximumFrame.width)
        size.height = min(max(1, size.height), maximumFrame.height)

        var origin = frame.origin
        let minX = maximumFrame.minX
        let maxX = maximumFrame.maxX - size.width
        let minY = maximumFrame.minY
        let maxY = maximumFrame.maxY - size.height
        origin.x = maxX >= minX ? min(max(origin.x, minX), maxX) : minX
        origin.y = maxY >= minY ? min(max(origin.y, minY), maxY) : minY

        return CGRect(origin: origin, size: size)
    }

    public static func clampedResizeSize(_ proposed: CGSize, aspect: CGSize?, within maximumSize: CGSize) -> CGSize {
        let preferred = aspect ?? proposed
        return aspectFittedSize(preferred, within: CGSize(
            width: min(max(1, proposed.width), max(1, maximumSize.width)),
            height: min(max(1, proposed.height), max(1, maximumSize.height))
        ), allowUpscale: true)
    }
}
