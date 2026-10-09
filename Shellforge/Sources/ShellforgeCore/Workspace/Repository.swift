// Ported from AiTerm (app/Sources/AiTermCore/Git/Repository.swift), GPLv3, Laurens D'Hondt.
import Foundation

/// What the New Task sheet asks a project's repository, through the login shell's git.
public enum Repository {
    public static let fallbackDefaultBranch = "main"

    /// AiTerm's rule: origin's HEAD while it still names a branch, else whichever of origin's or the
    /// local `main`/`master` exists, origin's first; `main` when none does or git cannot be asked.
    public static func defaultBranch(of path: String, launcher: CommandLauncher) -> String {
        let prefix = "refs/remotes/origin/"
        let usual = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"]
        guard let out = try? launcher.run("git", ["-C", path, "for-each-ref", "--format=%(refname) %(symref)", prefix + "HEAD"] + usual),
              out.status == 0 else { return fallbackDefaultBranch }
        var existing = Set<String>(), originHead: String?
        for line in out.stdout.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            existing.insert(String(fields[0]))
            if fields[0] == prefix + "HEAD", fields.count == 2, fields[1].hasPrefix(prefix) { originHead = String(fields[1]) }
        }
        if let originHead { return String(originHead.dropFirst(prefix.count)) }
        return usual.first(where: existing.contains).map { String($0.split(separator: "/").last!) } ?? fallbackDefaultBranch
    }

    /// The default branch first, then local branches newest first, then branches only on origin.
    public static func branches(of path: String, launcher: CommandLauncher) -> [String] {
        let listing = (try? launcher.run("git", ["-C", path, "for-each-ref", "--format=%(refname)", "--sort=-committerdate",
                                                "refs/heads", "refs/remotes/origin"]))
            .flatMap { $0.status == 0 ? $0.stdout : nil }?
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } ?? []
        let locals = listing.compactMap { $0.hasPrefix("refs/heads/") ? String($0.dropFirst("refs/heads/".count)) : nil }
        let remotes = listing.compactMap { ref -> String? in
            guard ref.hasPrefix("refs/remotes/origin/") else { return nil }
            let name = String(ref.dropFirst("refs/remotes/origin/".count))
            return name == "HEAD" ? nil : name
        }
        var out: [String] = [], seen = Set<String>()
        for name in [defaultBranch(of: path, launcher: launcher)] + locals + remotes where seen.insert(name).inserted { out.append(name) }
        return out
    }
}
