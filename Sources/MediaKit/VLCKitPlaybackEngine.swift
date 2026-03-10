import AppKit
import Diagnostics
import Foundation
import ObjectiveC

#if canImport(VLCKitSPM)
import VLCKitSPM
#endif

@MainActor
public final class VLCKitPlaybackEngine: VideoPlaybackEngine {
    private let diagnostics: DiagnosticsService
    private static var playerAssociationKey = 0

    public init(diagnostics: DiagnosticsService) {
        self.diagnostics = diagnostics
    }

    public var displayName: String {
        "VLCKit"
    }

    public func makePlayerView(for url: URL) -> NSView {
        Task {
            await diagnostics.record(.notice, category: "Media", message: "Creating VLC-backed player view", metadata: [
                "url": url.lastPathComponent
            ])
        }

        #if canImport(VLCKitSPM)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.black.cgColor

        let videoView = VLCVideoView(frame: container.bounds)
        videoView.autoresizingMask = [.width, .height]
        container.addSubview(videoView)

        let player = VLCMediaPlayer()
        player.drawable = videoView
        player.media = VLCMedia(url: url)
        player.play()
        objc_setAssociatedObject(
            container,
            &Self.playerAssociationKey,
            player,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return container
        #else
        let placeholder = NSTextField(labelWithString: "VLCKit package unavailable for \(url.lastPathComponent)")
        placeholder.alignment = .center
        placeholder.textColor = .secondaryLabelColor
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 540))
        placeholder.frame = container.bounds
        placeholder.autoresizingMask = [.width, .height]
        container.addSubview(placeholder)
        return container
        #endif
    }
}
