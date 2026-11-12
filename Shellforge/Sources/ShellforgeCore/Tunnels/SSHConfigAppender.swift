import Foundation

/// A host to add to `~/.ssh/config`, as the Add Host sheet has it. An empty field is one not given;
/// every field is trimmed before it is checked or written.
public struct NewSSHHost: Equatable, Sendable {
    public var alias: String
    public var hostName: String
    public var user: String
    public var port: String
    public var identityFile: String

    public init(alias: String, hostName: String, user: String = "", port: String = "", identityFile: String = "") {
        self.alias = alias; self.hostName = hostName; self.user = user; self.port = port; self.identityFile = identityFile
    }

    /// The same host with every field trimmed.
    var trimmed: NewSSHHost {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        return NewSSHHost(alias: trim(alias), hostName: trim(hostName), user: trim(user), port: trim(port), identityFile: trim(identityFile))
    }

    var fields: [String] { [alias, hostName, user, port, identityFile] }
}

/// What `SSHConfigAppender.append` did: where the old file was copied to (nil when there was no
/// file), and whether the config was created.
public struct AppendResult: Equatable, Sendable {
    public var backup: URL?
    public var created: Bool
    public init(backup: URL?, created: Bool) { self.backup = backup; self.created = created }
}

/// Why a host was not added, in words to show.
public enum SSHConfigAppendError: Error, Equatable, LocalizedError {
    /// The host itself is wrong: `SSHConfigAppender.problem`'s words.
    case refused(String)
    /// The old config could not be copied aside, so nothing was written.
    case backupFailed(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .refused(let problem): return problem
        case .backupFailed(let reason): return "Your SSH config couldn’t be backed up, so nothing was added. \(reason)"
        case .writeFailed(let reason): return "The host couldn’t be added to your SSH config. \(reason)"
        }
    }
}

/// Add Host: one `Host` block appended to the config. The file is never rewritten — it is copied
/// byte for byte to `config.shellforge-backup` beside it first, then opened for appending only, so
/// its old bytes stay an exact prefix and its mode is untouched. Through a symlink, the link's
/// target grows and the link stays. No backup, no write.
public enum SSHConfigAppender {
    static let backupName = "config.shellforge-backup"

    /// What is wrong with `host`, or nil when it can be added. `existing` is every host the config
    /// already reads, `Include`s too.
    public static func problem(with host: NewSSHHost, existing: [SSHHost]) -> String? {
        let host = host.trimmed
        if host.alias.isEmpty { return "Give the host a name." }
        if host.fields.contains(where: { $0.contains(where: { $0.isNewline || $0 == "\"" }) }) {
            return "Fields can’t contain line breaks or double quotes."
        }
        if host.alias.contains(where: { "*?!".contains($0) }) || !SSHConfig.isTypable(host.alias) {
            return "A host name can’t contain spaces, *, ?, ! or start with -."
        }
        // ssh matches a destination against `Host` patterns without regard to case.
        let alias = host.alias.lowercased()
        if existing.contains(where: { $0.alias.lowercased() == alias }) { return "“\(host.alias)” is already in your SSH config." }
        if host.hostName.isEmpty { return "Give the host’s address." }
        if !host.port.isEmpty {
            guard host.port.allSatisfy(\.isASCII), host.port.allSatisfy(\.isNumber),
                  let port = Int(host.port), (1...65535).contains(port) else { return "The port is a number from 1 to 65535." }
        }
        return nil
    }

    /// The block for `host`, four-space indented, each line ending in a newline; an IdentityFile
    /// with a space is quoted.
    public static func block(for host: NewSSHHost) -> String {
        let host = host.trimmed
        let identity = host.identityFile.contains(" ") ? "\"\(host.identityFile)\"" : host.identityFile
        let lines = [("HostName", host.hostName), ("User", host.user), ("Port", host.port), ("IdentityFile", identity)]
            .filter { !$0.1.isEmpty }
            .map { "    \($0.0) \($0.1)\n" }
        return "Host \(host.alias)\n" + lines.joined()
    }

    /// Appends `host` to `source.file`, after reading the hosts again and refusing one with a
    /// problem. A missing `~/.ssh` is made `0700` and a missing config `0600`, holding the block.
    @discardableResult
    public static func append(_ host: NewSSHHost, to source: SSHConfigSource) throws -> AppendResult {
        if let problem = problem(with: host, existing: SSHConfig.hosts(in: source.file, home: source.home)) {
            throw SSHConfigAppendError.refused(problem)
        }
        let block = block(for: host)
        let folder = source.file.deletingLastPathComponent()
        let target = source.file.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else {
            try create(source.file, in: folder, holding: block)
            return AppendResult(backup: nil, created: true)
        }

        let backup = folder.appendingPathComponent(backupName)
        let old: Data
        do {
            old = try Data(contentsOf: target)
            try old.write(to: backup, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backup.path)
            guard try Data(contentsOf: backup) == old else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            throw SSHConfigAppendError.backupFailed(error.localizedDescription)
        }

        let separator = old.isEmpty || old.last == UInt8(ascii: "\n") ? "\n" : "\n\n"
        let descriptor = open(target.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else { throw lastPOSIXError }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data((separator + block).utf8))
            try handle.close()
        } catch {
            throw SSHConfigAppendError.writeFailed(error.localizedDescription)
        }
        return AppendResult(backup: backup, created: false)
    }

    /// The failure `open` just reported.
    private static var lastPOSIXError: SSHConfigAppendError { .writeFailed(String(cString: strerror(errno))) }

    /// A new config holding only `block`: the folder made `0700` if it is missing, the file `0600`,
    /// and never over a file — or a link — already there.
    private static func create(_ file: URL, in folder: URL, holding block: String) throws {
        do {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw SSHConfigAppendError.writeFailed(error.localizedDescription)
        }
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw lastPOSIXError }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            fchmod(descriptor, 0o600)
            try handle.write(contentsOf: Data(block.utf8))
            try handle.close()
        } catch {
            throw SSHConfigAppendError.writeFailed(error.localizedDescription)
        }
    }
}
