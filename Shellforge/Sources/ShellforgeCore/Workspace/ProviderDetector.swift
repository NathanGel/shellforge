// Ported from AiTerm (app/Sources/AiTermCore/Git/ProviderDetector.swift), GPLv3, Laurens D'Hondt.
import Foundation

public struct RemoteInfo: Equatable, Sendable {
    public var host: String?
    public var path: String
    public var provider: Provider
}

public enum ProviderDetector {
    public static func detect(remoteUrl raw: String?, repoPath: String? = nil) -> RemoteInfo {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else {
            return RemoteInfo(host: nil, path: "", provider: repoPath.map { looksLikeGitLabCheckout($0) ? .gitlab : .git } ?? .none)
        }
        while s.hasSuffix("/") { s.removeLast() }
        var host: String? = nil, path = s
        if let range = s.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*://"#, options: .regularExpression) {
            var rest = String(s[range.upperBound...])
            if let at = rest.lastIndex(of: "@"), !rest[..<at].contains("/") { rest = String(rest[rest.index(after: at)...]) }
            let slash = rest.firstIndex(of: "/") ?? rest.endIndex
            var hostPort = String(rest[..<slash])
            if let colon = hostPort.lastIndex(of: ":") { hostPort = String(hostPort[..<colon]) }
            host = hostPort.isEmpty ? nil : hostPort.lowercased()
            path = slash < rest.endIndex ? String(rest[rest.index(after: slash)...]) : ""
        } else if let colon = s.firstIndex(of: ":"), !s[..<colon].contains("/") {   // scp-like
            var hostPart = String(s[..<colon])
            if let at = hostPart.lastIndex(of: "@") { hostPart = String(hostPart[hostPart.index(after: at)...]) }
            host = hostPart.lowercased()
            path = String(s[s.index(after: colon)...])
        }
        while path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        while path.hasSuffix("/") { path.removeLast() }
        path = path.removingPercentEncoding ?? path
        return RemoteInfo(host: host, path: path, provider: classify(host: host, path: path, repoPath: repoPath))
    }

    static func classify(host: String?, path: String, repoPath: String?) -> Provider {
        // github.com first: its paths never have subgroups, and a mirror's `.gitlab-ci.yml` does
        // not make it GitLab's. `ssh.github.com` is git over SSH on port 443.
        if let host, host == "github.com" || host == "ssh.github.com" { return .github }
        // Hosts known not to be GitLab, before the heuristics below take them for it: a `git.` name
        // (SourceHut, kernel.org) or a deep path (Azure DevOps: `org/project/_git/repo`).
        if let host, isKnownNotGitLab(host) { return .git }
        if let host, host == "gitlab.com" || host.hasPrefix("git.") || host.hasPrefix("gitlab.") { return .gitlab }
        // The subgroup rule only applies when the remote actually has a host; a
        // host-less (local filesystem) remote never classifies as GitLab by path shape.
        if host != nil, path.split(separator: "/").count > 2 { return .gitlab }
        if let repoPath, looksLikeGitLabCheckout(repoPath) { return .gitlab }
        return .git
    }

    private static let notGitLab: Set<String> = ["dev.azure.com", "ssh.dev.azure.com", "bitbucket.org", "codeberg.org",
                                                 "git.sr.ht", "git.kernel.org", "git.savannah.gnu.org"]

    private static func isKnownNotGitLab(_ host: String) -> Bool {
        notGitLab.contains(host) || host.hasSuffix(".visualstudio.com")
    }

    static func looksLikeGitLabCheckout(_ repoPath: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: repoPath + "/.gitlab-ci.yml") || fm.fileExists(atPath: repoPath + "/.gitlab")
    }
}

extension ProviderDetector {
    /// `git -C path remote get-url origin`, through the launcher (the login shell's environment),
    /// classified as AiTerm classifies it. Blocks: call it off the main thread.
    public static func provider(ofRepositoryAt path: String, launcher: CommandLauncher) -> Provider {
        guard let git = launcher.locate("git"),
              let out = try? launcher.run(git, ["-C", path, "remote", "get-url", "origin"], timeout: 10),
              out.status == 0 else { return detect(remoteUrl: nil, repoPath: path).provider }
        return detect(remoteUrl: out.stdout, repoPath: path).provider
    }
}
