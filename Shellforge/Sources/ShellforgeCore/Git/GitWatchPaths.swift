import Foundation

/// Which changes under a repository can change what the Git panel shows. Unlike the Files panel's
/// filter (`FolderWatcher.isRelevant`), refs count: a fetch or a commit moves ahead and behind.
public enum GitWatchPaths {
    /// The files directly in `.git/` that decide the branch, the index and a merge in progress.
    private static let gitFiles: Set<String> = ["index", "HEAD", "ORIG_HEAD", "MERGE_HEAD", "packed-refs"]
    /// Where refs live: loose ones, or a reftable repository's tables.
    private static let refFolders: Set<String> = ["refs", "reftable"]
    /// What a task worktree's own folder in `.git/worktrees/<name>/` keeps that the panel shows.
    private static let worktreeFiles: Set<String> = ["index", "HEAD"]

    /// Whether a change at `path` can change the panel. Inside `.git/`, only `gitFiles`, `refs/…`,
    /// `reftable/…` and `worktrees/<name>/{index,HEAD}`; lock files, objects and logs never. A
    /// change reported for `.git` or `.git/refs` itself (the stream naming a folder to rescan)
    /// counts. Outside it,
    /// everything except task worktrees (`.worktrees/`, which their own watchers cover) and a
    /// nested repository's git folder. `root` is the watched folder as the stream reports it.
    public static func isRelevant(_ path: String, root: String) -> Bool {
        guard let parts = parts(path, root: root) else { return true }
        guard parts.first == ".git" else {
            return parts.first != ".worktrees" && !parts.contains(".git")
        }
        let inside = Array(parts.dropFirst())
        guard let first = inside.first, let last = inside.last else { return true }
        guard !last.hasSuffix(".lock") else { return false }
        if refFolders.contains(first) { return true }
        if inside.count == 1 { return gitFiles.contains(first) }
        return first == "worktrees" && inside.count == 3 && worktreeFiles.contains(inside[2])
    }

    /// The task worktree a change inside the main repository's `.git/worktrees/<name>/` is for:
    /// `<name>`, from a path relative to the repository's folder. Nil for any other path.
    public static func worktreeName(_ relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts[0] == ".git", parts[1] == "worktrees" else { return nil }
        return parts[2]
    }

    /// Whether a change, relative to the repository's folder, is to what every worktree shares:
    /// the refs (a fetch or a push moves ahead and behind), `packed-refs`, `HEAD`, or `.git` as a
    /// whole.
    public static func isShared(_ relativePath: String) -> Bool {
        let parts = relativePath.split(separator: "/").map(String.init)
        guard parts.first == ".git" else { return false }
        guard parts.count > 1 else { return true }
        return refFolders.contains(parts[1]) || (parts.count == 2 && ["packed-refs", "HEAD"].contains(parts[1]))
    }

    /// `path`'s components under `root`; nil when it is not under it.
    private static func parts(_ path: String, root: String) -> [String]? {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        guard path == base || path.hasPrefix(base + "/") else { return nil }
        return path.dropFirst(base.count).split(separator: "/").map(String.init)
    }
}
