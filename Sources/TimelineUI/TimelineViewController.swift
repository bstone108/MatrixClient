import AppKit
import Foundation
import ImageIO
import MatrixCore
import MediaKit

@MainActor
public protocol TimelineWorkspaceState: AnyObject {
    var timelineItems: [TimelineItem] { get }
    var selectedRoomSummary: RoomSummary? { get }
    func addTimelineObserver(_ observer: @escaping @MainActor () -> Void)
    func addMediaObserver(_ observer: @escaping @MainActor () -> Void)
    func addSelectionObserver(_ observer: @escaping @MainActor () -> Void)
    func mediaState(for itemID: String) -> TimelineMediaLoadState?
    func prepareMedia(for item: TimelineItem, prefetchOriginal: Bool)
    func resolveOriginalMediaURL(for item: TimelineItem) async -> URL?
    func resolveReceiptAvatarFileURL(for receipt: ReadReceipt) async -> URL?
    func markSelectedRoomAsRead()
    func sendMessage(_ body: String)
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        senderField.font = .boldSystemFont(ofSize: 12)
        bodyField.font = .systemFont(ofSize: 13)
        bodyField.maximumNumberOfLines = 0
        metaField.font = .systemFont(ofSize: 11)
        metaField.textColor = .secondaryLabelColor

        let metaRow = NSStackView(views: [metaField, NSView(), receiptStripView])
        metaRow.orientation = .horizontal
        metaRow.alignment = .centerY
        metaRow.spacing = 8
        metaRow.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [senderField, bodyField, metaRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
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
        static let previewHeight: CGFloat = 220
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
    var onOpenRequested: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        senderField.font = .boldSystemFont(ofSize: 12)
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
        previewButton.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        previewButton.layer?.cornerRadius = 10
        previewButton.layer?.borderWidth = 1
        previewButton.layer?.borderColor = NSColor.separatorColor.cgColor
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
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            previewButton.heightAnchor.constraint(equalToConstant: Layout.previewHeight),
            previewButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 320),
            progressIndicator.widthAnchor.constraint(equalToConstant: 180),
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
            openButton.isHidden = true
            previewButton.toolTip = mediaState?.originalFileURL == nil ? "Fetch and open original" : "Open original"
        case .audio, .file, .none:
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
                    self.previewButton.contentTintColor = nil
                    self.hasResolvedPreviewImage = true
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
    }

    private static func previewImage(for url: URL, maxPixelSize: CGFloat) async -> NSImage? {
        await Task.detached(priority: .utility) {
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return NSImage(contentsOf: url)
            }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                return NSImage(contentsOf: url)
            }
            return NSImage(cgImage: cgImage, size: .zero)
        }.value
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

public final class TimelineViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSTextViewDelegate {
    private enum Layout {
        static let messageBaseHeight: CGFloat = 82
        static let statusBaseHeight: CGFloat = 58
        static let mediaBaseHeight: CGFloat = 332
        static let mediaExtraLineHeight: CGFloat = 16
        static let messageExtraLineHeight: CGFloat = 16
        static let autoScrollThreshold: CGFloat = 36
        static let composerMinHeight: CGFloat = 38
        static let composerMaxHeight: CGFloat = 160
    }

    private let state: any TimelineWorkspaceState
    private let videoPlaybackEngine: any VideoPlaybackEngine
    private let titleField = NSTextField(labelWithString: "No Room Selected")
    private let tableView = NSTableView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let composerScrollView = NSScrollView(frame: .zero)
    private let composerTextView = NSTextView(frame: .zero)
    private var composerHeightConstraint: NSLayoutConstraint?
    private var scrollObserver: NSObjectProtocol?
    private var pendingReadMarkTask: Task<Void, Never>?

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
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false

