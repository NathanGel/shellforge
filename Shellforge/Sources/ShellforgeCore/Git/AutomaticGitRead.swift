import Foundation

/// A git read Shellforge makes on its own — a panel's refresh, a badge, a branch list, a count —
/// rather than one the person asked for. The repository's own configuration runs nothing there:
/// no `core.fsmonitor` command and no hook. A `.git` that came in an archive or on a shared drive
/// can name any command as its fsmonitor, and `git status` or `ls-files` would run it.
///
/// Explicit Commit, Push, Pull, Switch and New Task keep the person's hooks: they never use this.
public enum AutomaticGitRead {
    /// git's options for such a read, placed before the subcommand.
    public static let options = ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null"]

    /// `-C path`, the options, then `args`: what follows `git` for a read in `path`.
    public static func arguments(_ args: [String], in path: String) -> [String] { ["-C", path] + options + args }
}
