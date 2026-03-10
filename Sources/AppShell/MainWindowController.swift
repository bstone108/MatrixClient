import AppKit
import MediaKit
import TimelineUI

final class MainWindowController: NSWindowController {
    private enum WindowMetrics {
        static let defaultSize = NSSize(width: 1_680, height: 980)
        static let minimumSize = NSSize(width: 1_120, height: 720)
        static let collapsedThreshold = NSSize(width: 320, height: 240)
        static let screenMargin: CGFloat = 40
    }

    private enum WindowPersistence {
        static let frameKey = "MainWindow.frame"
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
            contentRect: NSRect(origin: .zero, size: WindowMetrics.defaultSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Matrix Client"
        window.minSize = WindowMetrics.minimumSize
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.delegate = self
        shouldCascadeWindows = true
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
    }

    private func buildWorkspaceUI() {
        let rail = RailViewController(state: state)
        let roomList = RoomListViewController(state: state)
        let contentHost = ContentHostViewController(state: state, videoPlaybackEngine: videoPlaybackEngine)
        let inspector = InspectorViewController(state: state)

        let railItem = NSSplitViewItem(sidebarWithViewController: rail)
        railItem.minimumThickness = 180
        railItem.maximumThickness = 260

        let roomListItem = NSSplitViewItem(viewController: roomList)
        roomListItem.minimumThickness = 260
        roomListItem.maximumThickness = 360

        let timelineItem = NSSplitViewItem(viewController: contentHost)
        timelineItem.minimumThickness = 640

        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 260
        inspectorItem.maximumThickness = 360

        splitViewController.addSplitViewItem(railItem)
        splitViewController.addSplitViewItem(roomListItem)
        splitViewController.addSplitViewItem(timelineItem)
        splitViewController.addSplitViewItem(inspectorItem)
        self.inspectorItem = inspectorItem
        inspectorItem.isCollapsed = false

        toolbarController = buildToolbar()

        state.addSelectionObserver { [weak self] in
            guard let self else { return }
            if case .connected = self.state.sessionState {
                self.window?.title = self.state.currentWindowTitle
            }
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
            applyManagedFrame(sanitizedFrame(for: storedFrame, centerIfNeeded: false), display: false)
        } else {
            applyManagedFrame(defaultWindowFrame(centered: true), display: false)
        }
    }

    private func restoreWindowFrameIfNeeded(centerIfReset: Bool) {
        guard let window else { return }

        let currentFrame = window.frame
        let hasUsableSize = currentFrame.width >= WindowMetrics.collapsedThreshold.width &&
            currentFrame.height >= WindowMetrics.collapsedThreshold.height
        let isOnScreen = visibleFrame(containing: currentFrame)?.intersects(currentFrame) ?? false

        guard !hasUsableSize || !isOnScreen else { return }

        let fallbackFrame = persistedWindowFrame() ?? defaultWindowFrame(centered: centerIfReset)
        applyManagedFrame(sanitizedFrame(for: fallbackFrame, centerIfNeeded: centerIfReset), display: false)
    }

    private func scheduleWindowFrameStabilization(preferPersistedFrame: Bool, centerIfNeeded: Bool) {
        frameStabilizationTask?.cancel()
        frameStabilizationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            self?.stabilizeWindowFrame(preferPersistedFrame: preferPersistedFrame, centerIfNeeded: centerIfNeeded)
            try? await Task.sleep(for: .milliseconds(150))
            self?.stabilizeWindowFrame(preferPersistedFrame: false, centerIfNeeded: centerIfNeeded)
            self?.isRestoringInitialFrame = false
            self?.saveWindowFrame()
        }
    }

    private func stabilizeWindowFrame(preferPersistedFrame: Bool, centerIfNeeded: Bool) {
        guard let window else { return }

        let baseFrame: NSRect
        if let persisted = persistedWindowFrame(), (preferPersistedFrame || !userAdjustedWindowFrame) {
            baseFrame = persisted
        } else if window.frame.width >= WindowMetrics.collapsedThreshold.width,
                  window.frame.height >= WindowMetrics.collapsedThreshold.height {
            baseFrame = window.frame
        } else if let persisted = persistedWindowFrame() {
            baseFrame = persisted
        } else {
            baseFrame = defaultWindowFrame(centered: centerIfNeeded)
        }

        let targetFrame = sanitizedFrame(for: baseFrame, centerIfNeeded: centerIfNeeded)
        if !window.frame.equalTo(targetFrame) {
            applyManagedFrame(targetFrame, display: window.isVisible)
        }
        saveWindowFrame()
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
        let frame = sanitizedFrame(for: window.frame, centerIfNeeded: false)
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

    private func sanitizeVisibleWindowFrameIfNeeded() {
        guard let window else { return }
        let sanitized = sanitizedFrame(for: window.frame, centerIfNeeded: false)
        guard !window.frame.equalTo(sanitized) else { return }
        applyManagedFrame(sanitized, display: window.isVisible)
    }

    private func defaultWindowFrame(centered: Bool) -> NSRect {
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: WindowMetrics.defaultSize)
        let width = min(WindowMetrics.defaultSize.width, visibleFrame.width)
        let height = min(WindowMetrics.defaultSize.height, visibleFrame.height)
        let originX = centered
            ? visibleFrame.midX - (width / 2)
            : visibleFrame.minX + WindowMetrics.screenMargin
        let originY = centered
            ? visibleFrame.midY - (height / 2)
            : visibleFrame.maxY - height - WindowMetrics.screenMargin
        return NSRect(x: originX, y: originY, width: width, height: height).integral
    }

