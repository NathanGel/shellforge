// Ported from AiTerm (app/Sources/AiTermCore/Sidebar/TokenCounts.swift), GPLv3, Laurens D'Hondt.
/// The footer's token counts after `ctx` (proposal A, 8 Oct 2026): `in 936k · out 5.6k`, and one
/// sentence for their tooltip and VoiceOver. The footer formats nothing itself.
public extension TokenTally {
    /// The words before the two numbers, in the footer's voice beside `ctx`, `wk` and `cpu`.
    static let inputLabel = "in", outputLabel = "out"

    /// At most four glyphs, rounded down, so the row never claims more than was spent and never
    /// prints `1000k`: `840`, `5.6k` (`5k`, not `5.0k`), `936k`, `3.2M`, `12M`, `1.2B`.
    static func short(_ count: Int) -> String {
        let count = max(0, count)
        switch count {
        case ..<1_000: return "\(count)"
        case ..<10_000: return tenths(count / 100) + "k"
        case ..<1_000_000: return "\(count / 1_000)k"
        case ..<10_000_000: return tenths(count / 100_000) + "M"
        case ..<1_000_000_000: return "\(count / 1_000_000)M"
        case ..<10_000_000_000: return tenths(count / 100_000_000) + "B"
        default: return "\(count / 1_000_000_000)B"
        }
    }

    /// The pair in words: "Input 936,018 tokens, 99 % from cache · output 5,625 tokens · subagents
    /// included". A cache share the harness cannot tell apart is left out, not read as 0 %.
    var help: String {
        let share = cached.flatMap { cached in
            // Exact integer floors (a Double would read 29 of 100 as 28 %), the count held between none and all first so a
            // stray one never reads as a negative or over-full share, and split so the multiplication cannot overflow.
            let part = min(max(0, cached), input)
            return input > 0 ? ", \(part / input * 100 + part % input * 100 / input) % from cache" : nil
        } ?? ""
        return "Input \(Self.grouped(input)) tokens\(share) · output \(Self.grouped(output)) tokens · subagents included"
    }

    /// Thousands split by commas, written out rather than left to a locale: the same digits on every Mac.
    static func grouped(_ count: Int) -> String {
        var digits = String(max(0, count)), groups: [Substring] = []
        while digits.count > 3 {
            groups.insert(digits.suffix(3), at: 0)
            digits.removeLast(3)
        }
        return ([Substring(digits)] + groups).joined(separator: ",")
    }

    /// `tenths` as a number with one decimal, without a trailing `.0`.
    private static func tenths(_ tenths: Int) -> String {
        tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
    }
}
