import AppKit
import MatrixCore
import MediaKit
import TimelineUI

final class MainWindowController: NSWindowController {

    private enum WindowPersistence {
        static let frameKey = "MainWindow.frame"
        static let inspectorCollapsedKey = "MainWindow.inspectorCollapsed"
        static let splitAutosaveName = "MatrixClient.MainSplitView"
    }

    private let state: WorkspaceStateController
    private let videoPlaybackEngine: any VideoPlaybackEngine
    private let splitViewController = NSSplitViewController()
    private lazy var loginViewController = LoginViewController(state: state)
    private var inspectorItem: NSSplitViewItem?
    private var toolbarController: NSToolbar?
    private var frameStabilizationTask: Task<Void, Never>?
    private var isApplyingManagedFrame = false
    private var isRestoringInitialFrame = true
    private var isUserLiveResizing = false
    private var lastValidUserFrame: NSRect?

    init(state: WorkspaceStateController, videoPlaybackEngine: any VideoPlaybackEngine) {
        self.state = state
        self.videoPlaybackEngine = videoPlaybackEngine
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: NSSize(width: WindowFramePolicy.defaultSize.width, height: WindowFramePolicy.defaultSize.height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Matrix Client"
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        applyWindowSizeLimits()
        restorePersistedWindowFrame()
        buildWorkspaceUI()
        preventContentFromDrivingWindowSize()
        updatePresentation()
        applyResolvedFrame(reason: .recovery, proposed: window.frame)
        scheduleLockedFrameRestore(reason: .recovery)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    func toggleInspector(_ sender: Any?) {
        inspectorItem?.isCollapsed.toggle()
        persistInspectorCollapsedState()
        applyResolvedFrame(reason: .splitView, proposed: window?.frame ?? .zero)
    }

    func showAndFocusWindow() {
        isRestoringInitialFrame = true
        applyResolvedFrame(reason: .recovery, proposed: lastValidUserFrame ?? window?.frame ?? .zero)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        scheduleLockedFrameRestore(reason: .recovery)
    }

    @objc
    func exportSupportBundle(_ sender: Any?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await state.exportSupportBundle()
                await MainActor.run {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } catch {
                await MainActor.run {
                    let alert = NSAlert()
                    alert.alertStyle = .critical
                    alert.messageText = "Export Failed"
                    alert.informativeText = error.localizedDescription
                    alert.runModal()
                }
            }
        }
    }

    func persistWindowFrame() {
        saveWindowFrame()
        persistInspectorCollapsedState()
    }

    private func persistInspectorCollapsedState() {
        guard let inspectorItem else { return }
        UserDefaults.standard.set(inspectorItem.isCollapsed, forKey: WindowPersistence.inspectorCollapsedKey)
    }

    private func persistedInspectorCollapsed() -> Bool {
        if UserDefaults.standard.object(forKey: WindowPersistence.inspectorCollapsedKey) == nil {
            return true
        }
        return UserDefaults.standard.bool(forKey: WindowPersistence.inspectorCollapsedKey)
    }

    private func buildWorkspaceUI() {
        let rail = RailViewController(state: state)
        let roomList = RoomListViewController(state: state)
        let contentHost = ContentHostViewController(state: state, videoPlaybackEngine: videoPlaybackEngine)
        let inspector = InspectorViewController(state: state)

        let railItem = NSSplitViewItem(sidebarWithViewController: rail)
        railItem.minimumThickness = 80
        railItem.maximumThickness = 240
        railItem.canCollapse = true

        let roomListItem = NSSplitViewItem(contentListWithViewController: roomList)
        roomListItem.minimumThickness = 80
        roomListItem.maximumThickness = 340

        let timelineItem = NSSplitViewItem(viewController: contentHost)
        timelineItem.minimumThickness = 160
        timelineItem.holdingPriority = NSLayoutConstraint.Priority(1)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 80
        inspectorItem.maximumThickness = 360
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(1)

        splitViewController.splitView.isVertical = true
        splitViewController.splitView.dividerStyle = .thin
        splitViewController.splitView.autosaveName = WindowPersistence.splitAutosaveName
        splitViewController.addSplitViewItem(railItem)
        splitViewController.addSplitViewItem(roomListItem)
        splitViewController.addSplitViewItem(timelineItem)
        splitViewController.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem
        inspectorItem.isCollapsed = persistedInspectorCollapsed()

        toolbarController = buildToolbar()

        state.addSelectionObserver { [weak self] in
            guard let self else { return }
            if self.state.sessionState.showsWorkspace {
                self.window?.title = self.state.currentWindowTitle
            }
        }
        state.addSessionObserver { [weak self] in
            self?.updatePresentation()
        }
    }

    private func preventContentFromDrivingWindowSize() {
        splitViewController.view.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        splitViewController.view.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        splitViewController.view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        splitViewController.view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        splitViewController.splitView.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        splitViewController.splitView.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        splitViewController.splitView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        splitViewController.splitView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
        loginViewController.view.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
        loginViewController.view.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
        loginViewController.view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
        loginViewController.view.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
    }

    private func buildToolbar() -> NSToolbar {
        let toolbar = NSToolbar(identifier: "MatrixClientToolbar")
        toolbar.displayMode = .iconOnly
        toolbar.delegate = self
        return toolbar
    }

    private func restorePersistedWindowFrame() {
        guard window != nil else { return }
        if let storedFrame = persistedWindowFrame() {
            applyResolvedFrame(reason: .userInteraction, proposed: storedFrame, currentOverride: storedFrame)
        } else {
            applyManagedFrame(defaultWindowFrame(centered: true), display: false)
            rememberValidUserFrame(window?.frame)
        }
    }

    private func scheduleLockedFrameRestore(reason: WindowFrameAdjustmentReason) {
        let locked = lastValidUserFrame ?? window?.frame
        frameStabilizationTask?.cancel()
        frameStabilizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.applyResolvedFrame(reason: reason, proposed: locked ?? .zero, currentOverride: locked)
            try? await Task.sleep(for: .milliseconds(150))
            self?.applyResolvedFrame(reason: reason, proposed: locked ?? .zero, currentOverride: locked)
            self?.isRestoringInitialFrame = false
            self?.saveWindowFrame()
        }
    }

