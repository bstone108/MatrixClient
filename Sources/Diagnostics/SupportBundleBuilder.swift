import Foundation

public struct SupportBundleAttachment: Sendable {
    public let fileName: String
    public let data: Data

    public init(fileName: String, data: Data) {
        self.fileName = fileName
        self.data = data
    }
}

public struct SupportBundleSummary: Codable, Sendable {
    public let generatedAt: Date
    public let hostName: String
    public let operatingSystem: String
    public let appVersion: String
}

public actor SupportBundleBuilder {
    private let diagnostics: DiagnosticsService
    private let fileManager: FileManager

    public init(diagnostics: DiagnosticsService, fileManager: FileManager = .default) {
        self.diagnostics = diagnostics
        self.fileManager = fileManager
    }

    public func exportBundle(
        appVersion: String = "0.1.0",
        attachments: [SupportBundleAttachment] = []
    ) async throws -> URL {
        let baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("MatrixClient-Support-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)

        let summary = SupportBundleSummary(
            generatedAt: .now,
            hostName: ProcessInfo.processInfo.hostName,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
            appVersion: appVersion
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let logsData = try encoder.encode(await diagnostics.recentEntries())
        try logsData.write(to: baseURL.appendingPathComponent("logs.json"))

        let summaryData = try encoder.encode(summary)
        try summaryData.write(to: baseURL.appendingPathComponent("summary.json"))

        for attachment in attachments {
            try attachment.data.write(to: baseURL.appendingPathComponent(attachment.fileName))
        }

        return baseURL
    }
}

