import AppKit
import MatrixCore

@MainActor
protocol ComposerBarHosting: AnyObject {
    func composerDraftDidChange()
    func composerDidRequestSend()
    func composerDidRequestAttach()
    func composerDidReceiveDroppedFiles(_ urls: [URL])
    func composerDidRequestJoin()
    func composerDidRemovePendingAttachment(at index: Int)
}

final class ComposerTextView: NSTextView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var acceptsFirstResponder: Bool { isEditable }

    override func mouseDown(with event: NSEvent) {
        if isEditable {
            window?.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEditable || isSelectable else { return nil }
        return super.hitTest(point)
    }
}

final class ComposerFieldContainer: NSView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point), let textView = embeddedTextView(), textView.isEditable else {
            return super.hitTest(point)
        }
        return textView
    }

    override func mouseDown(with event: NSEvent) {
        if let textView = embeddedTextView(), textView.isEditable {
            window?.makeFirstResponder(textView)
        }
        super.mouseDown(with: event)
    }

    private func embeddedTextView() -> NSTextView? {
        var stack: [NSView] = subviews
        while let view = stack.popLast() {
            if let textView = view as? NSTextView {
                return textView
            }
            stack.append(contentsOf: view.subviews)
        }
        return nil
    }
}

final class ComposerAttachmentChipView: NSView {
    var onRemove: (() -> Void)?

    private let iconView = NSImageView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    private let removeButton = NSButton(title: "", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 11, weight: .medium)
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false

        removeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: "Remove attachment")
        removeButton.imagePosition = .imageOnly
        removeButton.isBordered = false
        removeButton.target = self
        removeButton.action = #selector(removeTapped)
        removeButton.setAccessibilityLabel("Remove attachment")
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        addSubview(iconView)
        addSubview(titleField)
        addSubview(removeButton)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 4),
            removeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            removeButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 16),
            removeButton.heightAnchor.constraint(equalToConstant: 16)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(attachment: OutgoingMediaAttachment) {
        titleField.stringValue = attachment.filename
        toolTip = attachment.filename
        let symbolName: String
        switch attachment.kind {
        case .image:
            symbolName = "photo"
        case .video:
            symbolName = "film"
        case .audio:
            symbolName = "waveform"
        case .file:
            symbolName = "doc"
        }
        iconView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        iconView.contentTintColor = .secondaryLabelColor
    }

    @objc
    private func removeTapped() {
        onRemove?()
    }
}

final class ComposerBarView: NSView, NSTextViewDelegate {
    weak var host: ComposerBarHosting?

    let textView = ComposerTextView(frame: NSRect(x: 0, y: 0, width: 420, height: 36))
    private let fieldContainer = ComposerFieldContainer()
    private let composerScrollView = NSScrollView(frame: .zero)
    private let attachButton = NSButton(title: "", target: nil, action: nil)
    private let sendButton = NSButton(title: "Send", target: nil, action: nil)
    private let joinButton = NSButton(title: "Join Room", target: nil, action: nil)
    private let membershipField = NSTextField(wrappingLabelWithString: "")
    private let noticeField = NSTextField(wrappingLabelWithString: "")
    private let pendingStack = NSStackView()
    private let membershipRow = NSStackView()
    private var composerHeightConstraint: NSLayoutConstraint?
    private var isComposerEnabled = false

    var draft: String {
        get { textView.string }
        set { textView.string = newValue }
    }

    var composerMinHeight: CGFloat { 36 }
    var composerMaxHeight: CGFloat { 140 }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        registerForDraggedTypes([.fileURL])

        membershipField.font = .systemFont(ofSize: 12)
        membershipField.textColor = .secondaryLabelColor
        membershipField.maximumNumberOfLines = 2

        noticeField.font = .systemFont(ofSize: 12)
        noticeField.textColor = .systemRed
        noticeField.maximumNumberOfLines = 2
        noticeField.isHidden = true

        joinButton.bezelStyle = .rounded
        joinButton.target = self
        joinButton.action = #selector(joinTapped)
        joinButton.setAccessibilityLabel("Join room")

        membershipRow.orientation = .horizontal
        membershipRow.alignment = .centerY
        membershipRow.spacing = 10
        membershipRow.addArrangedSubview(membershipField)
        membershipRow.addArrangedSubview(joinButton)
        membershipRow.isHidden = true

