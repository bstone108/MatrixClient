import AppKit
import MatrixCore

final class InspectorViewController: NSViewController {
    private let state: WorkspaceStateController
    private let roomSectionField = NSTextField(labelWithString: "Room")
    private let titleField = NSTextField(labelWithString: "")
    private let topicField = NSTextField(wrappingLabelWithString: "")
    private let membersField = NSTextField(labelWithString: "")
    private let membershipField = NSTextField(labelWithString: "")
    private let pinnedField = NSTextField(wrappingLabelWithString: "")
    private let joinButton = NSButton(title: "Join Room", target: nil, action: nil)
    private let downloadsSectionField = NSTextField(labelWithString: "Downloads")
    private let thumbSectionField = NSTextField(labelWithString: "Thumb")
    private let originalSectionField = NSTextField(labelWithString: "Orig")
    private let recoverySectionField = NSTextField(labelWithString: "Fail")
    private let thumbWorkerFields = (0..<2).map { _ in NSTextField(labelWithString: "") }
    private let originalWorkerFields = (0..<2).map { _ in NSTextField(labelWithString: "") }
    private let recoveryWorkerFields = (0..<1).map { _ in NSTextField(labelWithString: "") }
    private let detailsScrollView = NSScrollView()
    private let downloadsCard = NSVisualEffectView()

    init(state: WorkspaceStateController) {
        self.state = state
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView()
        roomSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        roomSectionField.textColor = .secondaryLabelColor
        titleField.font = .systemFont(ofSize: 16, weight: .semibold)
        topicField.maximumNumberOfLines = 0
        membersField.textColor = .secondaryLabelColor
        membershipField.textColor = .secondaryLabelColor
        pinnedField.maximumNumberOfLines = 0
        pinnedField.textColor = .secondaryLabelColor
        joinButton.bezelStyle = .rounded
        joinButton.target = self
        joinButton.action = #selector(joinSelectedRoom)
        joinButton.setAccessibilityLabel("Join room")

        downloadsSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        downloadsSectionField.textColor = .secondaryLabelColor
        thumbSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        thumbSectionField.textColor = .secondaryLabelColor
        originalSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        originalSectionField.textColor = .secondaryLabelColor
        recoverySectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        recoverySectionField.textColor = .secondaryLabelColor
        downloadsSectionField.stringValue = "Media downloads"
        thumbSectionField.stringValue = "Thumbnails"
        originalSectionField.stringValue = "Originals"
        recoverySectionField.stringValue = "Retries"

        let workerFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        for field in thumbWorkerFields + originalWorkerFields + recoveryWorkerFields {
            field.font = workerFont
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.usesSingleLineMode = true
        }

        let separator = NSBox()
        separator.boxType = .separator

        let detailStack = NSStackView(views: [
            roomSectionField,
            titleField,
            topicField,
            membersField,
            membershipField,
            joinButton,
            pinnedField
        ])
        detailStack.orientation = .vertical
        detailStack.spacing = 10
        detailStack.translatesAutoresizingMaskIntoConstraints = false

        detailsScrollView.borderType = .noBorder
        detailsScrollView.drawsBackground = false
        detailsScrollView.hasVerticalScroller = true
        detailsScrollView.translatesAutoresizingMaskIntoConstraints = false
        detailsScrollView.documentView = detailStack

        downloadsCard.material = .sidebar
        downloadsCard.state = .active
        downloadsCard.wantsLayer = true
        downloadsCard.layer?.cornerRadius = 12
        downloadsCard.translatesAutoresizingMaskIntoConstraints = false
        downloadsCard.setContentHuggingPriority(.defaultLow, for: .horizontal)
        downloadsCard.setContentHuggingPriority(.defaultHigh, for: .vertical)
        downloadsCard.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        downloadsCard.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)

        let thumbViews: [NSView] = [downloadsSectionField, thumbSectionField] + thumbWorkerFields
        let originalViews: [NSView] = [separator, originalSectionField] + originalWorkerFields
        let recoveryViews: [NSView] = [recoverySectionField] + recoveryWorkerFields
        let downloadsViews = thumbViews + originalViews + recoveryViews
        let downloadsStack = NSStackView(views: downloadsViews)
        downloadsStack.orientation = NSUserInterfaceLayoutOrientation.vertical
        downloadsStack.spacing = 8
        downloadsStack.translatesAutoresizingMaskIntoConstraints = false
        downloadsCard.addSubview(downloadsStack)

