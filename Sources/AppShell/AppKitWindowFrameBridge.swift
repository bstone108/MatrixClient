import AppKit
import MatrixCore

/// Converts and applies window frames without `NSRect(CGRect)` / `CGRect(NSRect)`,
/// which Swift parses as `Decodable.init(from:)` because the types are aliases.
/// AppKit window/screen reads and writes stay on the main actor.
@MainActor
enum AppKitWindowFrameBridge {
    nonisolated static func policyRect(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    nonisolated static func windowRect(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.size.width, height: rect.size.height)
    }

    nonisolated static func policySize(_ size: NSSize) -> CGSize {
        CGSize(width: size.width, height: size.height)
    }

    nonisolated static func windowSize(_ size: CGSize) -> NSSize {
        NSSize(width: size.width, height: size.height)
    }

    static func visibleFrames(of screens: [NSScreen]) -> [CGRect] {
        screens.map { policyRect($0.visibleFrame) }
    }

    static func visibleFrame(containing frame: NSRect, screens: [NSScreen]) -> CGRect {
        if let visible = WindowFramePolicy.visibleFrame(
            containing: policyRect(frame),
            screens: visibleFrames(of: screens)
        ) {
            return visible
        }
        return visibleFrames(of: screens).first ?? policyRect(NSScreen.main?.visibleFrame ?? .zero)
    }

    nonisolated static func resolvedWindowFrame(
        current: NSRect,
        proposed: NSRect,
        visibleFrame: CGRect,
        reason: WindowFrameAdjustmentReason
    ) -> NSRect {
        windowRect(
            WindowFramePolicy.resolvedFrame(
                current: policyRect(current),
                proposed: policyRect(proposed),
                visibleFrame: visibleFrame,
                reason: reason
            )
        )
    }

    /// Apply the same policy the main window uses, then write it onto a real `NSWindow`.
    @discardableResult
    static func applyResolvedFrame(
        to window: NSWindow,
        current: NSRect,
        proposed: NSRect,
        visibleFrame: CGRect,
        reason: WindowFrameAdjustmentReason
    ) -> NSRect {
        let resolved = resolvedWindowFrame(
            current: current,
            proposed: proposed,
            visibleFrame: visibleFrame,
            reason: reason
        )
        if !window.frame.equalTo(resolved) {
            window.setFrame(resolved, display: window.isVisible)
        }
        return window.frame
    }

    nonisolated static func sizeAfterWillResize(
        current: NSRect,
        proposedSize: NSSize,
        visibleFrame: CGRect,
        isUserDriven: Bool
    ) -> NSSize {
        let resolved = WindowFramePolicy.resolvedFrame(
            current: policyRect(current),
            proposed: CGRect(
                origin: current.origin,
                size: policySize(proposedSize)
            ),
            visibleFrame: visibleFrame,
            reason: isUserDriven ? .userInteraction : .textLayout
        )
        return windowSize(CGSize(width: resolved.width, height: resolved.height))
    }
}
