// Ported from AiTerm (app/Sources/AiTermCore/CodeHost.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// The service a release, a merge request or a pull request lives on, as copy names it. GitLab is
/// every host that is not github.com: it is the only other one Shellforge reads.
public enum CodeHost: String, Sendable, Equatable {
    case gitLab = "GitLab", gitHub = "GitHub"

    public var name: String { rawValue }

    /// Judged by the web URL a merge or pull request was stored with, so a saved review needs no
    /// field of its own to say where it came from.
    public init(webURL: String) {
        self = URL(string: webURL)?.host?.lowercased() == "github.com" ? .gitHub : .gitLab
    }

    /// How the host writes a request's number: GitLab `!87`, GitHub `#87`.
    public func reference(_ number: Int) -> String { (self == .gitHub ? "#" : "!") + String(number) }
}

/// A merge request (GitLab) or pull request (GitHub), as either host's client reads it.
public struct MergeRequest: Equatable, Sendable, Identifiable {
    public var iid: Int, title: String, sourceBranch: String, targetBranch: String
    public var author: String?, state: String, draft: Bool, url: String
    /// `owner:branch` when the branch lives in a fork rather than on origin, which is where a
    /// review checks out from. Only GitHub reports it.
    public var forkHead: String?
    public var id: Int { iid }
    public init(iid: Int, title: String, sourceBranch: String, targetBranch: String,
                author: String?, state: String, draft: Bool, url: String, forkHead: String? = nil) {
        self.iid = iid; self.title = title; self.sourceBranch = sourceBranch; self.targetBranch = targetBranch
        self.author = author; self.state = state; self.draft = draft; self.url = url; self.forkHead = forkHead
    }

    /// The lane a picked merge or pull request shows beside its title.
    public var lane: String { forkHead != nil ? "Fork" : draft ? "Draft" : state.capitalized }
    public var host: CodeHost { CodeHost(webURL: url) }
    /// `!87` for GitLab, `#87` for GitHub.
    public var reference: String { host.reference(iid) }
}
