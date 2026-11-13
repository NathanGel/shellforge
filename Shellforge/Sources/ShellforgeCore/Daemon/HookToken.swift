import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// The helper's per-user secret (`shellforged/hook_token.py`): one random token in `hook-token` in
/// the support folder, readable by its owner only. The app shows it to the helper to call the
/// app-only methods (`DaemonClient.hello`), and every hook Shellforge installs sends it to the hook
/// port, so another account on the Mac can neither post status events nor pass as the app.
///
/// The file holds the header line itself, `X-Shellforge-Token: <64 hex digits>`, so a curl command
/// sends it with `-H @<file>` and the token never appears in a command line, which `ps` shows to
/// every account. Whichever of the app and the helper comes first makes it, and the other reads it.
public enum HookToken {
    public static let fileName = "hook-token"
    public static let header = "X-Shellforge-Token"
    /// The longest file read: the line, and room for a stray byte that makes it invalid.
    private static let maximumBytes = 128

    public static func url(in support: ShellforgeSupport) -> URL { support.folder.appendingPathComponent(fileName) }

    /// The file's bytes for `token`.
    static func line(_ token: String) -> Data { Data("\(header): \(token)\n".utf8) }

    /// The token in `support`'s folder, or nil when there is none to trust: no file, a symlink,
    /// anything but a regular file of this user's that no one else may read, or anything but the line.
    public static func read(in support: ShellforgeSupport) -> String? {
        let fd = open(url(in: support).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: maximumBytes)
        let count = Darwin.read(fd, &buffer, maximumBytes)
        guard count > 0 else { return nil }
        return token(in: Data(buffer[0..<count]))
    }

    /// The token a file's bytes hold, or nil when they are not exactly the line.
    static func token(in data: Data) -> String? {
        guard var text = String(data: data, encoding: .utf8) else { return nil }
        if text.hasSuffix("\n") { text.removeLast() }
        let prefix = "\(header): "
        guard text.hasPrefix(prefix) else { return nil }
        let token = text.dropFirst(prefix.count)
        guard token.count == 64, token.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        return String(token)
    }

    /// The token in `support`'s folder, made first when there is none to trust: written whole to a
    /// private temporary file, then linked into place, which fails when another process made one
    /// first, whose token is used. A file that cannot be trusted is replaced, never read or followed.
    public static func readOrCreate(in support: ShellforgeSupport) throws -> String {
        if let token = read(in: support) { return token }
        try FileManager.default.createDirectory(at: support.folder, withIntermediateDirectories: true)
        let target = url(in: support)
        let temporary = support.folder.appendingPathComponent(".\(fileName).\(getpid()).\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: temporary.path]) }
        defer { unlink(temporary.path) }
        let bytes = line(randomToken())
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        fsync(fd)
        close(fd)
        guard written == bytes.count else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temporary.path]) }
        // link(2) never follows a link at `target`: that counts as a file already there.
        if link(temporary.path, target.path) != 0, errno == EEXIST, read(in: support) == nil {
            // rename(2) replaces a link or a bad file itself, never what a link names.
            guard rename(temporary.path, target.path) == 0 else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path])
            }
        }
        guard let token = read(in: support) else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: target.path]) }
        return token
    }

    private static func randomToken() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<32).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max, using: &generator)) }.joined()
    }
}
