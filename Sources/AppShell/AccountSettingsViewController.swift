import AppKit
import MatrixCore

final class AccountSettingsViewController: NSViewController {
    private let state: WorkspaceStateController

    private let titleField = NSTextField(labelWithString: "Accounts")
    private let subtitleField = NSTextField(wrappingLabelWithString: "Add another Matrix account or remove the currently selected one. Accounts stay separate in the sidebar, room list, timeline, receipts, and media queues.")
    private let activeAccountField = NSTextField(labelWithString: "")
    private let accountsListField = NSTextField(wrappingLabelWithString: "")
    private let serverField = NSTextField(string: "")
    private let usernameField = NSTextField(string: "")
    private let passwordField = NSSecureTextField(string: "")
    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let addAccountButton = NSButton(title: "Add Account", target: nil, action: nil)
    private let removeCurrentButton = NSButton(title: "Remove Current Account", target: nil, action: nil)

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
        activeAccountField.textColor = .secondaryLabelColor
        accountsListField.maximumNumberOfLines = 0
        accountsListField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        statusField.maximumNumberOfLines = 0
        statusField.textColor = .secondaryLabelColor
        statusField.isHidden = true

        serverField.placeholderString = "Server name or homeserver URL"
        usernameField.placeholderString = "Username or @user:server"
        passwordField.placeholderString = "Password"

        addAccountButton.target = self
        addAccountButton.action = #selector(addAccount(_:))
        addAccountButton.bezelStyle = .rounded
        addAccountButton.keyEquivalent = "\r"
        addAccountButton.setAccessibilityLabel("Add account")

        removeCurrentButton.target = self
        removeCurrentButton.action = #selector(removeCurrentAccount(_:))
        removeCurrentButton.bezelStyle = .rounded

        let formStack = NSStackView(views: [
            labeledRow(title: "Server", field: serverField),
            labeledRow(title: "Username", field: usernameField),
            labeledRow(title: "Password", field: passwordField)
        ])
        formStack.orientation = .vertical
        formStack.spacing = 12

        let buttonRow = NSStackView(views: [addAccountButton, removeCurrentButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .leading
        buttonRow.spacing = 10

        let contentStack = NSStackView(views: [
            titleField,
            subtitleField,
            activeAccountField,
            accountsListField,
            formStack,
            buttonRow,
            statusField
        ])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.documentView = contentStack
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            contentStack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor, constant: 24),
            contentStack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor, constant: -24),
            contentStack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor, constant: 24),
            contentStack.bottomAnchor.constraint(equalTo: scrollView.contentView.bottomAnchor, constant: -24),
            contentStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor, constant: -48)
        ])

        view = root
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        state.addSidebarObserver { [weak self] in
            self?.reloadData()
        }
        state.addSelectionObserver { [weak self] in
            self?.reloadData()
        }
        state.addSessionObserver { [weak self] in
            self?.reloadData()
        }
        reloadData()
    }

    @objc
    private func addAccount(_ sender: Any?) {
        state.addAccount(
            serverNameOrURL: serverField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            username: usernameField.stringValue,
            password: passwordField.stringValue
        )
    }

    @objc
    private func removeCurrentAccount(_ sender: Any?) {
        state.removeCurrentAccount()
    }

    private func reloadData() {
        if let selectedAccount = state.selectedAccountSummary {
            activeAccountField.stringValue = "Current: \(selectedAccount.displayName)  •  \(selectedAccount.userID)"
        } else {
            activeAccountField.stringValue = "No account selected."
        }

        if state.accounts.isEmpty {
            accountsListField.stringValue = "No saved accounts."
        } else {
            accountsListField.stringValue = state.accounts.map { account in
                let marker = account.accountID == state.selectedAccountID ? "*" : " "
                return "\(marker) \(account.displayName)  •  \(account.userID)"
            }
            .joined(separator: "\n")
        }

        addAccountButton.isEnabled = !state.isPerformingAccountOperation
        removeCurrentButton.isEnabled = !state.isPerformingAccountOperation && state.selectedAccountID != nil

        if let message = state.accountOperationStatusMessage, !message.isEmpty {
            statusField.isHidden = false
            statusField.textColor = state.isPerformingAccountOperation ||
                message.localizedCaseInsensitiveContains("added") ||
                message.localizedCaseInsensitiveContains("removed")
                ? .secondaryLabelColor
                : .systemRed
            statusField.stringValue = message
            if !state.isPerformingAccountOperation, message.localizedCaseInsensitiveContains("added") {
                serverField.stringValue = ""
                usernameField.stringValue = ""
                passwordField.stringValue = ""
            }
        } else {
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
