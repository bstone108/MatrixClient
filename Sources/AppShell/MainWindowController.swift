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
    private var userAdjustedWindowFrame = false

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
        window.minSize = NSSize(
            width: WindowFramePolicy.minimumSize.width,
            height: WindowFramePolicy.minimumSize.height
        )
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = false
        restorePersistedWindowFrame()
        buildWorkspaceUI()
        updatePresentation()
        restoreWindowFrameIfNeeded(centerIfReset: false)
        scheduleWindowFrameStabilization(preferPersistedFrame: true, centerIfNeeded: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc
    func toggleInspector(_ sender: Any?) {
        inspectorItem?.isCollapsed.toggle()
        persistInspectorCollapsedState()
    }

    func showAndFocusWindow() {
        isRestoringInitialFrame = true
        restoreWindowFrameIfNeeded(centerIfReset: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        scheduleWindowFrameStabilization(preferPersistedFrame: true, centerIfNeeded: false)
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
        railItem.minimumThickness = 168
        railItem.maximumThickness = 240
        railItem.canCollapse = true

        let roomListItem = NSSplitViewItem(contentListWithViewController: roomList)
        roomListItem.minimumThickness = 220
        roomListItem.maximumThickness = 340

        let timelineItem = NSSplitViewItem(viewController: contentHost)
        timelineItem.minimumThickness = 420
        timelineItem.holdingPriority = NSLayoutConstraint.Priority(249)

        let inspectorItem = NSSplitViewItem(inspectorWithViewController: inspector)
        inspectorItem.minimumThickness = 240
        inspectorItem.maximumThickness = 360
        inspectorItem.canCollapse = true
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(240)

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
            self.constrainWindowFrameToVisibleDisplay(allowPersistedFallback: false)
        }
        state.addSessionObserver { [weak self] in
            self?.updatePresentation()
        }
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
            let screens = NSScreen.screens.map { CGRect($0.visibleFrame) }
            let visible = WindowFramePolicy.visibleFrame(containing: CGRect(storedFrame), screens: screens)
                ?? screens.first
                ?? CGRect(NSScreen.main?.visibleFrame ?? .zero)
            applyManagedFrame(
                NSRect(WindowFramePolicy.sanitizedFrame(CGRect(storedFrame), visibleFrame: visible, centerIfNeeded: false)),
                display: false
            )
        } else {
            applyManagedFrame(defaultWindowFrame(centered: true), display: false)
        }
    }

    private func restoreWindowFrameIfNeeded(centerIfReset: Bool) {
        constrainWindowFrameToVisibleDisplay(allowPersistedFallback: true, centerIfUnusable: centerIfReset)
    }

    private func scheduleWindowFrameStabilization(preferPersistedFrame: Bool, centerIfNeeded: Bool) {
        frameStabilizationTask?.cancel()
        frameStabilizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.constrainWindowFrameToVisibleDisplay(
                allowPersistedFallback: preferPersistedFrame,
                centerIfUnusable: centerIfNeeded
            )
            try? await Task.sleep(for: .milliseconds(150))
            self?.constrainWindowFrameToVisibleDisplay(allowPersistedFallback: false, centerIfUnusable: false)
            self?.isRestoringInitialFrame = false
            self?.saveWindowFrame()
        }
    }

    private func constrainWindowFrameToVisibleDisplay(
        allowPersistedFallback: Bool,
        centerIfUnusable: Bool = false
    ) {
        guard let window else { return }
        let screens = NSScreen.screens.map { CGRect($0.visibleFrame) }
        let current = CGRect(window.frame)
        let visible = WindowFramePolicy.visibleFrame(containing: current, screens: screens)
            ?? screens.first
            ?? CGRect(NSScreen.main?.visibleFrame ?? .zero)

        let minSize = WindowFramePolicy.clampedMinimumSize(within: visible)
        window.minSize = NSSize(width: minSize.width, height: minSize.height)

        if WindowFramePolicy.shouldPreserveCurrentFrame(current, in: visible) {
            return
        }

        let base: CGRect
        if allowPersistedFallback, let persisted = persistedWindowFrame() {
            base = CGRect(persisted)
        } else if WindowFramePolicy.isUsableSize(current.size) {
            base = current
        } else if let persisted = persistedWindowFrame() {
            base = CGRect(persisted)
        } else {
            base = CGRect(defaultWindowFrame(centered: centerIfUnusable))
        }

        let target = NSRect(
            WindowFramePolicy.sanitizedFrame(
                base,
                visibleFrame: visible,
                centerIfNeeded: centerIfUnusable && !WindowFramePolicy.isUsableSize(current.size)
            )
        )
        if !window.frame.equalTo(target) {
            applyManagedFrame(target, display: window.isVisible)
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
        let frame = NSRect(
            WindowFramePolicy.sanitizedFrame(
                CGRect(window.frame),
                visibleFrame: currentVisibleFrame(),
                centerIfNeeded: false
            )
        )
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: WindowPersistence.frameKey)
    }

    private func applyManagedFrame(_ frame: NSRect, display: Bool) {
        guard let window else { return }
        isApplyingManagedFrame = true
        window.setFrame(frame, display: display)
        DispatchQueue.main.async { [weak self] in
            self?.isApplyingManagedFrame = false
        }
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

    private func currentVisibleFrame() -> CGRect {
        let screens = NSScreen.screens.map { CGRect($0.visibleFrame) }
        if let window,
           let visible = WindowFramePolicy.visibleFrame(containing: CGRect(window.frame), screens: screens) {
            return visible
        }
        return screens.first ?? CGRect(NSScreen.main?.visibleFrame ?? .zero)
    }

    private func updatePresentation() {
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
        isRestoringInitialFrame = true
        constrainWindowFrameToVisibleDisplay(allowPersistedFallback: true, centerIfUnusable: true)
        scheduleWindowFrameStabilization(preferPersistedFrame: false, centerIfNeeded: false)
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
    func windowDidMove(_ notification: Notification) {
        if !isApplyingManagedFrame, !isRestoringInitialFrame {
            userAdjustedWindowFrame = true
        }
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        if !isApplyingManagedFrame, !isRestoringInitialFrame {
            userAdjustedWindowFrame = true
            constrainWindowFrameToVisibleDisplay(allowPersistedFallback: false)
        }
        saveWindowFrame()
        persistInspectorCollapsedState()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        restoreWindowFrameIfNeeded(centerIfReset: false)
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        constrainWindowFrameToVisibleDisplay(allowPersistedFallback: false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        constrainWindowFrameToVisibleDisplay(allowPersistedFallback: false)
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        constrainWindowFrameToVisibleDisplay(allowPersistedFallback: false)
        saveWindowFrame()
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleInspector = NSToolbarItem.Identifier("toggleInspector")
    static let exportBundle = NSToolbarItem.Identifier("exportBundle")
}
