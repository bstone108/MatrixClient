import Foundation

/// Prevents AppKit from registering empty or identifier-only tooltips.
///
/// An empty `NSView.toolTip` (including `""` and whitespace) can create a
/// transient `_NSToolTipPanel` / helper window with a shadow and no text.
/// Storing a Matrix room/event ID in `toolTip` is state, not help, and can
/// also surface a stray tooltip on first layout of a hidden or zero-frame
/// control.
public enum TooltipSurfacePolicy: Sendable {
    public static func assignableTooltip(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if looksLikeMatrixIdentifier(trimmed) {
            return nil
        }
        return trimmed
    }

    /// Hidden or zero-size views must not register a tooltip; AppKit can still
    /// spawn the tooltip window at a bogus origin during first launch layout.
    public static func tooltipIfVisible(isHidden: Bool, raw: String?) -> String? {
        guard !isHidden else { return nil }
        return assignableTooltip(raw)
    }

    public static func looksLikeMatrixIdentifier(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sigil = trimmed.first, "!$@#".contains(sigil) else { return false }
        return trimmed.contains(":")
    }

    public static func isIdentifierStateStorageMisuse(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return looksLikeMatrixIdentifier(raw)
    }

    /// Room-header help may be shown as a tooltip; the room ID must never be.
    public static func roomHeaderTooltip(roomID: String?, help: String?) -> String? {
        _ = roomID
        return assignableTooltip(help)
    }
}
