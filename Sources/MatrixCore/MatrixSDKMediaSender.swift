import Foundation

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK

enum MatrixSDKMediaSender {
    /// Sends via the Matrix Rust SDK timeline APIs (`sendImage` / `sendVideo` /
    /// `sendAudio` / `sendFile`). Those methods already enqueue through the SDK
    /// send queue; this is not a parallel HTTP upload.
    static func send(_ attachment: OutgoingMediaAttachment, using timeline: Timeline) async throws {
        let accessed = attachment.fileURL.startAccessingSecurityScopedResource()
        defer {
            if accessed {
                attachment.fileURL.stopAccessingSecurityScopedResource()
            }
        }

        let path = attachment.fileSystemPath
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw MatrixSendError.fileUnreadable(attachment.filename)
        }

        let params = UploadParameters(
            source: .file(filename: path),
            caption: nonemptyCaption(attachment.caption),
            formattedCaption: nil,
            mentions: nil,
            inReplyTo: nil
        )

        switch attachment.kind {
        case .image:
            let handle = try timeline.sendImage(
                params: params,
                thumbnailSource: nil,
                imageInfo: ImageInfo(
                    height: attachment.height,
                    width: attachment.width,
                    mimetype: attachment.mimeType,
                    size: attachment.fileSize,
                    thumbnailInfo: nil,
                    thumbnailSource: nil,
                    blurhash: nil,
                    isAnimated: nil
                )
            )
            try await handle.join()
        case .video:
            let handle = try timeline.sendVideo(
                params: params,
                thumbnailSource: nil,
                videoInfo: VideoInfo(
                    duration: nil,
                    height: attachment.height,
                    width: attachment.width,
                    mimetype: attachment.mimeType,
                    size: attachment.fileSize,
                    thumbnailInfo: nil,
                    thumbnailSource: nil,
                    blurhash: nil
                )
            )
            try await handle.join()
        case .audio:
            let handle = try timeline.sendAudio(
                params: params,
                audioInfo: AudioInfo(
                    duration: nil,
                    size: attachment.fileSize,
                    mimetype: attachment.mimeType
                )
            )
            try await handle.join()
        case .file:
            let handle = try timeline.sendFile(
                params: params,
                fileInfo: FileInfo(
                    mimetype: attachment.mimeType,
                    size: attachment.fileSize,
                    thumbnailInfo: nil,
                    thumbnailSource: nil
                )
            )
            try await handle.join()
        }
    }

    private static func nonemptyCaption(_ caption: String?) -> String? {
        guard let caption else { return nil }
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
#endif
