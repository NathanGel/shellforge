// Ported from AiTerm (app/Sources/AiTermCore/Updates/ReleaseFeed.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The build's update source, from its `ShellforgeUpdateFeed` Info.plist value: `github:<owner>/<repo>`.
/// AiTerm also reads `gitlab:<project URL>` with Settings' GitLab token; Shellforge's releases are
/// on GitHub, so that feed and its token are not ported.
public enum ReleaseFeed: Equatable, Sendable {
    case gitHub(owner: String, repo: String)

    /// The Info.plist key the feed is read from.
    public static let infoKey = "ShellforgeUpdateFeed"

    public init?(_ text: String) {
        guard text.hasPrefix("github:") else { return nil }
        var path = String(text.dropFirst("github:".count))
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.unicodeScalars.allSatisfy(allowed.contains) }) else { return nil }
        self = .gitHub(owner: String(parts[0]), repo: String(parts[1]))
    }

    /// A GitHub feed is public and takes no token.
    public func source(session: URLSession = .shared) -> any ReleaseSource {
        switch self {
        case .gitHub(let owner, let repo): return GitHubReleaseSource(owner: owner, repo: repo, session: session)
        }
    }

    /// `text` is the running bundle's feed value: `nil` in a bundle without one.
    public static func source(for text: String?, session: URLSession = .shared) throws -> any ReleaseSource {
        guard let text, let feed = ReleaseFeed(text) else { throw UpdateError.noFeed }
        return feed.source(session: session)
    }
}
