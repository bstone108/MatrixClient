import Foundation

public enum MatrixSendError: LocalizedError, Sendable, Equatable {
    case roomNotJoined
    case missingSelection
    case fileUnreadable(String)
    case sdkUnavailable

    public var errorDescription: String? {
        switch self {
        case .roomNotJoined:
            return "Join this room before sending."
        case .missingSelection:
            return "Select a room before sending."
        case let .fileUnreadable(name):
            return "Could not read “\(name)”."
        case .sdkUnavailable:
            return "File sending is unavailable in this build."
        }
    }
}

public struct OutgoingMediaAttachment: Hashable, Codable, Sendable {
    public let fileURL: URL
    public let filename: String
    public let mimeType: String
    public let kind: TimelineMediaKind
    public let fileSize: UInt64
    public let width: UInt64?
    public let height: UInt64?
    public let durationSeconds: Double?
    public let caption: String?

    public init(
        fileURL: URL,
        filename: String,
        mimeType: String,
        kind: TimelineMediaKind,
        fileSize: UInt64,
        width: UInt64? = nil,
        height: UInt64? = nil,
        durationSeconds: Double? = nil,
        caption: String? = nil
    ) {
        self.fileURL = fileURL
        self.filename = filename
        self.mimeType = mimeType
        self.kind = kind
        self.fileSize = fileSize
        self.width = width
        self.height = height
        self.durationSeconds = durationSeconds
        self.caption = caption
    }

    public func withCaption(_ caption: String?) -> OutgoingMediaAttachment {
        OutgoingMediaAttachment(
            fileURL: fileURL,
            filename: filename,
            mimeType: mimeType,
            kind: kind,
            fileSize: fileSize,
            width: width,
            height: height,
            durationSeconds: durationSeconds,
            caption: caption
        )
    }

    public var fileSystemPath: String {
        fileURL.path(percentEncoded: false)
    }
}

public enum MediaAttachmentClassifier: Sendable {
    public static func kind(forMimeType mimeType: String) -> TimelineMediaKind {
        let lowered = mimeType.split(separator: ";", maxSplits: 1).first.map(String.init)?.lowercased() ?? mimeType.lowercased()
        if lowered.hasPrefix("image/") {
            return .image
        }
        if lowered.hasPrefix("video/") {
            return .video
        }
        if lowered.hasPrefix("audio/") {
            return .audio
        }
        return .file
    }

    public static func mimeType(forFilename filename: String) -> String {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        switch ext {
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "gif":
            return "image/gif"
        case "webp":
            return "image/webp"
        case "heic":
            return "image/heic"
        case "tif", "tiff":
            return "image/tiff"
        case "bmp":
            return "image/bmp"
        case "svg":
            return "image/svg+xml"
        case "mp4", "m4v":
            return "video/mp4"
        case "mov":
            return "video/quicktime"
        case "webm":
            return "video/webm"
        case "mkv":
            return "video/x-matroska"
        case "avi":
            return "video/x-msvideo"
        case "mp3":
            return "audio/mpeg"
        case "m4a", "aac":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "ogg", "oga":
            return "audio/ogg"
        case "flac":
            return "audio/flac"
        case "pdf":
            return "application/pdf"
        case "txt":
            return "text/plain"
        case "json":
            return "application/json"
        case "zip":
            return "application/zip"
        default:
            return "application/octet-stream"
        }
    }

    public static func sanitizedFilename(from url: URL) -> String {
        let name = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name == "/" || name == "." || name == ".." {
            return "file"
        }
        return name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }
}
