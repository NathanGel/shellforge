import Foundation

/// `workspace.json` in Shellforge's Application Support folder. Each save first copies the
/// previous file over `workspace.json.backup`, through a temporary copy renamed into place, so the
/// backup is never gone while its replacement is still being made; a file that no longer decodes is kept aside as
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
    /// Throws when the file is there but cannot be read (its permissions, a disk error), or when the
    /// damaged file cannot be kept aside; nothing may be saved over it then.
    public func load() throws -> Loaded {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch where Self.isMissing(error) {
            return Loaded(workspace: fromBackup() ?? Workspace(), recoveredFrom: nil)
        }
        if let workspace = try? JSONDecoder.workspace.decode(Workspace.self, from: data) {
            return Loaded(workspace: workspace, recoveredFrom: nil)
        }
        let kept = "workspace.json.damaged-\(UUID().uuidString)"
        try FileManager.default.moveItem(at: file, to: folder.appendingPathComponent(kept))
        let recovered = fromBackup() ?? Workspace()
        try JSONEncoder.workspace.encode(recovered).write(to: file, options: .atomic)
        return Loaded(workspace: recovered, recoveredFrom: kept)
    }

    /// Only a file that is not there counts as missing; any other failure to read it is an error.
    private static func isMissing(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError { return true }
        if error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT) { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? NSError).map(isMissing) ?? false
    }

    private func fromBackup() -> Workspace? {
        (try? Data(contentsOf: backup)).flatMap { try? JSONDecoder.workspace.decode(Workspace.self, from: $0) }
    }

    public func save(_ workspace: Workspace) throws {
        try check(workspace)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: file.path) {
            try replaceBackup()
        }
        try JSONEncoder.workspace.encode(workspace).write(to: file, options: .atomic)
    }

    /// Copies `workspace.json` to a temporary file beside the backup and renames it over the backup,
    /// which replaces it in one step: when the copy fails, the old backup is still there.
    private func replaceBackup() throws {
        let temporary = folder.appendingPathComponent("workspace.json.backup-\(UUID().uuidString).tmp")
        do {
            try FileManager.default.copyItem(at: file, to: temporary)
            guard rename(temporary.path, backup.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } catch {
            _ = try? FileManager.default.removeItem(at: temporary)
            throw error
        }
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
