import AppKit
import Foundation
import ImageIO
import MatrixCore
import MediaKit

@MainActor
public protocol TimelineWorkspaceState: AnyObject {
    var timelineItems: [TimelineItem] { get }
    var selectedRoomSummary: RoomSummary? { get }
    var composerNotice: String? { get }
    func addTimelineObserver(_ observer: @escaping @MainActor () -> Void)
    func addMediaObserver(_ observer: @escaping @MainActor () -> Void)
    func addSelectionObserver(_ observer: @escaping @MainActor () -> Void)
    func addComposerNoticeObserver(_ observer: @escaping @MainActor () -> Void)
    func addRoomListObserver(_ observer: @escaping @MainActor () -> Void)
    func mediaState(for itemID: String) -> TimelineMediaLoadState?
    func prepareMedia(for item: TimelineItem, prefetchOriginal: Bool)
    func resolveOriginalMediaURL(for item: TimelineItem) async -> URL?
    func resolveReceiptAvatarFileURL(for receipt: ReadReceipt) async -> URL?
    func markSelectedRoomAsRead()
    func sendMessage(_ body: String)
    func sendMedia(_ attachment: OutgoingMediaAttachment)
    func joinSelectedRoom()
    func presentComposerNotice(_ message: String?)
}

final class ReceiptAvatarBadgeView: NSView {
    private let imageView = NSImageView(frame: .zero)
    private let label = NSTextField(labelWithString: "")
    private var loadTask: Task<Void, Never>?
    private var representedAvatarKey: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        imageView.imageScaling = .scaleAxesIndependently
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)

        label.font = .systemFont(ofSize: 9, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 18),
            heightAnchor.constraint(equalToConstant: 18),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        loadTask?.cancel()
    }

    func configureFallback(text: String, backgroundColor: NSColor, toolTip: String?) {
        loadTask?.cancel()
        representedAvatarKey = nil
        label.stringValue = text
        label.isHidden = false
        imageView.image = nil
        layer?.backgroundColor = backgroundColor.cgColor
        self.toolTip = toolTip
    }

    func configure(
        receipt: ReadReceipt,
        avatarResolver: ((ReadReceipt) async -> URL?)? = nil
    ) {
        let tooltip: String
        if let readAt = receipt.readAt {
            tooltip = "\(receipt.displayName) read at \(readAt.formatted(date: .omitted, time: .shortened))"
        } else {
            tooltip = "\(receipt.displayName) read"
        }
        configureFallback(
            text: initials(for: receipt.displayName, fallback: receipt.userID),
            backgroundColor: color(for: receipt.userID),
            toolTip: tooltip
        )

        guard let avatarURL = receipt.avatarURL,
              let avatarResolver else {
            return
        }

        let avatarKey = "\(receipt.userID)|\(avatarURL)"
        representedAvatarKey = avatarKey
        loadTask?.cancel()
        loadTask = Task { [weak self] in
            guard let self else { return }
            guard let fileURL = await avatarResolver(receipt) else { return }
            let image = await Self.avatarImage(for: fileURL)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.representedAvatarKey == avatarKey, let image else { return }
                self.imageView.image = image
                self.label.isHidden = true
                self.layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }

    private static func avatarImage(for url: URL) async -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 36
              ] as CFDictionary) else {
            return NSImage(contentsOf: url)
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: 18, height: 18))
    }

    private func initials(for displayName: String, fallback: String) -> String {
        let source = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = (source.isEmpty ? fallback : source)
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(2)
        let initials = words.compactMap { $0.first }.map(String.init).joined()
        return initials.isEmpty ? String(fallback.prefix(1)).uppercased() : initials.uppercased()
    }

    private func color(for seed: String) -> NSColor {
        let palette: [NSColor] = [
            .systemBlue,
            .systemGreen,
            .systemOrange,
            .systemPink,
            .systemRed,
            .systemTeal
        ]
        let hash = seed.unicodeScalars.reduce(0) { partialResult, scalar in
            partialResult &+ Int(scalar.value)
        }
        return palette[hash % palette.count]
    }
}

final class ReadReceiptStripView: NSView {
    private enum Layout {
        static let badgeSize: CGFloat = 18
        static let normalSpacing: CGFloat = 4
        static let overlappedSpacing: CGFloat = -6
        static let maxSeparateBadges = 10
        static let defaultMaxVisible = 20
    }

