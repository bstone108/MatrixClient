import AppKit
import MatrixCore
import MediaKit

/// `NSImageView` normally reports the source image's dimensions as its
/// intrinsic content size. In a fitted media-preview window that can make a
/// large image drive the window to native pixels instead of filling the
/// viewport. The viewport owns the size; the image only aspect-fits it.
private final class AspectFitImageView: NSImageView {
    override var intrinsicContentSize: NSSize { .zero }
    override var fittingSize: NSSize { .zero }
}

final class MediaPreviewWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let preferredScreen: NSScreen?
    private let preferredMediaContentSize: NSSize
    private let mediaAspectRatio: NSSize?
    private var isApplyingWindowConstraints = false
    private var hasCompletedInitialPlacement = false

    init(item: TimelineItem, url: URL, preferredScreen: NSScreen?, videoPlaybackEngine: any VideoPlaybackEngine) {
        self.preferredScreen = preferredScreen
        self.preferredMediaContentSize = Self.preferredContentSize(for: item, url: url)
        self.mediaAspectRatio = Self.normalizedAspectRatio(for: item, url: url)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: MediaPreviewLayout.defaultContentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = item.media?.filename ?? item.body
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        super.init(window: window)
        window.delegate = self

        let contentView: NSView
        switch item.media?.kind {
        case .video:
            contentView = videoPlaybackEngine.makePlayerView(for: url)
        case .image:
            let imageView = AspectFitImageView(frame: .zero)
            imageView.image = NSImage(contentsOf: url)
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.imageAlignment = .alignCenter
            imageView.setContentHuggingPriority(.fittingSizeCompression, for: .horizontal)
            imageView.setContentHuggingPriority(.fittingSizeCompression, for: .vertical)
            imageView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.fittingSizeCompression, for: .vertical)
            imageView.translatesAutoresizingMaskIntoConstraints = false

            let container = NSView()
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor.black.cgColor
            container.layer?.masksToBounds = true
            container.addSubview(imageView)

            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: container.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
            ])
            contentView = container
        case .audio, .file, .none:
            let label = NSTextField(labelWithString: url.lastPathComponent)
            label.alignment = .center
            label.font = .systemFont(ofSize: 14)
            let container = NSView()
            label.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: container.centerYAnchor)
            ])
            contentView = container
        }

        let controller = NSViewController()
        controller.view = contentView
        window.contentViewController = controller
        applySizeLimits()
        applyInitialPlacement(display: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocusWindow() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        // Screen is often nil before order-front. Refit now that AppKit has
        // assigned one, instead of clamp-only against a stale default frame.
        applyInitialPlacement(display: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applySizeLimits()
        if !hasCompletedInitialPlacement {
            applyInitialPlacement(display: true)
            return
        }
        clampFrameToVisibleScreenIfNeeded()
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let maximumFrame = currentMaximumFrame(for: sender)
        return MediaPreviewLayout.clampedResizeSize(
            frameSize,
            aspect: mediaAspectRatio,
            within: maximumFrame.size
        )
    }

    private func applySizeLimits() {
        guard let window else { return }
        let maximumFrame = currentMaximumFrame(for: window)
        let maximumContentSize = maximumContentSize(for: window, maximumFrame: maximumFrame)
        let minimumContentSize = MediaPreviewLayout.clampedMinimumContentSize(within: maximumContentSize)

        window.maxSize = maximumFrame.size
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        window.contentMaxSize = maximumContentSize
        window.contentMinSize = minimumContentSize
        if let mediaAspectRatio {
            window.contentAspectRatio = mediaAspectRatio
        }
    }

    private func applyInitialPlacement(display: Bool) {
        guard let window else { return }
        guard !isApplyingWindowConstraints else { return }

        applySizeLimits()

        let screen = resolvedScreen(for: window)
        let maximumFrame = currentMaximumFrame(for: window)
        let maximumContentSize = maximumContentSize(for: window, maximumFrame: maximumFrame)
        let fittedContentSize = MediaPreviewLayout.fittedContentSize(
            preferred: preferredMediaContentSize,
            within: maximumContentSize
        )
        let fittedFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: fittedContentSize)).size
        let centered = MediaPreviewLayout.centeredFrame(size: fittedFrameSize, within: maximumFrame)
        let finalFrame = MediaPreviewLayout.clampedFrame(
            centered,
            within: maximumFrame,
            aspect: mediaAspectRatio ?? fittedFrameSize
        ).integral

        isApplyingWindowConstraints = true
        window.setFrame(finalFrame, display: display)
        isApplyingWindowConstraints = false

        if screen != nil || preferredScreen != nil {
            hasCompletedInitialPlacement = true
        }
    }

    private func clampFrameToVisibleScreenIfNeeded() {
        guard let window else { return }
        guard !isApplyingWindowConstraints else { return }

        let maximumFrame = currentMaximumFrame(for: window)
        let clamped = MediaPreviewLayout.clampedFrame(
            window.frame,
            within: maximumFrame,
            aspect: mediaAspectRatio ?? window.frame.size
        ).integral
        guard clamped != window.frame else { return }

        isApplyingWindowConstraints = true
        window.setFrame(clamped, display: true)
        isApplyingWindowConstraints = false
    }

    private static func preferredContentSize(for item: TimelineItem, url: URL) -> NSSize {
        if let width = item.media?.width, let height = item.media?.height, width > 0, height > 0 {
            return NSSize(width: CGFloat(width), height: CGFloat(height))
        }

        if item.media?.kind == .image,
           let imageSize = NSImage(contentsOf: url)?.size,
           imageSize.width > 0,
           imageSize.height > 0 {
            return imageSize
        }

        if item.media?.kind == .video {
            return NSSize(width: 1_280, height: 720)
        }

        return MediaPreviewLayout.defaultContentSize
    }

    private static func normalizedAspectRatio(for item: TimelineItem, url: URL) -> NSSize? {
        let size = preferredContentSize(for: item, url: url)
        guard size.width > 0, size.height > 0 else { return nil }
        return size
    }

    private func visibleFrame(for preferredScreen: NSScreen?) -> NSRect {
        if let preferredScreen {
            return preferredScreen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: MediaPreviewLayout.defaultContentSize)
    }

    private func resolvedScreen(for window: NSWindow) -> NSScreen? {
        if let windowScreen = window.screen {
            return windowScreen
        }
        if let preferredScreen {
            return preferredScreen
        }
        return NSScreen.screens.first {
            $0.frame.insetBy(dx: -MediaPreviewLayout.screenMargin, dy: -MediaPreviewLayout.screenMargin).intersects(window.frame)
        } ?? NSScreen.main
    }

    private func currentMaximumFrame(for window: NSWindow) -> NSRect {
        MediaPreviewLayout.maximumFrame(in: visibleFrame(for: resolvedScreen(for: window)))
    }

    private func maximumContentSize(for window: NSWindow, maximumFrame: NSRect) -> NSSize {
        let contentSize = window.contentRect(forFrameRect: maximumFrame).size
        return NSSize(
            width: max(1, floor(contentSize.width)),
            height: max(1, floor(contentSize.height))
        )
    }
}
