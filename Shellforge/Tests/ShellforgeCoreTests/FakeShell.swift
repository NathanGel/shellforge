import Foundation

/// A stand-in for the user's login shell: a script that sets what an rc file would, then runs the
/// command it is handed the way `zsh -l -i -c <command>` does. `body` runs first, as the rc files.
struct FakeShell {
    let directory: URL
    let path: String

    init(_ body: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("fakesh").path
        let script = "#!/bin/sh\nexport SHELL_ARGS=\"$1 $2 $3\"\n\(body)\nexec /bin/sh -c \"$4\"\n"
        try script.write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    }
}
