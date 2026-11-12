import Foundation

/// What a project's Files panel lists: in a repository, what git sees (tracked files still on disk
/// and untracked ones git does not ignore); elsewhere, the folder itself, one level at a time. Task
/// worktrees, under `.worktrees/`, are never listed. Every function blocks on the disk or on git
/// and is safe to call from any thread: callers run them off the main actor.
public enum ProjectFiles {
    public enum Listing: Equatable, Sendable {
        /// Every path git lists, relative to the project; `FileTree.build` makes the tree. A
        /// submodule, or an untracked nested repository, ends in "/": a folder with nothing in it.
        /// `submodules` names the submodules among them, without the "/".
        case git([String], submodules: Set<String> = [])
        /// Not a repository: the folder's top level, its folders not yet loaded.
        case folder([FileNode])
        case missing
        /// The folder, or git, could not be read; the reason is the system's or git's.
        case unreadable(String)
    }

    /// The folder task worktrees live in, under the project.
    static let worktrees = ".worktrees"
    /// A gitlink's mode in the index: a submodule.
    static let submoduleMode = "160000"
    static let gitTimeout: TimeInterval = 30

    public static func list(_ projectPath: String, launcher: CommandLauncher) -> Listing {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: projectPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .missing
        }
        do {
            let listed = try gitPaths(projectPath, launcher: launcher)
            return .git(listed.paths, submodules: listed.submodules)
        } catch GitListingProblem.failed(let reason) {
            return .unreadable(reason)
        } catch {
            // Not a repository: the folder as it is.
        }
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

    // -- git -----------------------------------------------------------------------------

    private enum GitListingProblem: Error {
        /// Not a repository, or git could not be launched at all (no Command Line Tools): either
        /// way the folder is listed as it is.
        case notARepository
        case failed(String)
    }

    /// The index's paths still on disk, then the untracked ones git does not ignore, without the
    /// task worktrees. `-z` separates paths with NUL and quotes none, so names with spaces or
    /// newlines survive. (git's output is read as UTF-8: a name that is not, rare on APFS, comes
    /// back with replacement characters.)
    private static func gitPaths(_ projectPath: String, launcher: CommandLauncher) throws -> (paths: [String], submodules: Set<String>) {
        // `--stage`: "<mode> <sha> <stage>\t<path>", so a submodule can be told by its mode. A
        // conflicted path is listed once per stage.
        let deleted = Set(try git(["ls-files", "--deleted"], in: projectPath, launcher: launcher))
        var seen = Set<String>()
        var submodules = Set<String>()
        let cached = try git(["ls-files", "--cached", "--stage"], in: projectPath, launcher: launcher).compactMap { entry -> String? in
            guard let tab = entry.firstIndex(of: "\t") else { return nil }
            let path = String(entry[entry.index(after: tab)...])
            guard !deleted.contains(path), seen.insert(path).inserted else { return nil }
            guard entry.hasPrefix(submoduleMode + " ") else { return path }
            submodules.insert(path)
            return path + "/"
        }
        let others = try git(["ls-files", "--others", "--exclude-standard"], in: projectPath, launcher: launcher)
        let prefix = worktrees + "/"
        let paths = (cached + others).filter { $0 != worktrees && !$0.hasPrefix(prefix) }
        return (paths, submodules.filter { $0 != worktrees && !$0.hasPrefix(prefix) })
    }

    /// `git -C projectPath args -z`, its NUL-separated entries. git speaks English (`LC_ALL=C`)
    /// so "not a git repository" can be told from every other refusal, which is never hidden. A
    /// git that cannot be launched at all, or macOS's `/usr/bin/git` stub without the Command Line
    /// Tools (it runs, then xcrun refuses), lists the folder as it is: without git there is no
    /// repository to show.
    private static func git(_ args: [String], in projectPath: String, launcher: CommandLauncher) throws -> [String] {
        let out: ChildOutput
        do {
            out = try launcher.run("git", ["-C", projectPath] + args + ["-z"], extra: ["LC_ALL": "C"], timeout: gitTimeout)
        } catch {
            throw GitListingProblem.notARepository
        }
        if out.timedOut { throw GitListingProblem.failed("git timed out") }
        guard out.status == 0 else {
            if out.stderr.contains("not a git repository") || out.stderr.contains(noDeveloperTools) {
                throw GitListingProblem.notARepository
            }
            throw GitListingProblem.failed("git: " + firstLine(out.stderr))
        }
        return out.stdout.split(separator: "\0").map(String.init)
    }

    /// What `/usr/bin/git` says through xcrun when the Command Line Tools are not installed.
    static let noDeveloperTools = "xcrun: error: invalid active developer path"

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? text
    }

    // -- a plain folder ------------------------------------------------------------------

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
