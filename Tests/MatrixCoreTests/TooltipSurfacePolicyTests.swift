import Foundation
import MatrixCore
import Testing

// AppKit `_NSToolTipPanel` windows cannot be instantiated or screenshotted on this
// Linux Cloud VM (no AppKit). These tests cover the assignment rules that prevent
// empty/identifier tooltips from being registered. Visual confirmation of a
// vanished helper window requires a macOS run.

@Test
func emptyOrWhitespaceTooltipsAreNotRegistered() {
    #expect(TooltipSurfacePolicy.assignableTooltip(nil) == nil)
    #expect(TooltipSurfacePolicy.assignableTooltip("") == nil)
    #expect(TooltipSurfacePolicy.assignableTooltip("   \n\t") == nil)
    #expect(TooltipSurfacePolicy.tooltipIfVisible(isHidden: false, raw: "") == nil)
}

@Test
func roomIDMustNotBeStoredAsAHeaderTooltip() {
    let roomID = "!general:example.org"
    #expect(TooltipSurfacePolicy.isIdentifierStateStorageMisuse(roomID))
    #expect(TooltipSurfacePolicy.looksLikeMatrixIdentifier(roomID))
    #expect(TooltipSurfacePolicy.assignableTooltip(roomID) == nil)
    #expect(
        TooltipSurfacePolicy.roomHeaderTooltip(
            roomID: roomID,
            help: RoomHeaderExpansionPolicy.accessibilityHelp(canRevealSubtitle: true)
        ) == "Show or hide the room topic"
    )
    #expect(TooltipSurfacePolicy.roomHeaderTooltip(roomID: roomID, help: nil) == nil)
}

@Test
func hiddenControlsDoNotRegisterATooltipSurface() {
    #expect(
        TooltipSurfacePolicy.tooltipIfVisible(
            isHidden: true,
            raw: "Jump to latest messages"
        ) == nil
    )
    #expect(
        TooltipSurfacePolicy.tooltipIfVisible(
            isHidden: false,
            raw: "Jump to latest messages"
        ) == "Jump to latest messages"
    )
}

@Test
func legitimateHelpTextIsStillAssignable() {
    #expect(TooltipSurfacePolicy.assignableTooltip("Attach file") == "Attach file")
    #expect(TooltipSurfacePolicy.assignableTooltip("Show or hide the inspector") == "Show or hide the inspector")
    #expect(!TooltipSurfacePolicy.looksLikeMatrixIdentifier("Join this room before sending messages."))
}

@Test
func emptyJoinedInspectorTooltipDoesNotCreateASurface() {
    let emptyJoin = [String]().joined(separator: " • ")
    #expect(emptyJoin.isEmpty)
    #expect(TooltipSurfacePolicy.assignableTooltip(emptyJoin) == nil)
}