    private let stackView = NSStackView()
    private var visibleBadgeCount = 0
    private var currentSpacing: CGFloat = Layout.normalSpacing

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = Layout.normalSpacing
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        stackView.setContentHuggingPriority(.required, for: .horizontal)
        stackView.setContentCompressionResistancePriority(.required, for: .horizontal)

        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        guard visibleBadgeCount > 0 else {
            return NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }

        let width = (Layout.badgeSize * CGFloat(visibleBadgeCount)) +
            (currentSpacing * CGFloat(max(0, visibleBadgeCount - 1)))
        return NSSize(
            width: ceil(max(Layout.badgeSize, width)),
            height: Layout.badgeSize
        )
    }

    func configure(
        receipts: [ReadReceipt],
        maxVisible: Int = Layout.defaultMaxVisible,
        avatarResolver: ((ReadReceipt) async -> URL?)? = nil
    ) {
        for subview in stackView.arrangedSubviews {
            stackView.removeArrangedSubview(subview)
            subview.removeFromSuperview()
        }

        let visibleReceipts = Array(receipts.suffix(maxVisible))
        let hiddenCount = max(0, receipts.count - visibleReceipts.count)
        let totalBadgeCount = visibleReceipts.count + (hiddenCount > 0 ? 1 : 0)
        currentSpacing = totalBadgeCount > Layout.maxSeparateBadges
            ? Layout.overlappedSpacing
            : Layout.normalSpacing
        stackView.spacing = currentSpacing

        for receipt in visibleReceipts {
            let badge = ReceiptAvatarBadgeView()
            badge.configure(receipt: receipt, avatarResolver: avatarResolver)
            badge.setContentHuggingPriority(.required, for: .horizontal)
            badge.setContentCompressionResistancePriority(.required, for: .horizontal)
            stackView.addArrangedSubview(badge)
        }

        if hiddenCount > 0 {
            let overflowBadge = ReceiptAvatarBadgeView()
            overflowBadge.configureFallback(
                text: "+\(hiddenCount)",
                backgroundColor: .tertiaryLabelColor,
                toolTip: "\(hiddenCount) more readers"
            )
            overflowBadge.setContentHuggingPriority(.required, for: .horizontal)
            overflowBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
            stackView.addArrangedSubview(overflowBadge)
        }

        visibleBadgeCount = totalBadgeCount
        invalidateIntrinsicContentSize()
        isHidden = receipts.isEmpty
    }
}

