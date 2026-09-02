import CoreGraphics
import Foundation
import MatrixCore
import Testing

private let display = CGRect(x: 0, y: 25, width: 1_440, height: 875)
private let user = CGRect(x: 80, y: 80, width: 1_200, height: 760)
private let contentGrown = CGRect(x: 80, y: 40, width: 1_600, height: 1_100)

private let contentReasons: [WindowFrameAdjustmentReason] = [
    .roomContent,
    .headerExpansion,
    .unreadList,
    .sessionPresentation,
    .splitView,
    .textLayout
]

@Suite("WindowFramePolicyTests")
struct WindowFramePolicyTests {
@Test
func validUserFrameIsPreservedExactly() {
    let sanitized = WindowFramePolicy.sanitizedFrame(user, visibleFrame: display, centerIfNeeded: true)

    #expect(WindowFramePolicy.shouldPreserveCurrentFrame(user, in: display))
    #expect(sanitized == user)
}

@Test
func validUserSizeIsUnchangedAcrossContentDrivenReasons() {
    for reason in contentReasons {
        let resolved = WindowFramePolicy.resolvedFrame(
            current: user,
            proposed: contentGrown,
            visibleFrame: display,
            reason: reason
        )
        #expect(resolved.size.width == user.size.width, "\(reason)")
        #expect(resolved.size.height == user.size.height, "\(reason)")
        #expect(WindowFramePolicy.isFullyContained(resolved, in: display), "\(reason)")
        #expect(!WindowFramePolicy.allowsContentDrivenSizeChange(from: user.size, to: contentGrown.size))
    }
}

@Test
func validUserSizeIsUnchangedAcrossSessionPresentationAndSplitViewWhenAlreadyOnScreen() {
    let afterSession = WindowFramePolicy.resolvedFrame(
        current: user,
        proposed: CGRect(x: 0, y: 0, width: 900, height: 560),
        visibleFrame: display,
        reason: .sessionPresentation
    )
    let afterSplit = WindowFramePolicy.resolvedFrame(
        current: user,
        proposed: CGRect(x: 80, y: 80, width: 1_480, height: 760),
        visibleFrame: display,
        reason: .splitView
    )
    #expect(afterSession.size == user.size)
    #expect(afterSplit.size == user.size)
}

@Test
func screenChangePreservesValidSizeWhenTheNewDisplayStillFitsIt() {
    let newDisplay = CGRect(x: 1_440, y: 25, width: 1_920, height: 1_080)
    let resolved = WindowFramePolicy.resolvedFrame(
        current: user,
        proposed: CGRect(x: 1_520, y: 80, width: 1_200, height: 760),
        visibleFrame: newDisplay,
        reason: .screenChange
    )
    #expect(resolved.width == user.width)
    #expect(resolved.height == user.height)
    #expect(WindowFramePolicy.isFullyContained(resolved, in: newDisplay))
}

@Test
func screenChangeShrinksOnlyWhenTheUserSizeCannotFit() {
    let smallDisplay = CGRect(x: 0, y: 0, width: 1_024, height: 640)
    let resolved = WindowFramePolicy.resolvedFrame(
        current: user,
        proposed: user,
        visibleFrame: smallDisplay,
        reason: .screenChange
    )
    #expect(resolved.width == smallDisplay.width)
    #expect(resolved.height == smallDisplay.height)
    #expect(WindowFramePolicy.isFullyContained(resolved, in: smallDisplay))
}

@Test
func entirelyOffscreenFrameMovesOntoSelectedDisplayWithoutResettingValidSize() {
    let offscreen = CGRect(x: 4_000, y: -2_000, width: 1_100, height: 720)
    let screens = [display, CGRect(x: 1_440, y: 25, width: 1_920, height: 1_080)]
    let selected = WindowFramePolicy.visibleFrame(containing: offscreen, screens: screens) ?? display
    let sanitized = WindowFramePolicy.resolvedFrame(
        current: offscreen,
        proposed: offscreen,
        visibleFrame: selected,
        reason: .recovery
    )

    #expect(!WindowFramePolicy.shouldPreserveCurrentFrame(offscreen, in: display))
    #expect(WindowFramePolicy.isFullyContained(sanitized, in: selected))
    #expect(sanitized.width == 1_100)
    #expect(sanitized.height == 720)
}

@Test
func partiallyOffscreenFrameIsClampedEntirelyInsideAndKeepsUserSize() {
    let partial = CGRect(x: 1_200, y: -80, width: 1_000, height: 700)
    let sanitized = WindowFramePolicy.sanitizedFrame(partial, visibleFrame: display, centerIfNeeded: false)

    #expect(WindowFramePolicy.isFullyContained(sanitized, in: display))
    #expect(sanitized.width == 1_000)
    #expect(sanitized.height == 700)
}

@Test
func contentDrivenGrowthIsRejectedAndDoesNotFillTheDisplay() {
    let resolved = WindowFramePolicy.resolvedFrame(
        current: user,
        proposed: CGRect(x: 40, y: 40, width: 3_200, height: 2_200),
        visibleFrame: display,
        reason: .textLayout
    )
    #expect(resolved.size == user.size)
    #expect(resolved.size != display.size)
    #expect(WindowFramePolicy.isFullyContained(resolved, in: display))
}

@Test
func twoByTwoCorruptFrameIsRecoveredEntirelyInsideTheVisibleFrame() {
    let corrupt = CGRect(x: 12, y: 12, width: 2, height: 2)
    let sanitized = WindowFramePolicy.resolvedFrame(
        current: corrupt,
        proposed: corrupt,
        visibleFrame: display,
        reason: .recovery
    )

    #expect(WindowFramePolicy.isAbsurdSize(corrupt.size))
    #expect(sanitized.width == min(WindowFramePolicy.recoverySize.width, display.width))
    #expect(sanitized.height == min(WindowFramePolicy.recoverySize.height, display.height))
    #expect(WindowFramePolicy.isFullyContained(sanitized, in: display))
}

@Test
func compactButValidUserSizeIsNotTreatedAsCorrupt() {
    let compact = CGRect(x: 40, y: 40, width: 420, height: 320)
    let sanitized = WindowFramePolicy.sanitizedFrame(compact, visibleFrame: display, centerIfNeeded: true)
    #expect(WindowFramePolicy.isUsableSize(compact.size))
    #expect(sanitized == compact)
}

@Test
func screenChangePicksTheDisplayWithTheLargestOverlap() {
    let left = CGRect(x: 0, y: 0, width: 1_280, height: 800)
    let right = CGRect(x: 1_280, y: 0, width: 1_920, height: 1_080)
    let straddling = CGRect(x: 1_100, y: 40, width: 900, height: 640)
    let selected = WindowFramePolicy.visibleFrame(containing: straddling, screens: [left, right])

    #expect(selected == right)
}

@Test
func windowLimitsNeverExceedTheVisibleDisplay() {
    let tiny = CGRect(x: 0, y: 0, width: 800, height: 500)
    let minimum = WindowFramePolicy.windowMinimumSize(within: tiny)
    let maximum = WindowFramePolicy.windowMaximumSize(within: tiny)
    #expect(minimum.width <= tiny.width)
    #expect(minimum.height <= tiny.height)
    #expect(maximum.width == tiny.width)
    #expect(maximum.height == tiny.height)
}
}
