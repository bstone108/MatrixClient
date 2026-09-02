import AppKit
import Diagnostics
import Foundation
import MatrixCore
import Testing
@testable import AppShell

private let contentReasons: [WindowFrameAdjustmentReason] = [
    .roomContent,
    .headerExpansion,
    .unreadList,
    .sessionPresentation,
    .splitView,
    .textLayout
]

private func isolatedDefaults() -> UserDefaults {
    let suite = "MainWindowFrameIntegrationTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

@MainActor
private func makeTestWindow(frame: NSRect) -> NSWindow {
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: frame.size),
        styleMask: [.titled, .closable, .miniaturizable, .resizable],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    window.setFrame(frame, display: false)
    return window
}

@MainActor
private func isFullyOnAScreen(_ frame: NSRect) -> Bool {
    let screens = NSScreen.screens
    if screens.isEmpty {
        return frame.width > 0 && frame.height > 0
    }
    return screens.contains { screen in
        WindowFramePolicy.isFullyContained(
            AppKitWindowFrameBridge.policyRect(frame),
            in: AppKitWindowFrameBridge.policyRect(screen.visibleFrame)
        )
    }
}

@MainActor
private func makeMainWindowController() -> MainWindowController {
    MainWindowController.WindowPersistence.defaults = isolatedDefaults()
    MainWindowController.WindowPersistence.splitAutosaveName = "MatrixClient.TestSplit.\(UUID().uuidString)"
    MainWindowController.WindowPersistence.skipDeferredFrameRestore = true
    let diagnostics = DiagnosticsService(subsystem: "test.main-window-frame")
    let state = WorkspaceStateController(
        matrixClient: WindowFrameTestMatrixClient(),
        diagnostics: diagnostics,
        supportBundleBuilder: SupportBundleBuilder(diagnostics: diagnostics),
        defaults: isolatedDefaults()
    )
    return MainWindowController(state: state, videoPlaybackEngine: WindowFrameTestVideoEngine())
}

@Suite("MainWindowFrameIntegrationTests")
@MainActor
struct MainWindowFrameIntegrationTests {
@Test
@MainActor
func realNSWindowRejectsContentDrivenGrowthAndStaysOnScreen() {
    let visible = AppKitWindowFrameBridge.visibleFrame(
        containing: NSScreen.main?.visibleFrame ?? .zero,
        screens: NSScreen.screens
    )
    let user = AppKitWindowFrameBridge.windowRect(
        CGRect(x: visible.minX + 40, y: visible.minY + 40, width: min(960, visible.width), height: min(640, visible.height))
    )
    let window = makeTestWindow(frame: user)
    let grown = NSRect(
        x: user.origin.x,
        y: user.origin.y,
        width: user.size.width + 800,
        height: user.size.height + 600
    )

    for reason in contentReasons {
        let after = AppKitWindowFrameBridge.applyResolvedFrame(
            to: window,
            current: user,
            proposed: grown,
            visibleFrame: visible,
            reason: reason
        )
        #expect(after.size.width == user.size.width, "\(reason)")
        #expect(after.size.height == user.size.height, "\(reason)")
        #expect(window.frame.size.width == user.size.width, "\(reason)")
        #expect(window.frame.size.height == user.size.height, "\(reason)")
        #expect(isFullyOnAScreen(window.frame), "\(reason)")
    }
}

@Test
@MainActor
func realNSWindowRecoversTwoByTwoAndStaysInsideVisibleFrame() {
    let visible = AppKitWindowFrameBridge.visibleFrame(
        containing: NSScreen.main?.visibleFrame ?? .zero,
        screens: NSScreen.screens
    )
    let corrupt = NSRect(x: visible.minX + 12, y: visible.minY + 12, width: 2, height: 2)
    let window = makeTestWindow(frame: corrupt)
    AppKitWindowFrameBridge.applyResolvedFrame(
        to: window,
        current: corrupt,
        proposed: corrupt,
        visibleFrame: visible,
        reason: .recovery
    )
    #expect(window.frame.width > 8)
    #expect(window.frame.height > 8)
    #expect(isFullyOnAScreen(window.frame))
}

@Test
@MainActor
func windowWillResizeLocksNonUserSizeChanges() {
    let visible = AppKitWindowFrameBridge.visibleFrame(
        containing: NSScreen.main?.visibleFrame ?? .zero,
        screens: NSScreen.screens
    )
    let current = AppKitWindowFrameBridge.windowRect(
        CGRect(x: visible.minX + 50, y: visible.minY + 50, width: min(1_100, visible.width), height: min(700, visible.height))
    )
    let locked = AppKitWindowFrameBridge.sizeAfterWillResize(
        current: current,
        proposedSize: NSSize(width: 4_000, height: 3_000),
        visibleFrame: visible,
        isUserDriven: false
    )
    #expect(locked.width == current.size.width)
    #expect(locked.height == current.size.height)
}

@Test
@MainActor
func mainWindowControllerInitAndContentChangesKeepSizeOnScreen() throws {
    let controller = makeMainWindowController()
    defer {
        MainWindowController.WindowPersistence.skipDeferredFrameRestore = false
        MainWindowController.WindowPersistence.defaults = .standard
        MainWindowController.WindowPersistence.splitAutosaveName = "MatrixClient.MainSplitView"
    }
    let window = try #require(controller.window)
    let initial = window.frame

    #expect(WindowFramePolicy.isUsableSize(AppKitWindowFrameBridge.policySize(initial.size)))
    #expect(isFullyOnAScreen(initial))
    #expect(controller.testingLastValidUserFrame != nil)

    controller.applyResolvedFrameForTesting(
        reason: .roomContent,
        proposed: NSRect(
            x: initial.origin.x,
            y: initial.origin.y,
            width: initial.size.width + 1_200,
            height: initial.size.height + 800
        )
    )
    #expect(window.frame.size.width == initial.size.width)
    #expect(window.frame.size.height == initial.size.height)
    #expect(isFullyOnAScreen(window.frame))

    controller.applyResolvedFrameForTesting(reason: .headerExpansion, proposed: window.frame)
    controller.applyResolvedFrameForTesting(reason: .unreadList, proposed: window.frame)
    controller.applyResolvedFrameForTesting(reason: .sessionPresentation, proposed: window.frame)
    controller.toggleInspector(nil)
    #expect(window.frame.size.width == initial.size.width)
    #expect(window.frame.size.height == initial.size.height)
    #expect(isFullyOnAScreen(window.frame))

    let refused = controller.windowWillResize(
        window,
        to: NSSize(width: 5_000, height: 4_000)
    )
    #expect(refused.width == initial.size.width)
    #expect(refused.height == initial.size.height)
}
}
