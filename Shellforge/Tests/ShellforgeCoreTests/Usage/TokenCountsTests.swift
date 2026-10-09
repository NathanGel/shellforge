// Ported from AiTerm (app/Tests/AiTermCoreTests/TokenCountsTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct TokenCountsTests {
    /// At most four glyphs, rounded down: the row never claims more than was spent, and never
    /// prints `1000k` or `5.0k` (proposal A, 8 Oct 2026).
    @Test(arguments: zip(
        [0, 840, 999, 1_000, 5_099, 5_625, 9_999, 10_000, 936_018, 999_999, 1_000_000, 3_283_279, 9_999_999, 12_400_000, -3, 99_999, 99_999_999, 999_999_999, 1_000_000_000, 1_234_000_000, 12_400_000_000],
        ["0", "840", "999", "1k", "5k", "5.6k", "9.9k", "10k", "936k", "999k", "1M", "3.2M", "9.9M", "12M", "0", "99k", "99M", "999M", "1B", "1.2B", "12B"]))
    func shortCounts(count: Int, expected: String) {
        #expect(TokenTally.short(count) == expected)
    }

    /// The tooltip and VoiceOver say the pair in words, with every digit and the cache's share.
    @Test func thePairIsReadInWords() {
        #expect(TokenTally(input: 936_018, cached: 935_988, output: 5_625).help
                == "Input 936,018 tokens, 99 % from cache · output 5,625 tokens · subagents included")
    }

    /// A share the harness cannot tell apart is left out rather than read as none.
    @Test func anUnknownCacheShareIsLeftOut() {
        #expect(TokenTally(input: 12, cached: nil, output: 3).help == "Input 12 tokens · output 3 tokens · subagents included")
        #expect(TokenTally(input: 0, cached: 0, output: 0).help == "Input 0 tokens · output 0 tokens · subagents included")
    }

    /// A count that cannot be a share of the input is held to none or all, never negative or over 100 %.
    @Test func theCacheShareStaysBetweenNoneAndAll() {
        #expect(TokenTally(input: 100, cached: 250, output: 1).help.contains(", 100 % from cache"))
        #expect(TokenTally(input: 100, cached: -5, output: 1).help.contains(", 0 % from cache"))
    }

    /// The share is an exact floor: 29 of 100 reads 29 %, not the 28 a floating-point division would give.
    @Test func theCacheShareIsAnExactFloor() {
        #expect(TokenTally(input: 100, cached: 29, output: 1).help
                == "Input 100 tokens, 29 % from cache · output 1 tokens · subagents included")
    }

    /// Thousands are split by commas on every Mac, whatever its locale.
    @Test func groupedCounts() {
        #expect(TokenTally.grouped(0) == "0")
        #expect(TokenTally.grouped(999) == "999")
        #expect(TokenTally.grouped(1_000) == "1,000")
        #expect(TokenTally.grouped(3_283_279) == "3,283,279")
    }
}
