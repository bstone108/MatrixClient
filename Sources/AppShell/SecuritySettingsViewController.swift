import AppKit

final class SecuritySettingsViewController: NSViewController {
    private let state: WorkspaceStateController
    private let titleField = NSTextField(labelWithString: "Security / Verification")
    private let subtitleField = NSTextField(wrappingLabelWithString: "Verify this session with another Matrix client so encrypted sessions are trusted across devices.")
    private let accountField = NSTextField(labelWithString: "")
    private let verificationStatusField = NSTextField(labelWithString: "")
    private let verificationDeviceField = NSTextField(labelWithString: "")
    private let verificationMessageField = NSTextField(wrappingLabelWithString: "")
    private let verificationEmojiField = NSTextField(wrappingLabelWithString: "")
    private let verificationDecimalsField = NSTextField(wrappingLabelWithString: "")
    private let requestVerificationButton = NSButton(title: "Request Verification", target: nil, action: nil)
    private let startSasButton = NSButton(title: "Start SAS", target: nil, action: nil)
    private let approveVerificationButton = NSButton(title: "Confirm Match", target: nil, action: nil)
    private let cancelOrRejectButton = NSButton(title: "Cancel Verification", target: nil, action: nil)

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
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.maximumNumberOfLines = 0
        accountField.textColor = .secondaryLabelColor
        verificationStatusField.textColor = .secondaryLabelColor
        verificationDeviceField.textColor = .secondaryLabelColor
        verificationMessageField.maximumNumberOfLines = 0
        verificationMessageField.textColor = .secondaryLabelColor
        verificationEmojiField.maximumNumberOfLines = 0
        verificationDecimalsField.maximumNumberOfLines = 0
        verificationDecimalsField.textColor = .secondaryLabelColor

        requestVerificationButton.target = self
        requestVerificationButton.action = #selector(requestVerification(_:))
        requestVerificationButton.setAccessibilityLabel("Request verification")
        startSasButton.target = self
        startSasButton.action = #selector(startSas(_:))
        startSasButton.setAccessibilityLabel("Start SAS verification")
        approveVerificationButton.target = self
        approveVerificationButton.action = #selector(approveVerification(_:))
        approveVerificationButton.setAccessibilityLabel("Confirm match")
        cancelOrRejectButton.target = self
        cancelOrRejectButton.action = #selector(cancelOrRejectVerification(_:))
        cancelOrRejectButton.setAccessibilityLabel("Cancel verification")

        let actionStack = NSStackView(views: [
            requestVerificationButton,
            startSasButton,
            approveVerificationButton,
            cancelOrRejectButton
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .leading
        actionStack.spacing = 10

        let contentStack = NSStackView(views: [
            titleField,
            subtitleField,
            accountField,
            verificationStatusField,
            verificationDeviceField,
            verificationMessageField,
            verificationEmojiField,
            verificationDecimalsField,
            actionStack
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
        state.addInspectorObserver { [weak self] in
            self?.reloadData()
        }
        state.addSelectionObserver { [weak self] in
            self?.reloadData()
        }
        reloadData()
    }

    @objc
    private func requestVerification(_ sender: Any?) {
        state.requestVerification()
    }

    @objc
    private func startSas(_ sender: Any?) {
        state.startSasVerification()
    }

    @objc
    private func approveVerification(_ sender: Any?) {
        state.approveVerification()
    }

    @objc
    private func cancelOrRejectVerification(_ sender: Any?) {
        if state.verificationSnapshot.canApprove {
            state.declineVerification()
        } else {
            state.cancelVerification()
        }
    }

    private func reloadData() {
        if let account = state.selectedAccountSummary {
            accountField.stringValue = "\(account.displayName)  •  \(account.userID)"
        } else {
            accountField.stringValue = "No active account."
        }

        let verification = state.verificationSnapshot
        verificationStatusField.stringValue = "Status: \(verification.statusText)"
        verificationDeviceField.stringValue = "Device ID: \(verification.deviceID ?? "Unknown")"
        verificationMessageField.stringValue = verification.message ?? ""
        verificationMessageField.isHidden = verificationMessageField.stringValue.isEmpty

        if verification.emojis.isEmpty {
            verificationEmojiField.stringValue = ""
            verificationEmojiField.isHidden = true
        } else {
            verificationEmojiField.stringValue = "Emoji SAS:\n" + verification.emojis
                .map { "\($0.symbol) \($0.description)" }
                .joined(separator: "   ")
            verificationEmojiField.isHidden = false
        }

        if verification.decimals.isEmpty {
            verificationDecimalsField.stringValue = ""
            verificationDecimalsField.isHidden = true
        } else {
            verificationDecimalsField.stringValue = "Decimal SAS: " + verification.decimals.map(String.init).joined(separator: " ")
            verificationDecimalsField.isHidden = false
        }

        requestVerificationButton.isHidden = !verification.canRequest
        startSasButton.isHidden = !verification.canStartSas
        approveVerificationButton.isHidden = !verification.canApprove

        let showCancelOrReject = verification.canDecline || verification.canCancel
        cancelOrRejectButton.isHidden = !showCancelOrReject
        cancelOrRejectButton.title = verification.canApprove ? "Reject Verification" : "Cancel Verification"
    }
}
