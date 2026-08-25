import AppKit

final class NotificationSettingsViewController: NSViewController {
    private let state: WorkspaceStateController

    private let titleField = NSTextField(labelWithString: "Notifications")
    private let subtitleField = NSTextField(
        wrappingLabelWithString: "Use macOS Notification Center banners and sounds for new Matrix messages. Explicitly muted Matrix rooms stay silent."
    )
    private lazy var desktopNotificationsButton = NSButton(
        checkboxWithTitle: "Desktop notifications",
        target: self,
        action: #selector(toggleDesktopNotifications(_:))
    )
    private lazy var soundButton = NSButton(
        checkboxWithTitle: "Play notification sound",
        target: self,
        action: #selector(toggleSound(_:))
    )

    init(state: WorkspaceStateController) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()

        titleField.font = .systemFont(ofSize: 24, weight: .semibold)
        subtitleField.maximumNumberOfLines = 0
        subtitleField.textColor = .secondaryLabelColor

        let contentStack = NSStackView(views: [
            titleField,
            subtitleField,
            desktopNotificationsButton,
            soundButton
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: root.topAnchor, constant: 24)
        ])

        desktopNotificationsButton.setAccessibilityLabel("Desktop notifications")
        soundButton.setAccessibilityLabel("Play notification sound")

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addSessionObserver { [weak self] in
            self?.reloadData()
        }
        reloadData()
    }

    @objc
    private func toggleDesktopNotifications(_ sender: NSButton) {
        state.setDesktopNotificationsEnabled(sender.state == .on)
    }

    @objc
    private func toggleSound(_ sender: NSButton) {
        state.setNotificationSoundEnabled(sender.state == .on)
    }

    private func reloadData() {
        desktopNotificationsButton.state = state.notificationPreferences.desktopNotificationsEnabled ? .on : .off
        soundButton.state = state.notificationPreferences.soundEnabled ? .on : .off
        soundButton.isEnabled = state.notificationPreferences.desktopNotificationsEnabled
    }
}
