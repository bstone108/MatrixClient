import CryptoKit
import Diagnostics
import Foundation

#if canImport(MatrixRustSDK)
@preconcurrency import MatrixRustSDK
#endif

#if canImport(MatrixRustSDK)
public actor ReceiptAvatarCache {
    private let client: Client
    private let diagnostics: DiagnosticsService
    private let cacheDirectoryURL: URL
    private let fileManager = FileManager.default

    private var inFlightTasks: [String: Task<URL?, Never>] = [:]

    public init(client: Client, diagnostics: DiagnosticsService, cacheRootURL: URL) {
        self.client = client
        self.diagnostics = diagnostics
        self.cacheDirectoryURL = cacheRootURL.appendingPathComponent("ReceiptAvatars", isDirectory: true)
    }

    public func fileURL(for avatarURL: String) async -> URL? {
        let normalizedAvatarURL = avatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedAvatarURL.isEmpty else { return nil }

        let destinationURL = cacheDirectoryURL.appendingPathComponent(cacheFileName(for: normalizedAvatarURL), isDirectory: false)
        if fileManager.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        if let task = inFlightTasks[normalizedAvatarURL] {
            return await task.value
        }

        let task = Task<URL?, Never> { [weak self] in
            guard let self else { return nil }
            return await self.fetchAvatarFile(normalizedAvatarURL, destinationURL: destinationURL)
        }
        inFlightTasks[normalizedAvatarURL] = task
        let result = await task.value
        inFlightTasks[normalizedAvatarURL] = nil
        return result
    }

    private func fetchAvatarFile(_ avatarURL: String, destinationURL: URL) async -> URL? {
        do {
            try fileManager.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destinationURL.path) {
                return destinationURL
            }

            let data = try await avatarData(for: avatarURL)
            try data.write(to: destinationURL, options: .atomic)
            return destinationURL
        } catch {
            await diagnostics.record(.error, category: "Receipts", message: "Failed to cache receipt avatar", metadata: [
                "avatarURL": avatarURL,
                "error": error.localizedDescription
            ])
            try? fileManager.removeItem(at: destinationURL)
            return nil
        }
    }

    private func avatarData(for avatarURL: String) async throws -> Data {
        if avatarURL.hasPrefix("mxc://") {
            let mediaSource = mediaSourceFromUrl(url: avatarURL)
            if let thumbnailData = try? await client.getMediaThumbnail(mediaSource: mediaSource, width: 72, height: 72),
               !thumbnailData.isEmpty {
                return thumbnailData
            }
            return try await client.getMediaContent(mediaSource: mediaSource)
        }

        guard let remoteURL = URL(string: avatarURL) else {
            throw URLError(.badURL)
        }

        let (data, _) = try await URLSession.shared.data(from: remoteURL)
        return data
    }

    private func cacheFileName(for avatarURL: String) -> String {
        let digest = SHA256.hash(data: Data(avatarURL.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "\(hex).img"
    }
}
#endif
