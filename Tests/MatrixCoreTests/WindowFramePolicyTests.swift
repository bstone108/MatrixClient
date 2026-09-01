import CoreGraphics
import Foundation
import MatrixCore
import Testing

private let display = CGRect(x: 0, y: 25, width: 1_440, height: 875)

@Test
func validUserFrameIsPreservedExactly() {
    let user = CGRect(x: 80, y: 80, width: 1_200, height: 760)
    let sanitized = WindowFramePolicy.sanitizedFrame(user, visibleFrame: display, centerIfNeeded: true)

    #expect(WindowFramePolicy.shouldPreserveCurrentFrame(user, in: display))
    #expect(sanitized.origin.x == user.origin.x)
    #expect(sanitized.origin.y == user.origin.y)
    #expect(sanitized.size.width == user.size.width)
    #expect(sanitized.size.height == user.size.height)
}

@Test
func entirelyOffscreenFrameMovesOntoSelectedDisplayWithoutResettingValidSize() {
    let offscreen = CGRect(x: 4_000, y: -2_000, width: 1_100, height: 720)
    let screens = [display, CGRect(x: 1_440, y: 25, width: 1_920, height: 1_080)]
    let selected = WindowFramePolicy.visibleFrame(containing: offscreen, screens: screens)
    let sanitized = WindowFramePolicy.sanitizedFrame(
        offscreen,
        visibleFrame: selected ?? display,
        centerIfNeeded: false
    )

    #expect(!WindowFramePolicy.shouldPreserveCurrentFrame(offscreen, in: display))
    #expect(WindowFramePolicy.isFullyContained(sanitized, in: selected ?? display))
    #expect(sanitized.width == 1_100)
    #expect(sanitized.height == 720)
}

@Test
func partiallyOffscreenFrameIsClampedAndKeepsUserSize() {
    let partial = CGRect(x: 1_200, y: -80, width: 1_000, height: 700)
    let sanitized = WindowFramePolicy.sanitizedFrame(partial, visibleFrame: display, centerIfNeeded: false)

    #expect(WindowFramePolicy.isFullyContained(sanitized, in: display))
    #expect(sanitized.width == 1_000)
    #expect(sanitized.height == 700)
    #expect(sanitized.maxX <= display.maxX + 0.5)
    #expect(sanitized.minY >= display.minY - 0.5)
}

@Test
func contentDrivenGrowthIsShrunkToVisibleFrame() {
    let grown = CGRect(x: 40, y: 40, width: 3_200, height: 2_200)
    let sanitized = WindowFramePolicy.sanitizedFrame(grown, visibleFrame: display, centerIfNeeded: false)

    #expect(sanitized.width == display.width)
    #expect(sanitized.height == display.height)
    #expect(WindowFramePolicy.isFullyContained(sanitized, in: display))
}

@Test
func collapsedFrameIsReplacedThenCenteredOnRequest() {
    let collapsed = CGRect(x: 12, y: 12, width: 120, height: 80)
    let sanitized = WindowFramePolicy.sanitizedFrame(collapsed, visibleFrame: display, centerIfNeeded: true)

    #expect(!WindowFramePolicy.isUsableSize(collapsed.size))
    #expect(sanitized.width == min(WindowFramePolicy.defaultSize.width, display.width))
    #expect(abs(sanitized.midX - display.midX) < 1)
    #expect(abs(sanitized.midY - display.midY) < 1)
    #expect(WindowFramePolicy.isFullyContained(sanitized, in: display))
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
func minimumSizeNeverExceedsTheVisibleDisplay() {
    let tiny = CGRect(x: 0, y: 0, width: 800, height: 500)
    let minimum = WindowFramePolicy.clampedMinimumSize(within: tiny)
    #expect(minimum.width == 800)
    #expect(minimum.height == 500)
}
