import Foundation

/// A program whose current directory is in a folder: what keeps writing into a worktree a removal
/// couldn't delete — a dev server, a file watcher.
public struct FolderUser: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public init(pid: Int32, name: String) { self.pid = pid; self.name = name }
}

/// Which programs hold a folder: those whose current directory is the folder or inside it.
public enum FolderUsers {
    /// One `lsof -a -d cwd -F pcn` — every process's current directory, never `lsof +D`, which
    /// walks the whole tree — read for the folder. Shellforge itself is left out. Empty on any
    /// failure: who holds the folder is a hint, never a reason for the removal to fail differently.
    public static func processes(using folder: String, launcher: CommandLauncher,
                                 lsof: String = "/usr/sbin/lsof") -> [FolderUser] {
        // lsof names the real path. `resolvingSymlinksInPath` would turn `/private/var` back into
        // `/var`, where every temporary folder lives.
        guard let real = realpath(folder, nil) else { return [] }
        let resolved = String(cString: real)
        free(real)
        // lsof exits 1 when some process could not be read, with the rest still on stdout.
        guard let out = try? launcher.run(lsof, ["-a", "-d", "cwd", "-F", "pcn"], timeout: 10) else { return [] }
        return parse(out.stdout, folder: resolved, excluding: getpid())
    }

    /// lsof's field output: `p<pid>` opens each process, `c<name>` names it, `n<path>` is its
    /// current directory. Anything else is passed over.
    static func parse(_ output: String, folder: String, excluding ownPid: Int32) -> [FolderUser] {
        var users: [FolderUser] = []
        var pid: Int32?, name = "?"
        for line in output.split(separator: "\n") {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            switch field {
            case "p":
                pid = Int32(value); name = "?"
            case "c":
                name = value
            case "n":
                guard let current = pid, current != ownPid, value == folder || value.hasPrefix(folder + "/") else { continue }
                users.append(FolderUser(pid: current, name: name))
                // One directory per process: a second `n` must not list it twice.
                pid = nil
            default:
                continue
            }
        }
        return users
    }

    /// `node (4211), nuxt (4230)`.
    public static func describe(_ users: [FolderUser]) -> String {
        users.map { "\($0.name) (\($0.pid))" }.joined(separator: ", ")
    }
}
