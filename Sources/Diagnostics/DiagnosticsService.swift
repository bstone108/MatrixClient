import Foundation
import OSLog

public enum LogLevel: String, Codable, Sendable {
    case debug
    case info
    case notice
    case error
    case fault
}

public struct AppLogEntry: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let level: LogLevel
    public let category: String
    public let message: String
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        level: LogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = metadata
    }
}

public actor DiagnosticsService {
    private let subsystem: String
    private let maxEntries: Int
    private var entries: [AppLogEntry] = []

    public init(subsystem: String = "com.brandonstone.MatrixClient", maxEntries: Int = 1_000) {
        self.subsystem = subsystem
        self.maxEntries = maxEntries
    }

    public func record(
        _ level: LogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let entry = AppLogEntry(level: level, category: category, message: message, metadata: metadata)
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }

        let logger = Logger(subsystem: subsystem, category: category)
        let metadataString = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        let rendered = metadataString.isEmpty ? message : "\(message) [\(metadataString)]"

        switch level {
        case .debug:
            logger.debug("\(rendered, privacy: .public)")
        case .info:
            logger.info("\(rendered, privacy: .public)")
        case .notice:
            logger.notice("\(rendered, privacy: .public)")
        case .error:
            logger.error("\(rendered, privacy: .public)")
        case .fault:
            logger.fault("\(rendered, privacy: .public)")
        }
    }

    public func recentEntries() -> [AppLogEntry] {
        entries
    }
}

