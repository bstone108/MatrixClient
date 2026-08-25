import CoreGraphics
import Foundation
import MatrixCore
import Testing

@Test
func mediaPreviewLayoutNeverUsesNativePixelWidth() {
    let visible = CGRect(x: 0, y: 0, width: 1_440, height: 875)
    let maximumFrame = MediaPreviewLayout.maximumFrame(in: visible)
    let maximumContent = CGSize(width: maximumFrame.width, height: maximumFrame.height - 28)
    let fitted = MediaPreviewLayout.fittedContentSize(
        preferred: CGSize(width: 4_032, height: 3_024),
        within: maximumContent
    )

    #expect(fitted.width <= MediaPreviewLayout.defaultContentSize.width)
    #expect(fitted.width <= maximumContent.width)
    #expect(fitted.height <= maximumContent.height)
    #expect(fitted.width < 4_032)
}

@Test
func mediaPreviewLayoutFitsPortraitWithoutWideSideGutters() {
    let fitted = MediaPreviewLayout.fittedContentSize(
        preferred: CGSize(width: 1_080, height: 1_920),
        within: MediaPreviewLayout.defaultContentSize
    )

    #expect(fitted.width < fitted.height)
    #expect(fitted.width < MediaPreviewLayout.defaultContentSize.width)
    #expect(abs((fitted.width / fitted.height) - (1_080.0 / 1_920.0)) < 0.01)
}

@Test
func mediaPreviewLayoutClampsOversizedFrameOntoVisibleScreen() {
    let visible = CGRect(x: 0, y: 25, width: 1_440, height: 850)
    let maximumFrame = MediaPreviewLayout.maximumFrame(in: visible)
    let offscreen = CGRect(x: -400, y: -200, width: 4_032, height: 3_024)
    let clamped = MediaPreviewLayout.clampedFrame(
        offscreen,
        within: maximumFrame,
        aspect: CGSize(width: 4, height: 3)
    )

    #expect(maximumFrame.contains(clamped) || clamped.integral == clamped.intersection(maximumFrame).integral)
    #expect(clamped.width <= maximumFrame.width)
    #expect(clamped.height <= maximumFrame.height)
    #expect(clamped.minX >= maximumFrame.minX)
    #expect(clamped.maxX <= maximumFrame.maxX + 0.5)
    #expect(clamped.minY >= maximumFrame.minY)
    #expect(clamped.maxY <= maximumFrame.maxY + 0.5)
    #expect(abs((clamped.width / clamped.height) - (4.0 / 3.0)) < 0.02)
}

@Test
func mediaPreviewLayoutDoesNotIndependentlyStretchToScreenAspect() {
    let maximumFrame = CGRect(x: 40, y: 40, width: 1_360, height: 800)
    let imageAspect = CGSize(width: 4, height: 3)
    let fitted = MediaPreviewLayout.fittedContentSize(
        preferred: imageAspect,
        within: maximumFrame.size
    )
    let centered = MediaPreviewLayout.centeredFrame(size: fitted, within: maximumFrame)
    let clamped = MediaPreviewLayout.clampedFrame(centered, within: maximumFrame, aspect: imageAspect)

    #expect(abs(clamped.width - fitted.width) < 1)
    #expect(abs(clamped.height - fitted.height) < 1)
    #expect(clamped.width < maximumFrame.width)
}
