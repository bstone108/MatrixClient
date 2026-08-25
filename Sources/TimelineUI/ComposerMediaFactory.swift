import AppKit
import Foundation
import ImageIO
import MatrixCore
import UniformTypeIdentifiers

enum ComposerMediaFactory {
    static func attachments(from urls: [URL], caption: String?) throws -> [OutgoingMediaAttachment] {
        let trimmedCaption = caption?.trimmingCharacters(in: .whitespacesAndNewlines)
        let captionValue = (trimmedCaption?.isEmpty == false) ? trimmedCaption : nil
        var result: [OutgoingMediaAttachment] = []
        result.reserveCapacity(urls.count)
        for (index, url) in urls.enumerated() {
            result.append(try attachment(from: url, caption: index == 0 ? captionValue : nil))
        }
        return result
    }

    static func attachment(from url: URL, caption: String?) throws -> OutgoingMediaAttachment {
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.isFileURL else {
            throw MatrixSendError.fileUnreadable(MediaAttachmentClassifier.sanitizedFilename(from: url))
        }

        let accessed = resolved.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                resolved.stopAccessingSecurityScopedResource()
            }
        }

        let filename = MediaAttachmentClassifier.sanitizedFilename(from: resolved)
        let path = resolved.path(percentEncoded: false)
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw MatrixSendError.fileUnreadable(filename)
        }

        let values = try resolved.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey, .isDirectoryKey, .isSymbolicLinkKey])
        if values.isDirectory == true {
            throw MatrixSendError.fileUnreadable(filename)
        }

        let rawSize = values.fileSize.map(Int64.init)
            ?? (try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.int64Value
            ?? 0
        let fileSize = UInt64(max(0, rawSize))
        let mimeType = mimeType(for: values.contentType, filename: filename)
        let kind = MediaAttachmentClassifier.kind(forMimeType: mimeType)
        let pixelSize = (kind == .image || kind == .video) ? imagePixelSize(at: resolved) : nil

        return OutgoingMediaAttachment(
            fileURL: resolved,
            filename: filename,
            mimeType: mimeType,
            kind: kind,
            fileSize: fileSize,
            width: pixelSize.map { UInt64(max(0, $0.width)) },
            height: pixelSize.map { UInt64(max(0, $0.height)) },
            caption: caption
        )
    }

    private static func mimeType(for contentType: UTType?, filename: String) -> String {
        if let preferred = contentType?.preferredMIMEType, !preferred.isEmpty {
            return preferred
        }
        return MediaAttachmentClassifier.mimeType(forFilename: filename)
    }

    private static func imagePixelSize(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let width = properties[kCGImagePropertyPixelWidth] as? Int
        let height = properties[kCGImagePropertyPixelHeight] as? Int
        guard let width, let height, width > 0, height > 0 else { return nil }
        return (width, height)
    }
}
