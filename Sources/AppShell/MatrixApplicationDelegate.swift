import AppKit
import TimelineUI

@MainActor
public final class MatrixApplicationDelegate: NSObject, NSApplicationDelegate {
    private var environment: ApplicationEnvironment?
    private var stateController: WorkspaceStateController?
    private var mainWindowController: MainWindowController?
    private var notificationController: NotificationController?
    private var updater: GitHubReleaseUpdater?

    public func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let environment = try ApplicationEnvironment.bootstrap()
            let stateController = WorkspaceStateController(
                matrixClient: environment.matrixClient,
                diagnostics: environment.diagnostics,
                supportBundleBuilder: environment.supportBundleBuilder
            )

            self.environment = environment
            self.stateController = stateController

            let notificationController = NotificationController(
                matrixClient: environment.matrixClient,
                state: stateController,
                diagnostics: environment.diagnostics
            )
            self.notificationController = notificationController

            let updater = GitHubReleaseUpdater(
                diagnostics: environment.diagnostics,
                applicationSupportURL: environment.database.paths.applicationSupportURL
            )
            self.updater = updater

            let controller = MainWindowController(
                state: stateController,
                videoPlaybackEngine: environment.videoPlaybackEngine,
                updater: updater
            )
            mainWindowController = controller

            buildMenu()
            updater.start()
            controller.showAndFocusWindow()
            NSApp.activate(ignoringOtherApps: true)
            notificationController.start()
            stateController.bootstrap()
        } catch {
            let alert = NSAlert(error: error)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    public func applicationDidBecomeActive(_ notification: Notification) {
        notificationController?.applicationDidBecomeActive()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        mainWindowController?.persistWindowFrame()
    }

    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if flag {
            NSApp.activate(ignoringOtherApps: true)
        } else {
            mainWindowController?.showAndFocusWindow()
            NSApp.activate(ignoringOtherApps: true)
        }
        return true
    }

    @objc
    private func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates(force: true)
    }

    @objc
    private func exportSupportBundle(_ sender: Any?) {
        mainWindowController?.exportSupportBundle(sender)
    }

    @objc
    private func toggleInspector(_ sender: Any?) {
        mainWindowController?.toggleInspector(sender)
    }

    private func buildMenu() {
        let mainMenu = NSMenu(title: "MainMenu")

        let appMenuItem = NSMenuItem(title: "Matrix Client", action: nil, keyEquivalent: "")
        mainMenu.addItem(appMenuItem)
        let appMenu = NSMenu(title: "Matrix Client")
        appMenuItem.submenu = appMenu
        appMenu.addItem(withTitle: "About Matrix Client", action: nil, keyEquivalent: "")
        appMenu.addItem(.separator())
        let checkUpdatesItem = NSMenuItem(
            title: "Check for Updates…",
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Matrix Client", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let fileMenuItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        mainMenu.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenuItem.submenu = fileMenu
        let exportItem = NSMenuItem(title: "Export Support Bundle", action: #selector(exportSupportBundle(_:)), keyEquivalent: "e")
        exportItem.target = self
        fileMenu.addItem(exportItem)
        let attachItem = NSMenuItem(title: "Attach File…", action: #selector(TimelineViewController.attachFile(_:)), keyEquivalent: "u")
        attachItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(attachItem)

        let viewMenuItem = NSMenuItem(title: "View", action: nil, keyEquivalent: "")
        mainMenu.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenuItem.submenu = viewMenu
        let inspectorItem = NSMenuItem(title: "Toggle Inspector", action: #selector(toggleInspector(_:)), keyEquivalent: "i")
        inspectorItem.target = self
        viewMenu.addItem(inspectorItem)

        let windowMenuItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenuItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}