        root.addSubview(detailsScrollView)
        root.addSubview(downloadsCard)

        NSLayoutConstraint.activate([
            detailsScrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            detailsScrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            detailsScrollView.topAnchor.constraint(equalTo: root.topAnchor),
            detailsScrollView.bottomAnchor.constraint(equalTo: downloadsCard.topAnchor, constant: -12),

            detailStack.leadingAnchor.constraint(equalTo: detailsScrollView.contentView.leadingAnchor, constant: 16),
            detailStack.trailingAnchor.constraint(equalTo: detailsScrollView.contentView.trailingAnchor, constant: -16),
            detailStack.topAnchor.constraint(equalTo: detailsScrollView.contentView.topAnchor, constant: 16),
            detailStack.bottomAnchor.constraint(equalTo: detailsScrollView.contentView.bottomAnchor, constant: -16),
            detailStack.widthAnchor.constraint(equalTo: detailsScrollView.contentView.widthAnchor, constant: -32),

            downloadsCard.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            downloadsCard.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            downloadsCard.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            downloadsCard.heightAnchor.constraint(equalToConstant: 260),

            downloadsStack.leadingAnchor.constraint(equalTo: downloadsCard.leadingAnchor, constant: 12),
            downloadsStack.trailingAnchor.constraint(equalTo: downloadsCard.trailingAnchor, constant: -12),
            downloadsStack.topAnchor.constraint(equalTo: downloadsCard.topAnchor, constant: 12),
            downloadsStack.bottomAnchor.constraint(equalTo: downloadsCard.bottomAnchor, constant: -12)
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

    private func reloadData() {
        if let details = state.selectedRoomDetails {
            titleField.stringValue = details.displayName
            topicField.stringValue = details.topic.isEmpty ? "No room topic." : details.topic
            membersField.stringValue = "\(details.memberCount) members  •  \(details.isEncrypted ? "Encrypted" : "Unencrypted")"
            membershipField.stringValue = state.selectedRoomSummary?.membership.label ?? ""
            joinButton.isHidden = state.selectedRoomSummary?.canJoin != true
            pinnedField.stringValue = details.pinnedMessages.isEmpty
                ? "No pinned messages."
                : "Pinned:\n" + details.pinnedMessages.joined(separator: "\n")
        } else if let summary = state.selectedRoomSummary {
            titleField.stringValue = summary.displayName
            topicField.stringValue = summary.topic.isEmpty ? "No room topic." : summary.topic
            membersField.stringValue = summary.isEncrypted ? "Encrypted room" : "Unencrypted room"
            membershipField.stringValue = summary.membership.label
            joinButton.isHidden = !summary.canJoin
            pinnedField.stringValue = summary.membership == .notJoined
                ? "Join this room from the selected space to start syncing messages."
                : "No pinned messages."
        } else {
            titleField.stringValue = "Room Details"
            topicField.stringValue = "Select a room to inspect details, encryption state, and pinned items."
            membersField.stringValue = ""
            membershipField.stringValue = ""
            joinButton.isHidden = true
            pinnedField.stringValue = ""
        }

        applyWorkerLines(
            state.mediaWorkerSnapshots(for: .thumbnail),
            to: thumbWorkerFields
        )
        applyWorkerLines(
            state.mediaWorkerSnapshots(for: .original),
            to: originalWorkerFields
        )
        applyWorkerLines(
            state.mediaWorkerSnapshots(for: .recovery),
            to: recoveryWorkerFields
        )
    }

    @objc
    private func joinSelectedRoom() {
        state.joinSelectedRoom()
    }

    private func applyWorkerLines(_ snapshots: [MediaDownloadWorkerSnapshot], to fields: [NSTextField]) {
        for (index, field) in fields.enumerated() {
            guard snapshots.indices.contains(index) else {
                field.stringValue = "0 Idle"
                field.toolTip = nil
                field.textColor = .tertiaryLabelColor
                continue
            }

            let snapshot = snapshots[index]
            let roomName = state.mediaWorkerRoomDisplayName(for: snapshot.roomID)
            field.stringValue = "\(snapshot.pendingCount) \(roomName)"
            field.toolTip = [
                snapshot.label,
                snapshot.statusText,
                roomName,
                snapshot.itemID
            ]
            .compactMap { value in
                guard let value, !value.isEmpty else { return nil }
                return value
            }
            .joined(separator: " • ")
            field.textColor = snapshot.roomID == nil ? .tertiaryLabelColor : .secondaryLabelColor
        }
    }
}
