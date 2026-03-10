import AppKit
import MatrixCore

final class InspectorViewController: NSViewController {
    private let state: WorkspaceStateController
    private let roomSectionField = NSTextField(labelWithString: "Room")
    private let titleField = NSTextField(labelWithString: "")
    private let topicField = NSTextField(wrappingLabelWithString: "")
    private let membersField = NSTextField(labelWithString: "")
    private let pinnedField = NSTextField(wrappingLabelWithString: "")
    private let downloadsSectionField = NSTextField(labelWithString: "Downloads")
    private let thumbSectionField = NSTextField(labelWithString: "Thumb")
    private let originalSectionField = NSTextField(labelWithString: "Orig")
    private let thumbWorkerFields = (0..<2).map { _ in NSTextField(labelWithString: "") }
    private let originalWorkerFields = (0..<3).map { _ in NSTextField(labelWithString: "") }

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
        pinnedField.maximumNumberOfLines = 0
        pinnedField.textColor = .secondaryLabelColor

        downloadsSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        downloadsSectionField.textColor = .secondaryLabelColor
        thumbSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        thumbSectionField.textColor = .secondaryLabelColor
        originalSectionField.font = .systemFont(ofSize: 11, weight: .semibold)
        originalSectionField.textColor = .secondaryLabelColor

        let workerFont = NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular)
        for field in thumbWorkerFields + originalWorkerFields {
            field.font = workerFont
            field.textColor = .secondaryLabelColor
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.usesSingleLineMode = true
        }

        let separator = NSBox()
        separator.boxType = .separator

        let stack = NSStackView(views: [
            roomSectionField,
            titleField,
            topicField,
            membersField,
            pinnedField,
            separator,
            downloadsSectionField,
            thumbSectionField
        ] + thumbWorkerFields + [
            originalSectionField
        ] + originalWorkerFields)
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16)
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
            pinnedField.stringValue = details.pinnedMessages.isEmpty
                ? "No pinned messages."
                : "Pinned:\n" + details.pinnedMessages.joined(separator: "\n")
        } else {
            titleField.stringValue = "Room Details"
            topicField.stringValue = "Select a room to inspect details, encryption state, and pinned items."
            membersField.stringValue = ""
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