        titleField.font = .systemFont(ofSize: 20, weight: .semibold)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("timeline"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.intercellSpacing = NSSize(width: 0, height: 8)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.selectionHighlightStyle = .none

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.contentView.postsBoundsChangedNotifications = true

        composerTextView.font = .systemFont(ofSize: 14)
        composerTextView.isRichText = false
        composerTextView.usesFindPanel = false
        composerTextView.isHorizontallyResizable = false
        composerTextView.isVerticallyResizable = true
        composerTextView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        composerTextView.textContainer?.widthTracksTextView = true
        composerTextView.textContainer?.heightTracksTextView = false
        composerTextView.textContainer?.lineFragmentPadding = 0
        composerTextView.textContainerInset = NSSize(width: 0, height: 7)
        composerTextView.delegate = self

        composerScrollView.documentView = composerTextView
        composerScrollView.hasVerticalScroller = false
        composerScrollView.autohidesScrollers = true
        composerScrollView.borderType = .bezelBorder

        let sendButton = NSButton(title: "Send", target: self, action: #selector(sendCurrentDraft))
        sendButton.keyEquivalent = "\r"

        let composerRow = NSStackView(views: [composerScrollView, sendButton])
        composerRow.orientation = .horizontal
        composerRow.alignment = .top
        composerRow.spacing = 12

        let stack = NSStackView(views: [titleField, scrollView, composerRow])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        composerHeightConstraint = composerScrollView.heightAnchor.constraint(equalToConstant: Layout.composerMinHeight)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),
            composerHeightConstraint!,
            sendButton.widthAnchor.constraint(equalToConstant: 88)
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
        state.addTimelineObserver { [weak self] in
            self?.reloadTimeline()
        }
        state.addMediaObserver { [weak self] in
            self?.refreshVisibleMediaRows()
        }
        state.addSelectionObserver { [weak self] in
            self?.reloadSelection()
        }
        reloadSelection()
        reloadTimeline()
        updateComposerHeight()
    }

    public override func viewWillDisappear() {
        super.viewWillDisappear()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        pendingReadMarkTask?.cancel()
        pendingReadMarkTask = nil
    }

    public override func viewDidLayout() {
        super.viewDidLayout()
        updateComposerHeight()
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
            if item.media != nil {
                let extraLines = max(0, CGFloat(item.body.count / 72))
                return Layout.mediaBaseHeight + (extraLines * Layout.mediaExtraLineHeight)
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
    private func sendCurrentDraft() {
        let body = composerTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        state.sendMessage(body)
        composerTextView.string = ""
        updateComposerHeight()
    }

    private func reloadSelection() {
        titleField.stringValue = state.selectedRoomSummary?.displayName ?? "No Room Selected"
    }

    private func reloadTimeline() {
        let clipView = scrollView.contentView
        let previousVisibleRect = clipView.documentVisibleRect
        let previousOffset = clipView.bounds.origin.y
        let wasAtBottom = previousVisibleRect.maxY >= max(tableView.bounds.height - Layout.autoScrollThreshold, 0)

        tableView.reloadData()
        tableView.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<state.timelineItems.count))
        tableView.layoutSubtreeIfNeeded()

        if wasAtBottom {
            scrollToBottom()
            scheduleMarkSelectedRoomAsRead()
            return
        }

        let maxOffset = max(0, tableView.bounds.height - clipView.bounds.height)
        clipView.scroll(to: NSPoint(x: 0, y: min(previousOffset, maxOffset)))
        scrollView.reflectScrolledClipView(clipView)
    }

    private func refreshVisibleMediaRows() {
        guard !state.timelineItems.isEmpty else { return }
        let visibleRect = scrollView.contentView.documentVisibleRect
        let rows = tableView.rows(in: visibleRect)
        guard rows.location != NSNotFound, rows.length > 0 else { return }

        for row in rows.location..<(rows.location + rows.length) where tableView.numberOfRows > row {
            let item = state.timelineItems[row]
            guard item.media != nil else { continue }
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

    public func textDidChange(_ notification: Notification) {
        guard notification.object as AnyObject? === composerTextView else { return }
        updateComposerHeight()
    }

    public func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === composerTextView else { return false }
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) ||
              commandSelector == #selector(NSResponder.insertLineBreak(_:)) else {
            return false
        }

        let modifiers = NSApp.currentEvent?.modifierFlags.intersection([.shift, .option, .control, .command]) ?? []
        guard modifiers.isEmpty else { return false }

        sendCurrentDraft()
        return true
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

    private func updateComposerHeight() {
        guard let textContainer = composerTextView.textContainer,
              let layoutManager = composerTextView.layoutManager else {
            return
        }

        let contentWidth = max(composerScrollView.contentSize.width, 0)
        textContainer.containerSize = NSSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)

        let textHeight = layoutManager.usedRect(for: textContainer).height
        let targetHeight = max(
            Layout.composerMinHeight,
            min(
                Layout.composerMaxHeight,
                ceil(textHeight + (composerTextView.textContainerInset.height * 2) + 2)
            )
        )

        if composerHeightConstraint?.constant != targetHeight {
            composerHeightConstraint?.constant = targetHeight
        }
        composerScrollView.hasVerticalScroller = targetHeight >= Layout.composerMaxHeight
    }
}
