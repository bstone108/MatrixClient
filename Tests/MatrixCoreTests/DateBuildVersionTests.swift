import Foundation
import MatrixCore
import Testing

@Test
func dateBuildVersionParsesUnpaddedTags() {
    let version = DateBuildVersion.parse("v2026.8.25.2")
    #expect(version == DateBuildVersion(year: 2026, month: 8, day: 25, build: 2))
    #expect(DateBuildVersion.parse("2026.8.25.2")?.rawValue == "2026.8.25.2")
}

@Test
func dateBuildVersionRejectsZeroPaddedMonthOrDay() {
    #expect(DateBuildVersion.parse("2026.08.25.1") == nil)
    #expect(DateBuildVersion.parse("2026.8.05.1") == nil)
    #expect(DateBuildVersion.parse("0.1.0") == nil)
    #expect(DateBuildVersion.parse("ci") == nil)
}

@Test
func dateBuildVersionComparesNumericallyNotLexically() {
    let older = DateBuildVersion.parse("2026.8.24.9")!
    let newer = DateBuildVersion.parse("2026.8.24.10")!
    let nextMonth = DateBuildVersion.parse("2026.9.1.1")!
    #expect(older < newer)
    #expect(newer < nextMonth)
    #expect(newer > older)
}
