import AppKit
import Diagnostics
import Foundation
import ImageIO

@MainActor
public protocol VideoPlaybackEngine: AnyObject {
    var displayName: String { get }
    func makePlayerView(for url: URL) -> NSView
}

public final class ImagePreviewPipeline {
    private let diagnostics: DiagnosticsService

    public init(diagnostics: DiagnosticsService) {
        self.diagnostics = diagnostics
    }

    public func thumbnail(for url: URL, maxPixelSize: CGFloat = 512) async -> NSImage? {
        await diagnostics.record(.debug, category: "Media", message: "Generating image thumbnail", metadata: [
            "url": url.lastPathComponent
        ])

        let cgImage = await Task.detached(priority: .utility) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
        guard let cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: .zero)
    }
}
