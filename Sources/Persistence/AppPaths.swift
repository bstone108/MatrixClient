import Foundation

public struct AppPaths: Sendable {
    public let applicationSupportURL: URL
    public let databaseURL: URL

    public init(applicationSupportURL: URL, databaseURL: URL) {
        self.applicationSupportURL = applicationSupportURL
        self.databaseURL = databaseURL
    }

    public static func `default`(fileManager: FileManager = .default) throws -> AppPaths {
        let appSupportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let applicationSupportURL = appSupportRoot.appendingPathComponent("MatrixClient", isDirectory: true)
        if !fileManager.fileExists(atPath: applicationSupportURL.path) {
            try fileManager.createDirectory(at: applicationSupportURL, withIntermediateDirectories: true)
        }
        return AppPaths(
            applicationSupportURL: applicationSupportURL,
            databaseURL: applicationSupportURL.appendingPathComponent("MatrixClient.sqlite")
        )
    }
}

