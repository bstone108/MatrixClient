import AppKit
import MatrixCore

@MainActor
protocol LoginWorkspaceState: AnyObject {
    var sessionState: ClientSessionState { get }
    func addSessionObserver(_ observer: @escaping @MainActor () -> Void)
    func login(serverNameOrURL: String?, username: String, password: String)
}

final class LoginViewController: NSViewController {
    private let state: any LoginWorkspaceState

    private let titleField = NSTextField(labelWithString: "Sign In")
    private let subtitleField = NSTextField(wrappingLabelWithString: "Enter a Matrix server name or homeserver URL. Server-name lookup uses .well-known so you can type a domain like matrix.org instead of the raw homeserver address.")
    private let serverField = NSTextField(string: "")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)

    init(state: any LoginWorkspaceState) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = NSSize(width: 900, height: 560)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: preferredContentSize.width, height: preferredContentSize.height))

        titleField.font = .systemFont(ofSize: 28, weight: .semibold)
        titleField.alignment = .center
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 0
        subtitleField.alignment = .center

        serverField.placeholderString = "Server name or homeserver URL"
        usernameField.placeholderString = "Username or @user:server"
        passwordField.placeholderString = "Password"

        statusField.maximumNumberOfLines = 0
        statusField.textColor = .secondaryLabelColor
        statusField.isHidden = true
        statusField.alignment = .center

        connectButton.bezelStyle = .rounded
        connectButton.controlSize = .large
        connectButton.target = self
        connectButton.action = #selector(attemptLogin)
        connectButton.keyEquivalent = "\r"
        connectButton.setAccessibilityLabel("Connect")

        serverField.nextKeyView = usernameField
        usernameField.nextKeyView = passwordField
        passwordField.nextKeyView = connectButton

        let serverRow = labeledRow(title: "Server", field: serverField)
        let usernameRow = labeledRow(title: "Username", field: usernameField)
        let passwordRow = labeledRow(title: "Password", field: passwordField)

        let card = NSVisualEffectView()
        card.material = .sidebar
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.translatesAutoresizingMaskIntoConstraints = false

        let fieldStack = NSStackView(views: [serverRow, usernameRow, passwordRow])
        fieldStack.orientation = .vertical
        fieldStack.spacing = 12
        fieldStack.translatesAutoresizingMaskIntoConstraints = false

        let contentStack = NSStackView(views: [titleField, subtitleField, fieldStack, statusField, connectButton])
        contentStack.orientation = .vertical
        contentStack.spacing = 16
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(contentStack)
        root.addSubview(card)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            card.widthAnchor.constraint(equalToConstant: 680),

            contentStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 28),
            contentStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -28),
            contentStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 28),
            contentStack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -28),
            fieldStack.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            serverRow.widthAnchor.constraint(equalTo: fieldStack.widthAnchor),
            usernameRow.widthAnchor.constraint(equalTo: fieldStack.widthAnchor),
            passwordRow.widthAnchor.constraint(equalTo: fieldStack.widthAnchor),
            connectButton.heightAnchor.constraint(equalToConstant: 36)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addSessionObserver { [weak self] in
            self?.reloadSessionState()
        }
        reloadSessionState()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(usernameField.stringValue.isEmpty ? usernameField : passwordField)
    }

    @objc
    private func attemptLogin() {
        state.login(
            serverNameOrURL: serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            username: usernameField.stringValue,
            password: passwordField.stringValue
        )
    }

    private func reloadSessionState() {
        connectButton.isEnabled = !state.sessionState.isBusy
        switch state.sessionState {
        case .launching, .restoring, .signingIn:
            statusField.isHidden = false
            statusField.textColor = .secondaryLabelColor
            statusField.stringValue = state.sessionState.statusMessage ?? ""
        case let .signedOut(message):
            if let message, !message.isEmpty {
                statusField.isHidden = false
                statusField.textColor = .systemRed
                statusField.stringValue = message
            } else {
                statusField.isHidden = true
                statusField.stringValue = ""
            }
        case .connected, .reconnecting:
            statusField.isHidden = true
            statusField.stringValue = ""
        }
    }

    private func labeledRow(title: String, field: NSControl) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.translatesAutoresizingMaskIntoConstraints = false
        field.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(label)
        container.addSubview(field)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            label.topAnchor.constraint(equalTo: container.topAnchor),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            field.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 6),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
