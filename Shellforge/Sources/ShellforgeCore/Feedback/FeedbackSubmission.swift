import Foundation

/// What the app sends to the feedback relay. The keys are the relay's (`feedback-relay/src/validate.js`):
/// absent fields are left out of the JSON, never sent empty.
public struct FeedbackSubmission: Codable, Equatable, Sendable {
    public let version: String
    public let macos: String
    public let rating: Int?
    public let good: String?
    public let bad: String?

    public init(versions: AppVersions, good: String, bad: String, rating: Int?) {
        self.version = versions.version
        self.macos = versions.macOS
        self.rating = rating
        self.good = Self.text(good)
        self.bad = Self.text(bad)
    }

    /// Characters the relay strips before it looks at the text (`feedback-relay/src/clean.js`):
    /// controls other than newline and tab, zero-width and bidi marks.
    private static func isInvisible(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0A, 0x09: return false
        case 0x200B...0x200D, 0x2060, 0xFEFF, 0x200E...0x200F, 0x202A...0x202E, 0x2066...0x2069: return true
        default: return scalar.properties.generalCategory == .control
        }
    }

    /// Nil when nothing a reader could see is left, so the app never sends what the relay would call blank.
    private static func text(_ s: String) -> String? {
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: s.unicodeScalars.filter { !isInvisible($0) })
        return String(visible).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : s
    }

    /// The relay refuses a submission with no words in it; a rating alone is not feedback.
    public var hasText: Bool { good != nil || bad != nil }

    /// The submission as a person would read it, for the clipboard and the fallback link.
    public var plainText: String {
        var sections: [String] = []
        if let good { sections.append("What’s working well?\n\(good)") }
        if let bad { sections.append("What gets in your way?\n\(bad)") }
        if let rating { sections.append("Rating: \(rating)/5") }
        sections.append("Shellforge \(version), macOS \(macos)")
        return sections.joined(separator: "\n\n")
    }
}