        pendingStack.orientation = .horizontal
        pendingStack.alignment = .centerY
        pendingStack.spacing = 8
        pendingStack.isHidden = true

        configureTextView()
        configureButtons()

        composerScrollView.documentView = textView
        composerScrollView.hasVerticalScroller = false
        composerScrollView.autohidesScrollers = true
        composerScrollView.borderType = .noBorder
        composerScrollView.drawsBackground = false
        composerScrollView.focusRingType = .none
        composerScrollView.translatesAutoresizingMaskIntoConstraints = false

        fieldContainer.addSubview(composerScrollView)
        NSLayoutConstraint.activate([
            composerScrollView.leadingAnchor.constraint(equalTo: fieldContainer.leadingAnchor, constant: 8),
            composerScrollView.trailingAnchor.constraint(equalTo: fieldContainer.trailingAnchor, constant: -8),
            composerScrollView.topAnchor.constraint(equalTo: fieldContainer.topAnchor, constant: 2),
            composerScrollView.bottomAnchor.constraint(equalTo: fieldContainer.bottomAnchor, constant: -2)
        ])

        let inputRow = NSStackView(views: [attachButton, fieldContainer, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .bottom
        inputRow.spacing = 8
        inputRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [membershipRow, noticeField, pendingStack, inputRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        composerHeightConstraint = fieldContainer.heightAnchor.constraint(equalToConstant: composerMinHeight + 4)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            inputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            membershipRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            noticeField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            composerHeightConstraint!,
            attachButton.widthAnchor.constraint(equalToConstant: 32),
            attachButton.heightAnchor.constraint(equalToConstant: 32),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 72)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        syncTextViewWidth()
        updateComposerHeight()
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isComposerEnabled else { return [] }
        return canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isComposerEnabled else { return false }
        guard let urls = fileURLs(from: sender), !urls.isEmpty else { return false }
        host?.composerDidReceiveDroppedFiles(urls)
        return true
    }

    func configure(
        summary: RoomSummary?,
        notice: String?,
        pendingAttachments: [OutgoingMediaAttachment]
    ) {
        let isJoined = summary?.membership == .joined
        isComposerEnabled = isJoined
        textView.isEditable = isJoined
        textView.isSelectable = true
        attachButton.isEnabled = isJoined
        sendButton.isEnabled = isJoined
        fieldContainer.alphaValue = isJoined ? 1 : 0.55
        attachButton.alphaValue = isJoined ? 1 : 0.55
        sendButton.alphaValue = isJoined ? 1 : 0.55

        if isJoined {
            membershipRow.isHidden = true
            textView.toolTip = nil
            attachButton.toolTip = "Attach file"
        } else if let summary {
            membershipRow.isHidden = false
            switch summary.membership {
            case .invited:
                membershipField.stringValue = "You’ve been invited to \(summary.displayName)."
                joinButton.title = "Accept Invite"
                joinButton.isHidden = !summary.canJoin
            case .notJoined:
                membershipField.stringValue = "Join \(summary.displayName) to send messages."
                joinButton.title = "Join Room"
                joinButton.isHidden = !summary.canJoin
            case .left:
                membershipField.stringValue = "You left this room."
                joinButton.isHidden = true
            case .joined:
                membershipRow.isHidden = true
            }
            textView.toolTip = "Join this room before sending messages."
            attachButton.toolTip = "Join this room before attaching files."
        } else {
            membershipRow.isHidden = false
            membershipField.stringValue = "Select a room to start chatting."
            joinButton.isHidden = true
            textView.toolTip = nil
            attachButton.toolTip = "Attach file"
        }

        if let notice, !notice.isEmpty {
            noticeField.isHidden = false
            noticeField.stringValue = notice
        } else {
            noticeField.isHidden = true
            noticeField.stringValue = ""
        }

        configurePending(pendingAttachments)
        if !isJoined && !textView.string.isEmpty {
            textView.string = ""
        }
        updateComposerHeight()
        updateSendKeyEquivalent()
    }

    @discardableResult
    func makeComposerFirstResponder() -> Bool {
        guard isComposerEnabled, let window = window, window.isKeyWindow else { return false }
        syncTextViewWidth()
        return window.makeFirstResponder(textView)
    }

    func updateComposerHeight() {
        guard let textContainer = textView.textContainer,
              let layoutManager = textView.layoutManager else {
            return
        }

        let contentWidth = max(composerScrollView.contentSize.width, 0)
        textContainer.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let textHeight = layoutManager.usedRect(for: textContainer).height
        let targetHeight = max(
            composerMinHeight,
            min(
                composerMaxHeight,
                ceil(textHeight + (textView.textContainerInset.height * 2) + 2)
            )
        )
        let fieldHeight = targetHeight + 4
        if composerHeightConstraint?.constant != fieldHeight {
            composerHeightConstraint?.constant = fieldHeight
        }
        composerScrollView.hasVerticalScroller = targetHeight >= composerMaxHeight
        syncTextViewWidth()
    }

    func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === textView else { return }
        updateComposerHeight()
        host?.composerDraftDidChange()
    }

