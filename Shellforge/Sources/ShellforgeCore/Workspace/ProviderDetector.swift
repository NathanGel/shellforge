import Foundation

/// Which `Provider` a project's code lives on, from its `origin` remote: AiTerm's project rows draw
/// GitLab's tanuki, GitHub's mark, or plain git.
public enum ProviderDetector {
    /// github.com is GitHub; a host with "gitlab" in it is GitLab (gitlab.com and self-hosted ones);
    /// any other remote, or none, is plain git.
    public static func provider(ofRemote url: String) -> Provider {
        let host = Self.host(of: url.lowercased())
        if host == "github.com" || host.hasSuffix(".github.com") { return .github }
        if host.contains("gitlab") { return .gitlab }
        return .git
    }

    /// `git -C path remote get-url origin`, through the launcher (the login shell's environment).
    /// Blocks: call it off the main thread.
    public static func provider(ofRepositoryAt path: String, launcher: CommandLauncher) -> Provider {
        guard let git = launcher.locate("git"),
              let out = try? launcher.run(git, ["-C", path, "remote", "get-url", "origin"], timeout: 10),
              out.status == 0 else { return .git }
        return provider(ofRemote: out.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// The host of `https://host/…`, `ssh://user@host:port/…` or scp-like `user@host:path`.
    private static func host(of url: String) -> String {
        if let parsed = URL(string: url), let host = parsed.host { return host }
        guard let colon = url.firstIndex(of: ":") else { return "" }
        let authority = url[..<colon]
        return String(authority.split(separator: "@").last ?? "")
    }
}
