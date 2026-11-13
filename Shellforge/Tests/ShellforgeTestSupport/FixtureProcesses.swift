import Foundation
import ShellforgeCore

/// Launching a test's fixture processes — the git that builds a scratch repository, a look at what
/// a test left behind — on a pool thread, never on the actor that awaits it.
///
/// Most UI suites run on the main actor, and `run` waits for its child where it is called. A spawn
/// costs little on an idle Mac, but on a loaded one each takes long enough that dozens of them in a
/// row hold the main actor for minutes, and every other main-actor test that polls with
/// `eventually` meanwhile runs out of time.
extension CommandLauncher {
    /// `run`, on a pool thread.
    public func runOffMain(_ command: String, _ arguments: [String]) async throws -> ChildOutput {
        try await BackgroundWork.run { try self.run(command, arguments) }
    }

    /// `git -C directory args`, on a pool thread: what it printed, trimmed, or a `GitFailure` when
    /// it did not succeed.
    @discardableResult
    public func fixtureGit(_ args: [String], in directory: String) async throws -> String {
        let out = try await runOffMain("git", ["-C", directory] + args)
        guard out.status == 0 else { throw GitFailure(command: "git " + args.joined(separator: " "), message: out.stderr) }
        return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
