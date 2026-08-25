import Foundation
import MatrixCore
import Testing

@Test
func mediaClassifierMapsImageVideoAudioAndGenericFiles() {
    #expect(MediaAttachmentClassifier.kind(forMimeType: "image/png") == .image)
    #expect(MediaAttachmentClassifier.kind(forMimeType: "IMAGE/JPEG; charset=binary") == .image)
    #expect(MediaAttachmentClassifier.kind(forMimeType: "video/mp4") == .video)
    #expect(MediaAttachmentClassifier.kind(forMimeType: "audio/mpeg") == .audio)
    #expect(MediaAttachmentClassifier.kind(forMimeType: "application/pdf") == .file)
    #expect(MediaAttachmentClassifier.kind(forMimeType: "application/octet-stream") == .file)
}

@Test
func mediaClassifierUsesFilenameExtensionsForCommonTypes() {
    #expect(MediaAttachmentClassifier.mimeType(forFilename: "photo.JPG") == "image/jpeg")
    #expect(MediaAttachmentClassifier.mimeType(forFilename: "clip.mov") == "video/quicktime")
    #expect(MediaAttachmentClassifier.mimeType(forFilename: "voice.m4a") == "audio/mp4")
    #expect(MediaAttachmentClassifier.mimeType(forFilename: "notes.txt") == "text/plain")
    #expect(MediaAttachmentClassifier.mimeType(forFilename: "archive.bin") == "application/octet-stream")
}

@Test
func sanitizedAttachmentFilenameDropsPathComponents() {
    let url = URL(fileURLWithPath: "/tmp/uploads/../secret/report.pdf")
    #expect(MediaAttachmentClassifier.sanitizedFilename(from: url) == "report.pdf")
    #expect(MediaAttachmentClassifier.sanitizedFilename(from: URL(fileURLWithPath: "/")) == "file")
}

@Test
func outgoingMediaAttachmentPreservesCaptionWithoutChangingFileIdentity() {
    let original = OutgoingMediaAttachment(
        fileURL: URL(fileURLWithPath: "/tmp/photo.png"),
        filename: "photo.png",
        mimeType: "image/png",
        kind: .image,
        fileSize: 1_024,
        width: 800,
        height: 600
    )
    let captioned = original.withCaption("Sunset")

    #expect(captioned.caption == "Sunset")
    #expect(captioned.fileURL == original.fileURL)
    #expect(captioned.kind == .image)
    #expect(captioned.fileSize == 1_024)
}

@Test
func matrixSendErrorMessagesDoNotIncludeSecrets() {
    #expect(MatrixSendError.roomNotJoined.errorDescription == "Join this room before sending.")
    #expect(MatrixSendError.fileUnreadable("notes.pdf").errorDescription == "Could not read “notes.pdf”.")
    #expect(MatrixSendError.sdkUnavailable.errorDescription?.contains("token") != true)
}