    private func applyResolvedFrame(
        reason: WindowFrameAdjustmentReason,
        proposed: NSRect,
        currentOverride: NSRect? = nil
    ) {
        guard let window else { return }
        applyWindowSizeLimits()
        let current = currentOverride ?? lastValidUserFrame ?? window.frame
        let resolved = NSRect(
            WindowFramePolicy.resolvedFrame(
                current: CGRect(current),
                proposed: CGRect(proposed),
                visibleFrame: currentVisibleFrame(for: current),
                reason: reason
            )
        )
        if !window.frame.equalTo(resolved) {
            applyManagedFrame(resolved, display: window.isVisible)
        }
        if WindowFramePolicy.shouldPreserveCurrentFrame(CGRect(resolved), in: currentVisibleFrame(for: resolved)) {
            rememberValidUserFrame(resolved)
        }
    }

    private func persistedWindowFrame() -> NSRect? {
        guard let frameString = UserDefaults.standard.string(forKey: WindowPersistence.frameKey) else { return nil }
        let frame = NSRectFromString(frameString)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    private func saveWindowFrame() {
        guard let window else { return }
        guard !isApplyingManagedFrame else { return }
        guard !isRestoringInitialFrame else { return }
        guard window.isVisible, !window.isMiniaturized, !window.styleMask.contains(.fullScreen) else { return }
        let resolved = NSRect(
            WindowFramePolicy.resolvedFrame(
                current: CGRect(lastValidUserFrame ?? window.frame),
                proposed: CGRect(window.frame),
                visibleFrame: currentVisibleFrame(),
                reason: .userInteraction
            )
        )
        UserDefaults.standard.set(NSStringFromRect(resolved), forKey: WindowPersistence.frameKey)
    }

    private func applyManagedFrame(_ frame: NSRect, display: Bool) {
        guard let window else { return }
        isApplyingManagedFrame = true
        window.setFrame(frame, display: display)
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingManagedFrame = false
        }
    }

    private func rememberValidUserFrame(_ frame: NSRect?) {
        guard let frame, WindowFramePolicy.isUsableSize(frame.size) else { return }
        lastValidUserFrame = frame
    }

    private func applyWindowSizeLimits() {
        guard let window else { return }
        let visible = currentVisibleFrame()
        let minimum = WindowFramePolicy.windowMinimumSize(within: visible)
        let maximum = WindowFramePolicy.windowMaximumSize(within: visible)
        window.minSize = NSSize(width: minimum.width, height: minimum.height)
        window.maxSize = NSSize(width: maximum.width, height: maximum.height)
    }