    func textDidBeginEditing(_ notification: Notification) {
        guard notification.object as AnyObject? === textView else { return }
        updateSendKeyEquivalent()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as AnyObject? === textView else { return }
        sendButton.keyEquivalent = ""
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === self.textView else { return false }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) ||
              commandSelector == #selector(NSResponder.insertLineBreak(_:)) else {
            return false
        }

        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option, .control, .command]) ?? []
        guard modifiers.isEmpty else { return false }

        host?.composerDidRequestSend()
        return true
    }

    private func configureTextView() {
        textView.font = .systemFont(ofSize: 14)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFindPanel = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: composerMinHeight)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 4
        textView.textContainerInset = NSSize(width: 2, height: 8)
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.delegate = self
        textView.setAccessibilityLabel("Message")
        textView.setAccessibilityRole(.textArea)
    }

    private func configureButtons() {
        attachButton.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Attach file")
        attachButton.imagePosition = .imageOnly
        attachButton.bezelStyle = .regularSquare
        attachButton.isBordered = false
        attachButton.target = self
        attachButton.action = #selector(attachTapped)
        attachButton.toolTip = "Attach file"
        attachButton.setAccessibilityLabel("Attach file")
        attachButton.setAccessibilityRole(.button)

        sendButton.bezelStyle = .rounded
        sendButton.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        sendButton.imagePosition = .imageLeading
        sendButton.target = self
        sendButton.action = #selector(sendTapped)
        sendButton.setAccessibilityLabel("Send")
        sendButton.setAccessibilityRole(.button)
    }

    private func configurePending(_ attachments: [OutgoingMediaAttachment]) {
        for view in pendingStack.arrangedSubviews {
            pendingStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        pendingStack.isHidden = attachments.isEmpty
        for (index, attachment) in attachments.enumerated() {
            let chip = ComposerAttachmentChipView()
            chip.configure(attachment: attachment)
            chip.onRemove = { [weak self] in
                self?.host?.composerDidRemovePendingAttachment(at: index)
            }
            pendingStack.addArrangedSubview(chip)
        }
    }

    private func syncTextViewWidth() {
        let width = max(composerScrollView.contentSize.width, fieldContainer.bounds.width - 16, 1)
        var frame = textView.frame
        frame.size.width = width
        if frame.size.height < composerMinHeight {
            frame.size.height = composerMinHeight
        }
        textView.minSize = NSSize(width: width, height: composerMinHeight)
        textView.frame = frame
        textView.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
    }

    private func updateSendKeyEquivalent() {
        let composerIsFirst = window?.firstResponder === textView
        sendButton.keyEquivalent = (isComposerEnabled && composerIsFirst) ? "\r" : ""
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }

    @objc
    private func attachTapped() {
        host?.composerDidRequestAttach()
    }

    @objc
    private func sendTapped() {
        host?.composerDidRequestSend()
    }

    @objc
    private func joinTapped() {
        host?.composerDidRequestJoin()
    }
}

final class FileDropView: NSView {
    var isDropEnabled = false
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isDropEnabled else { return [] }
        return canAccept(sender) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isDropEnabled, let urls = fileURLs(from: sender), !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }

    private func canAccept(_ sender: NSDraggingInfo) -> Bool {
        sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        )
    }

    private func fileURLs(from sender: NSDraggingInfo) -> [URL]? {
        sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [URL]
    }
}

final class FileDropScrollView: NSScrollView {
    var isDropEnabled = false
    var onDrop: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard isDropEnabled else { return [] }
        return sender.draggingPasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard isDropEnabled else { return false }
        guard let urls = sender.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty else {
            return false
        }
        onDrop?(urls)
        return true
    }
}

