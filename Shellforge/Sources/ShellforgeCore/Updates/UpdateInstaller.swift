// Ported from AiTerm (app/Sources/AiTermCore/Updates/UpdateInstaller.swift), GPLv3, Laurens D'Hondt.
import Foundation
import os

let updatesLog = Logger(subsystem: "io.github.nathangel.shellforge", category: "updates")

/// Replaces the running app with a staged one. A running bundle cannot replace itself, so a small
/// zsh helper does it: started detached, it waits for Shellforge to quit, moves the old app aside
/// to `Updates/previous/`, moves the new one into the same place and opens it. If the new one
/// cannot move in, the old one goes back and is opened instead. If Shellforge never quits — its
/// quit was cancelled — the helper gives up and nothing changes. Either way it writes its exit
/// status to `Updates/result` before opening anything, and the next launch reports a failure from
/// it before deleting `Updates/`: the helper runs after Shellforge has quit, so there is no one
/// else to tell.
public enum UpdateInstaller {
    /// The helper moves the installed bundle aside and the new one into its place, which needs
    /// write access to the folder holding it and to the bundle itself (moving a directory rewrites
    /// its `..`). Without it the first `mv` fails after Shellforge has already quit and the old
    /// version just reopens, so this is asked before anything is downloaded.
    public static func checkReplaceable(_ installed: URL) throws {
        let fm = FileManager.default, folder = installed.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path), fm.isWritableFile(atPath: installed.path) else {
            throw UpdateError.cannotReplace(folder.path)
        }
    }

    /// Starts the helper and returns at once; `onExit` hears its exit status, if this process is
    /// still there to hear it.
    @discardableResult
    public static func launch(staged: URL, installed: URL, updates: URL, pid: Int32,
                              timeout: Int = 60, opener: String = "/usr/bin/open",
                              environment: [String: String] = ProcessInfo.processInfo.environment,
                              onExit: @escaping @Sendable (Int32) -> Void = { _ in }) throws -> RunningChild {
        do {
            try FileManager.default.createDirectory(at: updates, withIntermediateDirectories: true)
            let helper = updates.appendingPathComponent("install-update.sh")
            try Data(script.utf8).write(to: helper)
            let result = resultURL(in: updates)
            if FileManager.default.fileExists(atPath: result.path) { try FileManager.default.removeItem(at: result) }
            // `-f`: none of the user's zsh startup files, which can print, fail or stall.
            return try ChildProcess.launch("/bin/zsh", ["-f", helper.path, String(pid), staged.path, installed.path,
                                                        updates.appendingPathComponent("previous/Shellforge.app").path,
                                                        String(timeout), opener, result.path],
                                           environment: withoutLaunchIdentity(environment), directory: nil, output: nil,
                                           onExit: { _, status in onExit(status) })
        } catch {
            throw UpdateError.installFailed(error.localizedDescription)
        }
    }

    /// `environment` without what makes a child pass for this app (`__CFBundleIdentifier`,
    /// `XPC_*`) or for an agent's child (`InheritedEnvironment`'s markers): the version the helper
    /// opens is a launch of its own.
    static func withoutLaunchIdentity(_ environment: [String: String]) -> [String: String] {
        environment.filter { key, _ in
            key != "__CFBundleIdentifier" && !key.hasPrefix("XPC_") && !key.hasPrefix("__XPC_") && !InheritedEnvironment.markers.contains(key)
        }
    }

    /// The last helper's exit status: 0 installed, 1 Shellforge never quit, 2 the old app could not
    /// be moved aside, 3 the new one could not move in (the old one was put back). `nil` when no
    /// helper ran since `Updates/` was last cleared. Taken, not just read: the file goes at once,
    /// so a cleanup of `Updates/` that stops partway cannot report the same failure again.
    public static func takePreviousResult(in updates: URL) -> Int32? {
        let url = resultURL(in: updates)
        // None is the usual answer: no helper ran.
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        // Left behind, the same failure would be reported at the next launch.
        attempt("Removing the install helper's result") { try FileManager.default.removeItem(at: url) }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func resultURL(in updates: URL) -> URL { updates.appendingPathComponent("result") }

    public static func removeLeftovers(in updates: URL) {
        guard FileManager.default.fileExists(atPath: updates.path) else { return }
        attempt("Removing the last update's leftovers") { try FileManager.default.removeItem(at: updates) }
    }

    private static func attempt(_ what: String, _ body: () throws -> Void) {
        do { try body() } catch {
            updatesLog.error("\(what, privacy: .public) failed: \(String(describing: error), privacy: .public)")
        }
    }

    static let script = #"""
    #!/bin/zsh
    # Shellforge's update helper. Arguments: <pid> <staged app> <installed app> <previous app> <timeout s> <opener> <result file>
    pid=$1 staged=$2 installed=$3 previous=$4 timeout=$5 opener=$6 result=$7
    # The status goes to <result file> before anything opens: the app that opens reads it on launch.
    finish() {
        print -r -- "$1" > "$result"
        (( $1 == 1 )) || "$opener" "$installed"
        exit "$1"
    }
    for (( i = 0; i < timeout * 10; i++ )); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
    kill -0 "$pid" 2>/dev/null && finish 1
    rm -rf "$previous"
    mkdir -p "${previous:h}"
    mv "$installed" "$previous" || finish 2
    if ! mv "$staged" "$installed"; then
        mv "$previous" "$installed"
        finish 3
    fi
    finish 0
    """#
}
