import Foundation
import MatrixCore
import Testing

@Test
func dateBuildVersionParsesCanonicalPaddedTags() {
    let version = DateBuildVersion.parse("v2026.08.25.02")
    #expect(version == DateBuildVersion(year: 2026, month: 8, day: 25, build: 2))
    #expect(DateBuildVersion.parse("2026.08.25.02")?.rawValue == "2026.08.25.02")
}

@Test
func dateBuildVersionReadsLegacyUnpaddedTagsAndNormalizesThem() {
    let version = DateBuildVersion.parse("v2026.8.25.2")
    #expect(version == DateBuildVersion(year: 2026, month: 8, day: 25, build: 2))
    #expect(version?.rawValue == "2026.08.25.02")
}

@Test
func dateBuildVersionRejectsMixedOrInvalidFormats() {
    #expect(DateBuildVersion.parse("2026.08.25.2") == nil)
    #expect(DateBuildVersion.parse("2026.8.25.02") == nil)
    #expect(DateBuildVersion.parse("2026.08.25.00") == nil)
    #expect(DateBuildVersion.parse("0.1.0") == nil)
    #expect(DateBuildVersion.parse("ci") == nil)
}

@Test
func dateBuildVersionComparesNumericallyNotLexically() {
    let older = DateBuildVersion.parse("2026.08.24.09")!
    let newer = DateBuildVersion.parse("2026.08.24.10")!
    let nextMonth = DateBuildVersion.parse("2026.09.01.01")!
    #expect(older < newer)
    #expect(newer < nextMonth)
    #expect(newer > older)
}
