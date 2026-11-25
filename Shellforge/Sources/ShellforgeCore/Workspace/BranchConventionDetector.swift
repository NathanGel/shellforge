import Foundation

/// A branch-name pattern a repository follows, and where that was read: a file name, or
/// “existing branches”.
public struct BranchConvention: Equatable, Sendable {
    public let pattern: String
    public let source: String
    public init(pattern: String, source: String) { self.pattern = pattern; self.source = source }
}

/// Reads how a repository names its branches, for Branch Names to suggest: what its agent docs say,
/// else what most of its branches do. Only ever a suggestion; nothing changes until it is picked.
public enum BranchConventionDetector {
    /// The files whose words about branches count, in the order they are read.
    static let docs = ["AGENTS.md", "CLAUDE.md"]
    /// The fewest branches of one shape that make a convention, and the share of them it needs.
    static let minimumBranches = 5, majority = 0.6

    /// The docs first, then the branches. Runs git: call it off the main actor.
    public static func detect(in path: String, launcher: CommandLauncher) -> BranchConvention? {
        for doc in docs {
            if let text = try? String(contentsOfFile: path + "/" + doc, encoding: .utf8), let pattern = fromDocs(text) {
                return BranchConvention(pattern: pattern, source: doc)
            }
        }
        guard let out = try? launcher.run("git", ["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads", "refs/remotes/origin"]),
              out.status == 0 else { return nil }
        let names = Set(out.stdout.split(separator: "\n").map { line -> String in
            line.hasPrefix("origin/") ? String(line.dropFirst("origin/".count)) : String(line)
        }).subtracting(["origin", "HEAD"])
        return fromBranches(Array(names)).map { BranchConvention(pattern: $0, source: "existing branches") }
    }

    /// The first backticked example on a line about branches that maps to a pattern.
    public static func fromDocs(_ text: String) -> String? {
        for line in text.split(separator: "\n") where line.lowercased().contains("branch") {
            let pieces = line.split(separator: "`", omittingEmptySubsequences: false)
            // Odd pieces are inside backticks.
            for (i, piece) in pieces.enumerated() where i % 2 == 1 && i < pieces.count - 1 {
                if let pattern = pattern(ofExample: String(piece)) { return pattern }
            }
        }
        return nil
    }

    /// Long-lived branches, which say nothing about how work is named.
    static let mainlines: Set<String> = ["main", "master", "develop", "development", "trunk"]

    /// The pattern most branches follow, when at least `minimumBranches` do and they are a clear
    /// majority of the working branches: every branch but the mainlines, shaped or not.
    public static func fromBranches(_ names: [String]) -> String? {
        let working = names.filter { !mainlines.contains($0) }
        let counts = Dictionary(working.compactMap(pattern(ofExample:)).map { ($0, 1) }, uniquingKeysWith: +)
        guard let (top, count) = counts.max(by: { $0.value < $1.value }),
              count >= minimumBranches, Double(count) >= majority * Double(working.count) else { return nil }
        return top
    }

    /// The pattern one branch name follows: an optional prefix (a type, or a word such as
    /// `feature`), then a ticket key, then an optional slug. A type with only a slug is Type and
    /// Name. Anything else, such as `main`, follows none.
    public static func pattern(ofExample example: String) -> String? {
        var prefix = "", rest = Substring(example)
        if let slash = rest.firstIndex(of: "/") {
            let head = String(rest[..<slash])
            rest = rest[rest.index(after: slash)...]
            if BranchType(rawValue: head) != nil { prefix = "{type}/" }
            else if head.range(of: #"^[a-z][a-z0-9_-]*$"#, options: .regularExpression) != nil { prefix = head + "/" }
            else { return nil }
        }
        let slug = #"^[a-z0-9]+(-[a-z0-9]+)*$"#
        guard let key = rest.range(of: #"^[A-Za-z][A-Za-z0-9]*-[0-9]+"#, options: .regularExpression) else {
            return prefix == "{type}/" && rest.range(of: slug, options: .regularExpression) != nil ? BranchPattern.typeAndName : nil
        }
        let letters = rest[key].prefix { $0 != "-" }
        let token: String
        if letters == letters.uppercased() { token = "{KEY}" } else if letters == letters.lowercased() { token = "{key}" } else { return nil }
        let after = rest[key.upperBound...]
        let tail: String
        if after.isEmpty { tail = "" }
        else if after.hasPrefix("-"), after.dropFirst().range(of: slug, options: .regularExpression) != nil { tail = "-{slug}" }
        else { return nil }
        let pattern = prefix + token + tail
        // Type and Name drops a missing slug: `feat/abc-123` is its branch too.
        return pattern == "{type}/{key}" ? BranchPattern.typeAndName : pattern
    }
}
