import Foundation

/// `YYYY.MM.DD.BB` America/Chicago date.build.
public struct DateBuildVersion: Comparable, Hashable, Sendable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int
    public let build: Int

    public var description: String { rawValue }

    public var rawValue: String {
        String(format: "%04d.%02d.%02d.%02d", year, month, day, build)
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
              let build = Int(parts[3]), (1...99).contains(build) else {
            return nil
        }
        let isCanonical = parts[1].count == 2 &&
            parts[2].count == 2 &&
            parts[3].count == 2 &&
            String(format: "%02d", month) == parts[1] &&
            String(format: "%02d", day) == parts[2] &&
            String(format: "%02d", build) == parts[3]
        let isLegacy = String(month) == parts[1] &&
            String(day) == parts[2] &&
            String(build) == parts[3]
        // Keep reading previously published unpadded releases, but normalize
        // their numeric value so newly issued versions remain canonical.
        guard isCanonical || isLegacy else {
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
