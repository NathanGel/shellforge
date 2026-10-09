import Foundation

/// `workspace.json` in Shellforge's Application Support folder. Each save first copies the
/// previous file to `workspace.json.backup`; a file that no longer decodes is kept aside as
/// `workspace.json.damaged-<uuid>` and the backup is loaded instead, so a crash mid-write
/// never costs the user their projects.
public struct WorkspaceStore: Sendable {
    public let folder: URL

    public init(folder: URL = WorkspaceStore.defaultFolder) {
        self.folder = folder
    }

    public static var defaultFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shellforge", isDirectory: true)
    }

    public struct Loaded: Equatable, Sendable {
        public var workspace: Workspace
        /// The damaged file kept aside, when the backup had to be loaded.
        public var recoveredFrom: String?
    }

    public enum Refusal: Error, Equatable {
        case duplicateId(UUID)
        case taskWithoutProject(UUID)
    }

    private var file: URL { folder.appendingPathComponent("workspace.json") }
    private var backup: URL { folder.appendingPathComponent("workspace.json.backup") }

    /// The saved workspace. With no `workspace.json` the backup is used, if there is one. A file
    /// that no longer decodes is kept aside and the backup written back as `workspace.json` at
    /// once, so the recovery lasts: the next launch, or another window, finds the projects too.
    /// Throws when the damaged file cannot be kept aside; nothing may be saved over it then.
    public func load() throws -> Loaded {
        guard let data = try? Data(contentsOf: file) else { return Loaded(workspace: fromBackup() ?? Workspace(), recoveredFrom: nil) }
        if let workspace = try? JSONDecoder.workspace.decode(Workspace.self, from: data) {
            return Loaded(workspace: workspace, recoveredFrom: nil)
        }
        let kept = "workspace.json.damaged-\(UUID().uuidString)"
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(kept))
        let recovered = fromBackup() ?? Workspace()
        try JSONEncoder.workspace.encode(recovered).write(to: file, options: .atomic)
        return Loaded(workspace: recovered, recoveredFrom: kept)
    }

    private func fromBackup() -> Workspace? {
        (try? Data(contentsOf: backup)).flatMap { try? JSONDecoder.workspace.decode(Workspace.self, from: $0) }
    }

    public func save(_ workspace: Workspace) throws {
        try check(workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            _ = try? FileManager.default.removeItem(at: backup)
            try FileManager.default.copyItem(at: file, to: backup)
        }
        try JSONEncoder.workspace.encode(workspace).write(to: file, options: .atomic)
    }

    private func check(_ workspace: Workspace) throws {
        var seen = Set<UUID>()
        for id in workspace.projects.map(\.id) + workspace.tasks.map(\.id) where !seen.insert(id).inserted {
            throw Refusal.duplicateId(id)
        }
        let projects = Set(workspace.projects.map(\.id))
        if let orphan = workspace.tasks.first(where: { !projects.contains($0.projectId) }) {
            throw Refusal.taskWithoutProject(orphan.id)
        }
    }
}
