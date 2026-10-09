import Foundation

/// A git command that exited non-zero, with git's own words.
public struct GitFailure: Error, CustomStringConvertible, Equatable {
    public var command: String
    public var message: String
    public var description: String { "\(command) failed: \(message.trimmingCharacters(in: .whitespacesAndNewlines))" }
}

/// Makes a task's checkout: `<project>/.worktrees/<slug>` on a new branch `<slug>` from the base.
/// git runs through `CommandLauncher`, so the repository's hooks see the login shell's `PATH`.
public enum TaskWorktrees {
    /// Lowercase ASCII letters and digits, runs of anything else as one `-`; "task" when nothing is left.
    public static func slug(for title: String) -> String {
        let folded = title.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = "", dash = false
        for scalar in folded.unicodeScalars {
            if scalar.isASCII, CharacterSet.alphanumerics.contains(scalar) {
                if dash, !slug.isEmpty { slug.append("-") }
                slug.unicodeScalars.append(scalar)
                dash = false
            } else {
                dash = true
            }
        }
        return slug.isEmpty ? "task" : slug.lowercased()
    }

    public static func create(title: String, in project: Project, base: String?, launcher: CommandLauncher) throws -> TaskItem {
        func git(_ args: [String]) throws -> String {
            let out = try launcher.run("git", ["-C", project.path] + args)
            guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
            return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let base = try base ?? git(["rev-parse", "--abbrev-ref", "HEAD"])
        let root = "\(project.path)/.worktrees"
        let stem = slug(for: title)
        var name = stem, n = 1
        while FileManager.default.fileExists(atPath: "\(root)/\(name)")
                || (try? git(["rev-parse", "--verify", "--quiet", "refs/heads/\(name)"])) != nil {
            n += 1
            name = "\(stem)-\(n)"
        }
        try exclude(".worktrees/", gitDir: git(["rev-parse", "--git-common-dir"]), project: project)
        _ = try git(["worktree", "add", "-q", "-b", name, "\(root)/\(name)", base])
        return TaskItem(projectId: project.id, title: title, branch: name, worktreePath: "\(root)/\(name)", baseBranch: base)
    }

    /// Adds `pattern` to the repository's `info/exclude` once, so the worktrees never show as untracked.
    private static func exclude(_ pattern: String, gitDir: String, project: Project) throws {
        let dir = gitDir.hasPrefix("/") ? gitDir : "\(project.path)/\(gitDir)"
        let file = "\(dir)/info/exclude"
        try FileManager.default.createDirectory(atPath: "\(dir)/info", withIntermediateDirectories: true)
        let current = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !current.components(separatedBy: "\n").contains(pattern) else { return }
        let joiner = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try (current + joiner + pattern + "\n").write(toFile: file, atomically: true, encoding: .utf8)
    }
}