final class TimelineMessageCellView: NSTableCellView {
    private let senderField = NSTextField(labelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let receiptStripView = ReadReceiptStripView()
    private let bubbleView = NSView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        senderField.font = .systemFont(ofSize: 12, weight: .semibold)
        bodyField.font = .systemFont(ofSize: 13)
        bodyField.maximumNumberOfLines = 0
        metaField.font = .systemFont(ofSize: 11)
        metaField.textColor = .secondaryLabelColor

        bubbleView.wantsLayer = true
        bubbleView.layer?.cornerRadius = 12
        bubbleView.translatesAutoresizingMaskIntoConstraints = false

        let metaRow = NSStackView(views: [metaField, NSView(), receiptStripView])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [senderField, bodyField, metaRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubbleView)
        addSubview(stack)

        NSLayoutConstraint.activate([
            bubbleView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            bubbleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            bubbleView.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            bubbleView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
            stack.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            metaRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(
        item: TimelineItem,
        avatarResolver: ((ReadReceipt) async -> URL?)? = nil
    ) {
        senderField.stringValue = item.senderDisplayName
        bodyField.stringValue = item.body
        metaField.stringValue = TimelineCellFormatting.metaText(for: item)
        receiptStripView.configure(
            receipts: item.isOwnMessage ? item.receipts.readReceipts : [],
            avatarResolver: avatarResolver
        )
        bubbleView.layer?.backgroundColor = (item.isOwnMessage
            ? NSColor.controlAccentColor.withAlphaComponent(0.12)
            : NSColor.separatorColor.withAlphaComponent(0.18)).cgColor
    }
}

final class TimelineStatusCellView: NSTableCellView {
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let metaField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        bodyField.font = .systemFont(ofSize: 12)
        bodyField.textColor = .secondaryLabelColor
        bodyField.maximumNumberOfLines = 0
        bodyField.alignment = .center
        metaField.font = .systemFont(ofSize: 11)
        metaField.textColor = .tertiaryLabelColor
        metaField.alignment = .center

        let stack = NSStackView(views: [bodyField, metaField])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -36),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(item: TimelineItem) {
        bodyField.stringValue = item.body
        metaField.stringValue = item.timestamp.formatted(date: .omitted, time: .shortened)
    }
}

final class TimelineMediaCellView: NSTableCellView {
    private enum Layout {
        static let imagePreviewHeight: CGFloat = 168
        static let compactPreviewHeight: CGFloat = 44
    }

    private let senderField = NSTextField(labelWithString: "")
    private let previewButton = NSButton(title: "", target: nil, action: nil)
    private let captionField = NSTextField(wrappingLabelWithString: "")
    private let metaField = NSTextField(labelWithString: "")
    private let receiptStripView = ReadReceiptStripView()
    private let progressIndicator = NSProgressIndicator(frame: .zero)
    private let progressField = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "View Original", target: nil, action: nil)

    private var representedItemID: String?
    private var previewSourceURL: URL?
    private var hasResolvedPreviewImage = false
    private var previewTask: Task<Void, Never>?
    private var previewHeightConstraint: NSLayoutConstraint?
    var onOpenRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        senderField.font = .systemFont(ofSize: 12, weight: .semibold)
        captionField.font = .systemFont(ofSize: 13)
        captionField.maximumNumberOfLines = 0
        metaField.font = .systemFont(ofSize: 11)
        metaField.textColor = .secondaryLabelColor
        progressField.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        progressField.textColor = .secondaryLabelColor

        previewButton.bezelStyle = .shadowlessSquare
        previewButton.isBordered = false
        previewButton.imagePosition = .imageOnly
        previewButton.imageScaling = .scaleProportionallyUpOrDown
        previewButton.wantsLayer = true
        previewButton.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.12).cgColor
        previewButton.layer?.cornerRadius = 10
        previewButton.layer?.borderWidth = 0
        previewButton.translatesAutoresizingMaskIntoConstraints = false
        previewButton.target = self
        previewButton.action = #selector(openRequested)

        progressIndicator.isIndeterminate = false
        progressIndicator.controlSize = .small
        progressIndicator.style = .bar
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        openButton.bezelStyle = .rounded
        openButton.target = self
        openButton.action = #selector(openRequested)

        let metaRow = NSStackView(views: [metaField, NSView(), receiptStripView])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let progressStack = NSStackView(views: [progressIndicator, progressField, NSView(), openButton])
        progressStack.orientation = .horizontal
        progressStack.alignment = .centerY
        progressStack.spacing = 8

