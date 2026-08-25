import Foundation

/// `YYYY.M.D.N` America/Chicago date.build (unpadded month and day).
public struct DateBuildVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public let build: Int

    public var description: String { rawValue }

    public var rawValue: String {
        "\(year).\(month).\(day).\(build)"
    }

    public init(year: Int, month: Int, day: Int, build: Int) {
        self.year = year
        self.month = month
        self.day = day
        self.build = build
    }

    public static func parse(_ raw: String) -> DateBuildVersion? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") || trimmed.hasPrefix("V")
            ? String(trimmed.dropFirst())
            : trimmed
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4,
              let year = Int(parts[0]), year >= 1_000, year <= 9_999,
              let month = Int(parts[1]), (1...12).contains(month),
              let day = Int(parts[2]), (1...31).contains(day),
              let build = Int(parts[3]), build >= 1 else {
            return nil
        }
        // Reject zero-padded month/day such as 2026.08.24.1.
        guard String(month) == parts[1], String(day) == parts[2] else {
            return nil
        }
        return DateBuildVersion(year: year, month: month, day: day, build: build)
    }

    public static func < (lhs: DateBuildVersion, rhs: DateBuildVersion) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        if lhs.day != rhs.day { return lhs.day < rhs.day }
        return lhs.build < rhs.build
    }
}
