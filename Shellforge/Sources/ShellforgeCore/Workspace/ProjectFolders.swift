import Foundation

/// Turns a folder the user picked into a project: the repository it is in, named after its folder.
public enum ProjectFolders {
    public enum Refusal: Error, Equatable {
        /// git's own reason the folder is not in a repository.
        case notARepository(String)
        /// The repository is already a project, at this path.
        case alreadyAdded(String)
    }

    public static func project(at folder: String, in workspace: Workspace, launcher: CommandLauncher) throws -> Project {
        let out = try launcher.run("git", ["-C", folder, "rev-parse", "--show-toplevel"])
        guard out.status == 0 else { throw Refusal.notARepository(out.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        let top = URL(fileURLWithPath: out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)).resolvingSymlinksInPath().path
        if workspace.projects.contains(where: { URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path == top }) {
            throw Refusal.alreadyAdded(top)
        }
        return Project(name: URL(fileURLWithPath: top).lastPathComponent, path: top)
    }
}