        let stack = NSStackView(views: [senderField, previewButton, captionField, metaRow, progressStack])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        previewHeightConstraint = previewButton.heightAnchor.constraint(equalToConstant: Layout.imagePreviewHeight)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
            previewHeightConstraint!,
            previewButton.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            previewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 160),
            progressIndicator.widthAnchor.constraint(equalToConstant: 140),
            metaRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        previewTask?.cancel()
    }

    func configure(
        item: TimelineItem,
        mediaState: TimelineMediaLoadState?,
        avatarResolver: ((ReadReceipt) async -> URL?)? = nil
    ) {
        let itemDidChange = representedItemID != item.id
        representedItemID = item.id
        previewTask?.cancel()
        previewTask = nil

        senderField.stringValue = item.senderDisplayName
        captionField.stringValue = TimelineCellFormatting.mediaCaption(for: item)
        metaField.stringValue = TimelineCellFormatting.metaText(for: item)
        receiptStripView.configure(
            receipts: item.isOwnMessage ? item.receipts.readReceipts : [],
            avatarResolver: avatarResolver
        )

        if itemDidChange {
            previewSourceURL = nil
            hasResolvedPreviewImage = false
            setFallbackPreview(for: item)
        }

        switch item.media?.kind {
        case .image, .video:
            let hasPreview = mediaState?.thumbnailFileURL != nil || mediaState?.originalFileURL != nil
            previewHeightConstraint?.constant = hasPreview ? Layout.imagePreviewHeight : Layout.compactPreviewHeight
            openButton.isHidden = true
            previewButton.toolTip = mediaState?.originalFileURL == nil ? "Fetch and open original" : "Open original"
        case .audio, .file, .none:
            previewHeightConstraint?.constant = Layout.compactPreviewHeight
            openButton.isHidden = false
            openButton.title = mediaState?.originalFileURL == nil ? "Fetch File" : "Open File"
            previewButton.toolTip = openButton.title
        }

        configureProgress(mediaState)
        configurePreview(item: item, mediaState: mediaState, itemDidChange: itemDidChange)
    }

    @objc
    private func openRequested() {
        onOpenRequested?()
    }

    private func configureProgress(_ mediaState: TimelineMediaLoadState?) {
        guard let mediaState else {
            progressIndicator.isHidden = true
            progressField.isHidden = true
            return
        }

        if let errorDescription = mediaState.errorDescription, !errorDescription.isEmpty {
            progressIndicator.isHidden = true
            progressField.isHidden = false
            progressField.stringValue = errorDescription
            return
        }

        let shouldShowProgress = mediaState.isLoadingOriginal || (mediaState.receivedBytes > 0 && mediaState.originalFileURL == nil)
        progressIndicator.isHidden = !shouldShowProgress
        progressField.isHidden = !shouldShowProgress
        guard shouldShowProgress else { return }

        if let totalBytes = mediaState.totalBytes, totalBytes > 0 {
            progressIndicator.stopAnimation(nil)
            progressIndicator.isIndeterminate = false
            progressIndicator.doubleValue = Double(mediaState.receivedBytes) / Double(totalBytes)
            progressField.stringValue = "\(TimelineCellFormatting.byteString(mediaState.receivedBytes)) of \(TimelineCellFormatting.byteString(totalBytes))"
        } else {
            progressIndicator.isIndeterminate = true
            progressIndicator.startAnimation(nil)
            progressField.stringValue = TimelineCellFormatting.receivedBytesText(mediaState.receivedBytes)
        }
    }

    private func configurePreview(item: TimelineItem, mediaState: TimelineMediaLoadState?, itemDidChange: Bool) {
        let previewURL = mediaState?.thumbnailFileURL ?? mediaState?.originalFileURL
        guard let previewURL else {
            if itemDidChange || previewButton.image == nil {
                setFallbackPreview(for: item)
            }
            return
        }

        if previewSourceURL == previewURL, hasResolvedPreviewImage {
            return
        }

        let itemID = item.id
        previewSourceURL = previewURL
        previewTask = Task {
            let image = await Self.previewImage(for: previewURL, maxPixelSize: 960)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.representedItemID == itemID, self.previewSourceURL == previewURL else { return }
                if let image {
                    self.previewButton.image = image
                    self.previewButton.title = ""
                    self.previewButton.imagePosition = .imageOnly
                    self.previewButton.contentTintColor = nil
                    self.hasResolvedPreviewImage = true
                    self.previewHeightConstraint?.constant = Layout.imagePreviewHeight
                } else if !self.hasResolvedPreviewImage {
                    self.setFallbackPreview(for: item)
                }
            }
        }
    }

    private func setFallbackPreview(for item: TimelineItem) {
        let fallbackImageName: String
        switch item.media?.kind {
        case .image:
            fallbackImageName = "photo"
        case .video:
            fallbackImageName = "play.rectangle"
        case .audio:
            fallbackImageName = "waveform"
        case .file, .none:
            fallbackImageName = "doc"
        }

        let fallbackImage = NSImage(systemSymbolName: fallbackImageName, accessibilityDescription: nil)
        fallbackImage?.isTemplate = true
        previewButton.image = fallbackImage
        previewButton.contentTintColor = .secondaryLabelColor
        previewButton.imagePosition = item.media?.kind == .image || item.media?.kind == .video ? .imageOnly : .imageLeading
        previewButton.title = item.media?.kind == .file || item.media?.kind == .audio
            ? TimelineCellFormatting.mediaCaption(for: item)
            : ""
        previewButton.layer?.borderWidth = 0
    }

    private static func previewImage(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        if let cgImage {
            return NSImage(cgImage: cgImage, size: .zero)
        }
        let data = await Task.detached(priority: .utility) {
            try? Data(contentsOf: url)
        }.value
        return data.flatMap { NSImage(data: $0) }
    }
}