    private func sanitizedFrame(for proposedFrame: NSRect, centerIfNeeded: Bool) -> NSRect {
        let candidateVisibleFrame = visibleFrame(containing: proposedFrame) ?? NSScreen.main?.visibleFrame
        guard let candidateVisibleFrame else {
            return NSRect(origin: .zero, size: WindowMetrics.defaultSize).integral
        }

        let minWidth = min(WindowMetrics.minimumSize.width, candidateVisibleFrame.width)
        let minHeight = min(WindowMetrics.minimumSize.height, candidateVisibleFrame.height)

        let preferredWidth = proposedFrame.width >= WindowMetrics.collapsedThreshold.width
            ? proposedFrame.width
            : WindowMetrics.defaultSize.width
        let preferredHeight = proposedFrame.height >= WindowMetrics.collapsedThreshold.height
            ? proposedFrame.height
            : WindowMetrics.defaultSize.height

        var frame = proposedFrame
        frame.size.width = min(max(preferredWidth, minWidth), candidateVisibleFrame.width)
        frame.size.height = min(max(preferredHeight, minHeight), candidateVisibleFrame.height)

        if centerIfNeeded && (proposedFrame.width < WindowMetrics.collapsedThreshold.width ||
            proposedFrame.height < WindowMetrics.collapsedThreshold.height) {
            frame.origin.x = candidateVisibleFrame.midX - (frame.width / 2)
            frame.origin.y = candidateVisibleFrame.midY - (frame.height / 2)
        }

        let minX = candidateVisibleFrame.minX
        let maxX = candidateVisibleFrame.maxX - frame.width
        let minY = candidateVisibleFrame.minY
        let maxY = candidateVisibleFrame.maxY - frame.height

        frame.origin.x = min(max(frame.origin.x, minX), maxX)
        frame.origin.y = min(max(frame.origin.y, minY), maxY)

        return frame.integral
    }

    private func visibleFrame(containing frame: NSRect) -> NSRect? {
        let candidateFrames = NSScreen.screens.map(\.visibleFrame)
        return candidateFrames.first(where: { $0.insetBy(dx: -WindowMetrics.screenMargin, dy: -WindowMetrics.screenMargin).intersects(frame) })
            ?? candidateFrames.first
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
            item.image = NSImage(systemSymbolName: "sidebar.right", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(toggleInspector(_:))
        case .exportBundle:
            item.label = "Export Logs"
            item.image = NSImage(systemSymbolName: "square.and.arrow.up", accessibilityDescription: nil)
            item.target = self
            item.action = #selector(exportSupportBundle(_:))
        default:
            return nil
        }
        return item
    }

    private func updatePresentation() {
        switch state.sessionState {
        case .connected:
            window?.contentViewController = splitViewController
            window?.toolbar = toolbarController
            window?.title = state.currentWindowTitle
        case .launching, .restoring, .signingIn, .signedOut:
            window?.contentViewController = loginViewController
            window?.toolbar = nil
            window?.title = "Matrix Client"
        }
        isRestoringInitialFrame = true
        restoreWindowFrameIfNeeded(centerIfReset: true)
        scheduleWindowFrameStabilization(preferPersistedFrame: true, centerIfNeeded: true)
    }
}

extension MainWindowController: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        sanitizeVisibleWindowFrameIfNeeded()
        if !isApplyingManagedFrame, !isRestoringInitialFrame {
            userAdjustedWindowFrame = true
        }
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        sanitizeVisibleWindowFrameIfNeeded()
        if !isApplyingManagedFrame, !isRestoringInitialFrame {
            userAdjustedWindowFrame = true
        }
        saveWindowFrame()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        restoreWindowFrameIfNeeded(centerIfReset: false)
        saveWindowFrame()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        scheduleWindowFrameStabilization(preferPersistedFrame: false, centerIfNeeded: false)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        scheduleWindowFrameStabilization(preferPersistedFrame: false, centerIfNeeded: false)
    }
}

private extension NSToolbarItem.Identifier {
    static let toggleInspector = NSToolbarItem.Identifier("toggleInspector")
    static let exportBundle = NSToolbarItem.Identifier("exportBundle")
}