    private func defaultWindowFrame(centered: Bool) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame
            ?? NSRect(origin: .zero, size: NSSize(width: WindowFramePolicy.defaultSize.width, height: WindowFramePolicy.defaultSize.height))
        let width = min(WindowFramePolicy.defaultSize.width, visibleFrame.width)
        let height = min(WindowFramePolicy.defaultSize.height, visibleFrame.height)
        let originX = centered
            ? visibleFrame.midX - (width / 2)
            : visibleFrame.minX + WindowFramePolicy.screenMargin
        let originY = centered
            ? visibleFrame.midY - (height / 2)
            : visibleFrame.maxY - height - WindowFramePolicy.screenMargin
        return NSRect(x: originX, y: originY, width: width, height: height).integral
    }

    private func currentVisibleFrame(for frame: NSRect? = nil) -> CGRect {
        let screens = NSScreen.screens.map { CGRect($0.visibleFrame) }
        let reference = frame ?? window?.frame ?? .zero
        if let visible = WindowFramePolicy.visibleFrame(containing: CGRect(reference), screens: screens) {
            return visible
        }
        return screens.first ?? CGRect(NSScreen.main?.visibleFrame ?? .zero)
    }

    private func updatePresentation() {
        let locked = lastValidUserFrame ?? window?.frame
        switch state.sessionState {
        case .connected, .reconnecting:
            window?.contentViewController = splitViewController
            window?.toolbar = toolbarController
            window?.title = state.currentWindowTitle
        case .launching, .restoring, .signingIn, .signedOut:
            window?.contentViewController = loginViewController
            window?.toolbar = nil
            window?.title = "Matrix Client"
        }
        preventContentFromDrivingWindowSize()
        isRestoringInitialFrame = true
        applyResolvedFrame(reason: .sessionPresentation, proposed: locked ?? .zero, currentOverride: locked)
        scheduleLockedFrameRestore(reason: .sessionPresentation)
    }
}

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleInspector, .exportBundle, .flexibleSpace]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleInspector, .flexibleSpace, .exportBundle]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case .toggleInspector:
            item.label = "Inspector"
            item.paletteLabel = "Toggle Inspector"
            item.toolTip = "Show or hide the inspector"
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: "Toggle inspector")
            item.target = self
            item.action = #selector(toggleInspector(_:))
        case .exportBundle:
            item.label = "Export Logs"
            item.paletteLabel = "Export Support Bundle"
            item.toolTip = "Export a support bundle"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: "Export support bundle")
            item.target = self
            item.action = #selector(exportSupportBundle(_:))
        default:
            return nil
        }
        return item
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let visible = currentVisibleFrame()
        if isApplyingManagedFrame || isUserLiveResizing {
            let resolved = WindowFramePolicy.resolvedFrame(
                current: CGRect(lastValidUserFrame ?? sender.frame),
                proposed: CGRect(origin: sender.frame.origin, size: CGSize(width: frameSize.width, height: frameSize.height)),
                visibleFrame: visible,
                reason: .userInteraction
            )
            return NSSize(width: resolved.width, height: resolved.height)
        }
        let locked = WindowFramePolicy.resolvedFrame(
            current: CGRect(lastValidUserFrame ?? sender.frame),
            proposed: CGRect(origin: sender.frame.origin, size: CGSize(width: frameSize.width, height: frameSize.height)),
            visibleFrame: visible,
            reason: .textLayout
        )
        return NSSize(width: locked.width, height: locked.height)
    }

    func windowWillStartLiveResize(_ notification: Notification) {
        isUserLiveResizing = true
    }

    func windowDidMove(_ notification: Notification) {
        if !isApplyingManagedFrame, !isRestoringInitialFrame {
            applyResolvedFrame(
                reason: .userInteraction,
                proposed: window?.frame ?? .zero,
                currentOverride: window?.frame
            )
        }
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        if !isApplyingManagedFrame, !isRestoringInitialFrame, !isUserLiveResizing {
            applyResolvedFrame(
                reason: .textLayout,
                proposed: window?.frame ?? .zero,
                currentOverride: lastValidUserFrame
            )
        }
        saveWindowFrame()
        persistInspectorCollapsedState()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        applyResolvedFrame(reason: .userInteraction, proposed: lastValidUserFrame ?? window?.frame ?? .zero)
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        applyResolvedFrame(
            reason: .userInteraction,
            proposed: window?.frame ?? .zero,
            currentOverride: window?.frame
        )
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyWindowSizeLimits()
        applyResolvedFrame(reason: .screenChange, proposed: window?.frame ?? .zero, currentOverride: lastValidUserFrame)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        isUserLiveResizing = false
        applyResolvedFrame(reason: .userInteraction, proposed: window?.frame ?? .zero)
        rememberValidUserFrame(window?.frame)
        saveWindowFrame()
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleInspector = NSToolbarItem.Identifier("toggleInspector")
    static let exportBundle = NSToolbarItem.Identifier("exportBundle")
}