enum TimelineCellFormatting {
    static func mediaCaption(for item: TimelineItem) -> String {
        guard let media = item.media else { return item.body }
        let trimmedBody = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            return trimmedBody
        }
        if let filename = media.filename, !filename.isEmpty {
            return filename
        }
        return media.body.isEmpty ? "Media" : media.body
    }

    static func metaText(for item: TimelineItem) -> String {
        let delivery = item.deliveryState?.label ?? "Received"
        let time = item.timestamp.formatted(date: .omitted, time: .shortened)

        var components = [time]
        if let media = item.media {
            components.append(mediaLabel(for: media.kind))
            if let width = media.width, let height = media.height {
                components.append("\(width)x\(height)")
            }
            if let duration = media.durationSeconds, duration > 0 {
                components.append(durationString(duration))
            }
        }
        components.append(delivery)
        if item.isDeleted {
            components.append("Deleted")
        }
        return components.joined(separator: "  ")
    }

    static func byteString(_ value: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        return formatter.string(fromByteCount: value)
    }

    static func receivedBytesText(_ value: Int64) -> String {
        value > 0 ? "\(byteString(value)) downloaded" : "Downloading…"
    }

    private static func mediaLabel(for kind: TimelineMediaKind) -> String {
        switch kind {
        case .image:
            return "Image"
        case .video:
            return "Video"
        case .audio:
            return "Audio"
        case .file:
            return "File"
        }
    }

    private static func durationString(_ duration: Double) -> String {
        let totalSeconds = max(0, Int(duration.rounded()))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

public final class TimelineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, ComposerBarHosting, NSMenuItemValidation {
    private enum Layout {
        static let messageBaseHeight: CGFloat = 72
        static let statusBaseHeight: CGFloat = 52
        static let imageMediaBaseHeight: CGFloat = 248
        static let compactMediaBaseHeight: CGFloat = 118
        static let mediaExtraLineHeight: CGFloat = 14
        static let messageExtraLineHeight: CGFloat = 14
        static let autoScrollThreshold: CGFloat = 36
    }

    private let state: any TimelineWorkspaceState
    private let videoPlaybackEngine: any VideoPlaybackEngine
    private let titleField = NSTextField(labelWithString: "No Room Selected")
    private let subtitleField = NSTextField(labelWithString: "")
    private let emptyField = NSTextField(wrappingLabelWithString: "")
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = FileDropScrollView(frame: .zero)
    private let composerBar = ComposerBarView()
    private var scrollObserver: NSObjectProtocol?
    private var windowObserver: NSObjectProtocol?
    private var pendingReadMarkTask: Task<Void, Never>?
    private var pendingAttachments: [OutgoingMediaAttachment] = []
    private var didFocusComposerForCurrentRoom = false

    private var previewControllers: [MediaPreviewWindowController] = []

    public init(state: any TimelineWorkspaceState, videoPlaybackEngine: any VideoPlaybackEngine) {
        self.state = state
        self.videoPlaybackEngine = videoPlaybackEngine
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        let root = FileDropView()
        root.translatesAutoresizingMaskIntoConstraints = false
        root.onDrop = { [weak self] urls in
            self?.enqueueAttachments(from: urls)
        }

        titleField.font = .systemFont(ofSize: 18, weight: .semibold)
        subtitleField.font = .systemFont(ofSize: 12)
        subtitleField.textColor = .secondaryLabelColor
        emptyField.font = .systemFont(ofSize: 13)
        emptyField.textColor = .secondaryLabelColor
        emptyField.alignment = .center
        emptyField.maximumNumberOfLines = 0
        emptyField.isHidden = true

        let headerStack = NSStackView(views: [titleField, subtitleField])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 2

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 4)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .none
        tableView.backgroundColor = .textBackgroundColor
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.refusesFirstResponder = true

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.onDrop = { [weak self] urls in
            self?.enqueueAttachments(from: urls)
        }

        composerBar.host = self

        let stack = NSStackView(views: [headerStack, scrollView, emptyField, composerBar])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            headerStack.widthAnchor.constraint(equalTo: stack.widthAnchor),
            composerBar.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        view = root
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleTimelineScroll()
            }
        }
        windowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                guard let self, notification.object as AnyObject? === self.view.window else { return }
                self.focusComposerIfNeeded(force: false)
            }
        }
        state.addTimelineObserver { [weak self] in
            self?.reloadTimeline()
        }
        state.addMediaObserver { [weak self] in
            self?.refreshVisibleMediaRows()
        }
        state.addSelectionObserver { [weak self] in
            self?.reloadSelection()
        }
        state.addRoomListObserver { [weak self] in
            self?.reloadSelection()
        }
        state.addComposerNoticeObserver { [weak self] in
            self?.reloadComposer()
        }
        reloadSelection()
        reloadTimeline()
        composerBar.updateComposerHeight()
    }

    public override func viewDidAppear() {
        super.viewDidAppear()
        reloadComposer()
        focusComposerIfNeeded(force: true)
    }

    public override var acceptsFirstResponder: Bool { true }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if let windowObserver {
            NotificationCenter.default.removeObserver(windowObserver)
            self.windowObserver = nil
        }
        pendingReadMarkTask?.cancel()
        pendingReadMarkTask = nil
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        composerBar.updateComposerHeight()
    }

    public func numberOfRows(in tableView: NSTableView) -> Int {
        state.timelineItems.count
    }

    public func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        let item = state.timelineItems[row]
        switch item.kind {
        case .statusSummary:
            let extraLines = max(0, CGFloat(item.body.count / 90))
            return Layout.statusBaseHeight + (extraLines * Layout.messageExtraLineHeight)
        case .message:
            if let media = item.media {
                let extraLines = max(0, CGFloat(item.body.count / 72))
                let mediaState = state.mediaState(for: item.id)
                let hasPreview = mediaState?.thumbnailFileURL != nil || mediaState?.originalFileURL != nil
                let base: CGFloat
                switch media.kind {
                case .image, .video:
                    base = hasPreview ? Layout.imageMediaBaseHeight : Layout.compactMediaBaseHeight
                case .audio, .file:
                    base = Layout.compactMediaBaseHeight
                }
                return base + (extraLines * Layout.mediaExtraLineHeight)
            }
            let extraLines = max(0, CGFloat(item.body.count / 72))
            return Layout.messageBaseHeight + (extraLines * Layout.messageExtraLineHeight)
        }
    }

    public func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = state.timelineItems[row]
        if item.kind == .statusSummary {
            let identifier = NSUserInterfaceItemIdentifier("TimelineStatusCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TimelineStatusCellView) ?? {
                let newCell = TimelineStatusCellView()
                newCell.identifier = identifier
                return newCell
            }()
            cell.configure(item: item)
            return cell
        }

        if item.media != nil {
            let identifier = NSUserInterfaceItemIdentifier("TimelineMediaCell")
            let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TimelineMediaCellView) ?? {
                let newCell = TimelineMediaCellView()
                newCell.identifier = identifier
                return newCell
            }()
            cell.configure(
                item: item,
                mediaState: state.mediaState(for: item.id),
                avatarResolver: resolveReceiptAvatarFileURL
            )
            cell.onOpenRequested = { [weak self] in
                self?.openMedia(for: item)
            }
            return cell
        }

        let identifier = NSUserInterfaceItemIdentifier("TimelineMessageCell")
        let cell = (tableView.makeView(withIdentifier: identifier, owner: self) as? TimelineMessageCellView) ?? {
            let newCell = TimelineMessageCellView()
            newCell.identifier = identifier
            return newCell
        }()
        cell.configure(item: item, avatarResolver: resolveReceiptAvatarFileURL)
        return cell
    }

    @objc
    func attachFile(_ sender: Any?) {
        composerDidRequestAttach()
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(attachFile(_:)) {
            return state.selectedRoomSummary?.membership == .joined
        }
        return true
    }

    func composerDraftDidChange() {}

    func composerDidRequestSend() {
        sendCurrentDraft()
    }

    func composerDidRequestAttach() {
        guard state.selectedRoomSummary?.membership == .joined else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Attach"
        panel.message = "Choose files to send to this room."
        let present: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor [weak self] in
                self?.enqueueAttachments(from: panel.urls)
            }
        }
        if let window = view.window {
            panel.beginSheetModal(for: window, completionHandler: present)
        } else {
            panel.begin(completionHandler: present)
        }
    }

    func composerDidReceiveDroppedFiles(_ urls: [URL]) {
        enqueueAttachments(from: urls)
    }

    func composerDidRequestJoin() {
        state.joinSelectedRoom()
    }

    func composerDidRemovePendingAttachment(at index: Int) {
        guard pendingAttachments.indices.contains(index) else { return }
        pendingAttachments.remove(at: index)
        reloadComposer()
        focusComposerIfNeeded(force: true)
    }

    @objc
    private func sendCurrentDraft() {
        guard state.selectedRoomSummary?.membership == .joined else { return }
        let body = composerBar.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !body.isEmpty || !attachments.isEmpty else { return }

        if !attachments.isEmpty {
            let caption = body.isEmpty ? nil : body
            for (index, attachment) in attachments.enumerated() {
                state.sendMedia(attachment.withCaption(index == 0 ? caption : nil))
            }
            pendingAttachments = []
            composerBar.draft = ""
        } else {
            state.sendMessage(body)
            composerBar.draft = ""
        }
        reloadComposer()
        focusComposerIfNeeded(force: true)
    }

    private func reloadSelection() {
        let previousRoomID = titleField.toolTip
        if let summary = state.selectedRoomSummary {
            titleField.stringValue = summary.displayName
            switch summary.membership {
            case .notJoined:
                subtitleField.stringValue = summary.topic.isEmpty ? "Not joined" : "Not joined  •  \(summary.topic)"
            case .invited:
                subtitleField.stringValue = summary.topic.isEmpty ? "Invited" : "Invited  •  \(summary.topic)"
            case .left:
                subtitleField.stringValue = "You left this room"
            case .joined:
                subtitleField.stringValue = summary.topic
            }
            titleField.toolTip = summary.roomID.rawValue
            if previousRoomID != summary.roomID.rawValue {
                didFocusComposerForCurrentRoom = false
                pendingAttachments = []
            }
        } else {
            titleField.stringValue = "No Room Selected"
            subtitleField.stringValue = ""
            titleField.toolTip = nil
            didFocusComposerForCurrentRoom = false
            pendingAttachments = []
        }
        subtitleField.isHidden = subtitleField.stringValue.isEmpty
        if let root = view as? FileDropView {
            root.isDropEnabled = state.selectedRoomSummary?.membership == .joined
        }
        scrollView.isDropEnabled = state.selectedRoomSummary?.membership == .joined
        reloadComposer()
        updateEmptyState()
        focusComposerIfNeeded(force: !didFocusComposerForCurrentRoom)
    }

    private func reloadComposer() {
        composerBar.configure(
            summary: state.selectedRoomSummary,
            notice: state.composerNotice,
            pendingAttachments: pendingAttachments
        )
    }

    private func reloadTimeline() {
        let clipView = scrollView.contentView
        let previousVisibleRect = clipView.documentVisibleRect
        let previousOffset = clipView.bounds.origin.y
        let wasAtBottom = previousVisibleRect.maxY >= max(tableView.bounds.height - Layout.autoScrollThreshold, 0)
        let composerWasFirst = view.window?.firstResponder === composerBar.textView

        tableView.reloadData()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<state.timelineItems.count))
        tableView.layoutSubtreeIfNeeded()
        updateEmptyState()

        if wasAtBottom {
            scrollToBottom()
            scheduleMarkSelectedRoomAsRead()
        } else {
            let maxOffset = max(0, tableView.bounds.height - clipView.bounds.height)
            clipView.scroll(to: NSPoint(x: 0, y: min(previousOffset, maxOffset)))
            scrollView.reflectScrolledClipView(clipView)
        }

        if composerWasFirst {
            focusComposerIfNeeded(force: true)
        }
    }

    private func refreshVisibleMediaRows() {
        guard !state.timelineItems.isEmpty else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let rows = tableView.rows(in: visibleRect)
        guard rows.location != NSNotFound, rows.length > 0 else { return }

        var heightsNeedUpdate = IndexSet()
        for row in rows.location..<(rows.location + rows.length) where tableView.numberOfRows > row {
            let item = state.timelineItems[row]
            guard item.media != nil else { continue }
            heightsNeedUpdate.insert(row)
            guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? TimelineMediaCellView else {
                continue
            }
            cell.configure(
                item: item,
                mediaState: state.mediaState(for: item.id),
                avatarResolver: resolveReceiptAvatarFileURL
            )
            cell.onOpenRequested = { [weak self] in
                self?.openMedia(for: item)
            }
        }
        if !heightsNeedUpdate.isEmpty {
            tableView.noteHeightOfRows(withIndexesChanged: heightsNeedUpdate)
        }
    }

    private func scrollToBottom() {
        guard state.timelineItems.count > 0 else { return }
        tableView.scrollRowToVisible(state.timelineItems.count - 1)
    }

    private func handleTimelineScroll() {
        guard isScrolledToBottom() else { return }
        scheduleMarkSelectedRoomAsRead()
    }

    private func isScrolledToBottom() -> Bool {
        let visibleRect = scrollView.contentView.documentVisibleRect
        return visibleRect.maxY >= max(tableView.bounds.height - Layout.autoScrollThreshold, 0)
    }

    private func scheduleMarkSelectedRoomAsRead() {
        guard !state.timelineItems.isEmpty else { return }
        pendingReadMarkTask?.cancel()
        pendingReadMarkTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !Task.isCancelled else { return }
            await MainActor.run {
                self.state.markSelectedRoomAsRead()
            }
        }
    }

    private func updateEmptyState() {
        if state.selectedRoomSummary == nil {
            emptyField.stringValue = "Select a room to read and send messages."
            emptyField.isHidden = false
        } else if state.timelineItems.isEmpty {
            emptyField.stringValue = "No messages yet."
            emptyField.isHidden = false
        } else {
            emptyField.isHidden = true
            emptyField.stringValue = ""
        }
    }

    private func focusComposerIfNeeded(force: Bool) {
        guard state.selectedRoomSummary?.membership == .joined else { return }
        guard view.window?.isKeyWindow == true else { return }
        let alreadyFocused = view.window?.firstResponder === composerBar.textView
        if alreadyFocused {
            didFocusComposerForCurrentRoom = true
            return
        }
        guard force || !didFocusComposerForCurrentRoom else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.composerBar.makeComposerFirstResponder() {
                self.didFocusComposerForCurrentRoom = true
            }
        }
    }

    private func enqueueAttachments(from urls: [URL]) {
        guard state.selectedRoomSummary?.membership == .joined else { return }
        do {
            let attachments = try ComposerMediaFactory.attachments(from: urls, caption: nil)
            pendingAttachments.append(contentsOf: attachments)
            reloadComposer()
            focusComposerIfNeeded(force: true)
        } catch {
            state.presentComposerNotice(error.localizedDescription)
        }
    }

    private func openMedia(for item: TimelineItem) {
        let currentState = state.mediaState(for: item.id)
        if let url = currentState?.originalFileURL {
            presentMedia(for: item, url: url)
            return
        }

        state.prepareMedia(for: item, prefetchOriginal: true)
        Task { [weak self] in
            guard let self else { return }
            guard let url = await self.state.resolveOriginalMediaURL(for: item) else { return }
            await MainActor.run {
                self.presentMedia(for: item, url: url)
            }
        }
    }

    private func resolveReceiptAvatarFileURL(for receipt: ReadReceipt) async -> URL? {
        await state.resolveReceiptAvatarFileURL(for: receipt)
    }

    private func presentMedia(for item: TimelineItem, url: URL) {
        guard let media = item.media else { return }

        switch media.kind {
        case .image, .video:
            let controller = MediaPreviewWindowController(
                item: item,
                url: url,
                preferredScreen: view.window?.screen,
                videoPlaybackEngine: videoPlaybackEngine
            )
            controller.onClose = { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.previewControllers.removeAll { $0 === controller }
            }
            previewControllers.append(controller)
            controller.showAndFocusWindow()
        case .audio, .file:
            NSWorkspace.shared.open(url)
        }
    }
}
