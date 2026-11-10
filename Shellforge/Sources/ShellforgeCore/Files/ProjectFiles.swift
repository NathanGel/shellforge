import Foundation

/// What a project's Files panel lists: in a repository, what git sees (tracked files and untracked
/// ones git does not ignore); elsewhere, the folder itself, one level at a time. Task worktrees,
/// under `.worktrees/`, are never listed. Every function blocks on the disk or on git and is safe
/// to call from any thread: callers run them off the main actor.
public enum ProjectFiles {
    public enum Listing: Equatable, Sendable {
        /// Every path git lists, relative to the project; `FileTree.build` makes the tree.
        case git([String])
        /// Not a repository: the folder's top level, its folders not yet loaded.
        case folder([FileNode])
        case missing
        /// The folder could not be read; the reason is the system's.
        case unreadable(String)
    }

    /// The folder task worktrees live in, under the project.
    static let worktrees = ".worktrees"

    public static func list(_ projectPath: String, launcher: CommandLauncher) -> Listing {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        if let paths = gitPaths(projectPath, launcher: launcher) { return .git(paths) }
        do {
            return .folder(try entries(of: "", in: projectPath))
        } catch {
            return .unreadable(error.localizedDescription)
        }
    }

    /// One folder's entries, for a folder that is not in a repository, its folders not yet
    /// loaded; nothing when it cannot be read. `folder` is relative to the project ("" for its top).
    public static func children(of folder: String, in projectPath: String) -> [FileNode] {
        (try? entries(of: folder, in: projectPath)) ?? []
    }

    /// What `git ls-files` lists, or nil when the folder is not a repository or git cannot run.
    /// `-z` separates paths with NUL and quotes none, so names with spaces or newlines survive.
    private static func gitPaths(_ projectPath: String, launcher: CommandLauncher) -> [String]? {
        guard let out = try? launcher.run("git", ["-C", projectPath, "ls-files", "--cached", "--others",
                                                  "--exclude-standard", "-z"]),
              out.status == 0 else { return nil }
        let prefix = worktrees + "/"
        return out.stdout.split(separator: "\0").compactMap { path in
            path == worktrees || path.hasPrefix(prefix) ? nil : String(path)
        }
    }

    /// A folder's entries without the dot ones (`.worktrees` among them), folders first.
    private static func entries(of folder: String, in projectPath: String) throws -> [FileNode] {
        let base = URL(fileURLWithPath: projectPath).appendingPathComponent(folder)
        let names = try FileManager.default.contentsOfDirectory(atPath: base.path)
        let prefix = folder.isEmpty ? "" : folder + "/"
        let nodes = names.filter { !$0.hasPrefix(".") }.map { name in
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: base.appendingPathComponent(name).path, isDirectory: &isDirectory)
            return FileNode(name: name, path: prefix + name, isFolder: isDirectory.boolValue, children: nil)
        }
        return FileTree.sorted(nodes)
    }
}
