import Foundation

/// One entry of a project's file tree: a file, or a folder and what it holds.
public struct FileNode: Equatable, Sendable, Identifiable {
    public var name: String
    /// Relative to the project, "/"-separated.
    public var path: String
    public var isFolder: Bool
    /// Nil for a file, and for a folder listed lazily that has not been loaded yet.
    public var children: [FileNode]?
    public var id: String { path }

    public init(name: String, path: String, isFolder: Bool, children: [FileNode]?) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
        self.children = children
    }
}

/// Builds the tree the Files panel shows from a flat list of relative paths, as git lists them.
public enum FileTree {
    /// Folders before files, each group in Finder's order (`folder2` before `folder10`). The
    /// folders on the way to a path are made from it; a path ending in "/" is a folder with
    /// nothing listed in it (git's untracked nested repository). Safe to call from any thread.
    public static func build(_ paths: [String]) -> [FileNode] {
        let root = Folder()
        for path in paths {
            let isFolder = path.hasSuffix("/")
            let parts = path.split(separator: "/")
            guard let last = parts.last else { continue }
            var folder = root
            for part in parts.dropLast() { folder = folder.folder(String(part)) }
            if isFolder { _ = folder.folder(String(last)) } else { folder.files.insert(String(last)) }
        }
        return root.nodes(prefix: "")
    }

    /// Folders first, then files, each sorted as Finder sorts names.
    static func sorted(_ nodes: [FileNode]) -> [FileNode] {
        nodes.sorted { a, b in
            if a.isFolder != b.isFolder { return a.isFolder }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// A folder being filled while the paths are read: a reference, so a path's folders are
    /// found and filled in place rather than copied.
    private final class Folder {
        var folders: [String: Folder] = [:]
        var files: Set<String> = []

        func folder(_ name: String) -> Folder {
            if let existing = folders[name] { return existing }
            let made = Folder()
            folders[name] = made
            return made
        }

        func nodes(prefix: String) -> [FileNode] {
            let folderNodes = folders.map { name, folder in
                let path = prefix + name
                return FileNode(name: name, path: path, isFolder: true, children: folder.nodes(prefix: path + "/"))
            }
            let fileNodes = files.subtracting(folders.keys).map {
                FileNode(name: $0, path: prefix + $0, isFolder: false, children: nil)
            }
            return FileTree.sorted(folderNodes + fileNodes)
        }
    }
}
