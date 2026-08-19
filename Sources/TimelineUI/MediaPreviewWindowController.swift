import AppKit
import MatrixCore
import MediaKit

/// `NSImageView` normally reports the source image's dimensions as its
/// intrinsic content size. In a fixed media-preview window that can make a
/// large image draw at its native size instead of accepting the viewport's
/// dimensions. The viewport owns the size; the image only aspect-fits it.
private final class AspectFitImageView: NSImageView {
    override var intrinsicContentSize: NSSize { .zero }
}

final class MediaPreviewWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let defaultContentSize = NSSize(width: 1_080, height: 760)
        static let minimumContentSize = NSSize(width: 420, height: 320)
        static let screenMargin: CGFloat = 24
    }

    var onClose: (() -> Void)?
    private let preferredScreen: NSScreen?
    private let preferredMediaContentSize: NSSize
    private let mediaAspectRatio: NSSize?
    private var isApplyingWindowConstraints = false

    init(item: TimelineItem, url: URL, preferredScreen: NSScreen?, videoPlaybackEngine: any VideoPlaybackEngine) {
        self.preferredScreen = preferredScreen
        self.preferredMediaContentSize = Self.preferredContentSize(for: item, url: url)
        self.mediaAspectRatio = Self.normalizedAspectRatio(for: item, url: url)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.defaultContentSize),
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
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            imageView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
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
        applyWindowConstraints(recalculateSize: true, display: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func showAndFocusWindow() {
        showWindow(nil)
        applyWindowConstraints(recalculateSize: true, display: false)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
        applyWindowConstraints(recalculateSize: false, display: true)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }

    func windowDidResize(_ notification: Notification) {
        applyWindowConstraints(recalculateSize: false, display: true)
    }

    func windowDidMove(_ notification: Notification) {
        applyWindowConstraints(recalculateSize: false, display: true)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        applyWindowConstraints(recalculateSize: true, display: true)
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let maximumFrame = maximumFrame(for: resolvedScreen(for: sender))
        var proposedFrame = sender.frame
        proposedFrame.size = frameSize
        let clampedFrame = clampedFrame(proposedFrame, maximumFrame: maximumFrame, screen: resolvedScreen(for: sender))
        return clampedFrame.size
    }

    private func applyWindowConstraints(recalculateSize: Bool, display: Bool) {
        guard let window else { return }
        guard !isApplyingWindowConstraints else { return }

        let screen = resolvedScreen(for: window)
        let maximumFrame = maximumFrame(for: screen)
        let maximumContentSize = maximumContentSize(for: window, maximumFrame: maximumFrame)
        let minimumContentSize = minimumContentSize(within: maximumContentSize)

        window.maxSize = maximumFrame.size
        window.minSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: minimumContentSize)).size
        window.contentMaxSize = maximumContentSize
        window.contentMinSize = minimumContentSize
        if let mediaAspectRatio {
            window.contentAspectRatio = mediaAspectRatio
        }

        let targetFrame: NSRect
        if recalculateSize {
            let fittedContentSize = fittedContentSize(within: maximumContentSize)
            let fittedFrameSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: fittedContentSize)).size
            targetFrame = centeredFrame(
                size: fittedFrameSize,
                within: maximumFrame
            )
        } else {
            targetFrame = clampedFrame(window.frame, maximumFrame: maximumFrame, screen: screen)
        }

        let finalFrame = clampedFrame(targetFrame, maximumFrame: maximumFrame, screen: screen).integral
        guard finalFrame != window.frame else { return }

        isApplyingWindowConstraints = true
        window.setFrame(finalFrame, display: display)
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

        return Layout.defaultContentSize
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
        return NSScreen.main?.visibleFrame ?? NSRect(origin: .zero, size: Layout.defaultContentSize)
    }

    private func resolvedScreen(for window: NSWindow) -> NSScreen? {
        if let windowScreen = window.screen {
            return windowScreen
        }
        if let preferredScreen {
            return preferredScreen
        }
        return NSScreen.screens.first {
            $0.frame.insetBy(dx: -Layout.screenMargin, dy: -Layout.screenMargin).intersects(window.frame)
        } ?? NSScreen.main
    }

    private func maximumFrame(for screen: NSScreen?) -> NSRect {
        let frame = visibleFrame(for: screen)
        let constrained = frame.insetBy(dx: Layout.screenMargin, dy: Layout.screenMargin)
        if constrained.width > 0, constrained.height > 0 {
            return constrained
        }
        return frame
    }

    private func maximumContentSize(for window: NSWindow, maximumFrame: NSRect) -> NSSize {
        let contentSize = window.contentRect(forFrameRect: maximumFrame).size
        return NSSize(
            width: max(1, floor(contentSize.width)),
            height: max(1, floor(contentSize.height))
        )
    }

    private func minimumContentSize(within maximumContentSize: NSSize) -> NSSize {
        NSSize(
            width: min(Layout.minimumContentSize.width, maximumContentSize.width),
            height: min(Layout.minimumContentSize.height, maximumContentSize.height)
        )
    }

    private func fittedContentSize(within maximumContentSize: NSSize) -> NSSize {
        let preferredSize = preferredMediaContentSize
        guard preferredSize.width > 0, preferredSize.height > 0 else {
            return maximumContentSize
        }

        let widthScale = maximumContentSize.width / preferredSize.width
        let heightScale = maximumContentSize.height / preferredSize.height
        let scale = min(1, widthScale, heightScale)
        let fittedSize = NSSize(
            width: max(1, floor(preferredSize.width * scale)),
            height: max(1, floor(preferredSize.height * scale))
        )

        return NSSize(
            width: min(fittedSize.width, maximumContentSize.width),
            height: min(fittedSize.height, maximumContentSize.height)
        )
    }

    private func centeredFrame(size: NSSize, within bounds: NSRect) -> NSRect {
        NSRect(
            x: bounds.midX - (size.width / 2),
            y: bounds.midY - (size.height / 2),
            width: size.width,
            height: size.height
        )
    }

    private func clampedFrame(_ frame: NSRect, maximumFrame: NSRect, screen: NSScreen?) -> NSRect {
        var result = frame
        result.size.width = min(result.width, maximumFrame.width)
        result.size.height = min(result.height, maximumFrame.height)

        if let screen, let window {
            result = window.constrainFrameRect(result, to: screen)
        }

        if result.minX < maximumFrame.minX {
            result.origin.x = maximumFrame.minX
        }
        if result.maxX > maximumFrame.maxX {
            result.origin.x = maximumFrame.maxX - result.width
        }
        if result.minY < maximumFrame.minY {
            result.origin.y = maximumFrame.minY
        }
        if result.maxY > maximumFrame.maxY {
            result.origin.y = maximumFrame.maxY - result.height
        }

        return result
    }
}
