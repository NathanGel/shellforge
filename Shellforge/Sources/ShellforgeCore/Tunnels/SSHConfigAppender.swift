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
    public var trimmed: NewSSHHost {
        let trim: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        return NewSSHHost(alias: trim(alias), hostName: trim(hostName), user: trim(user), port: trim(port), identityFile: trim(identityFile))
    }
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
    /// Nothing was added; the config is as it was.
    case writeFailed(String)
    /// A write failed part-way and could not be undone: the config may end in half a line.
    case damaged
    /// The config grew or shrank between its backup and the append, so nothing was added.
    case changedWhileAdding
    /// The config is a symlink to nothing.
    case brokenLink

    public var errorDescription: String? {
        switch self {
        case .refused(let problem): return problem
        case .backupFailed(let reason): return "Your SSH config couldn’t be backed up, so nothing was added. \(reason)"
        case .writeFailed(let reason): return "The host couldn’t be added to your SSH config. \(reason)"
        case .damaged:
            return "The host couldn’t be added to your SSH config, and it may be damaged. Your previous config is in \(SSHConfigAppender.backupName)."
        case .changedWhileAdding: return "Your SSH config changed while adding the host. Try again."
        case .brokenLink: return "~/.ssh/config is a link to a file that doesn’t exist. Fix the link, then add the host."
        }
    }
}

/// Add Host: one `Host` block appended to the config. The file is never rewritten — it is copied
/// byte for byte to `config.shellforge-backup` beside it first, then opened for appending only, so
/// its old bytes stay an exact prefix and its mode is untouched. Through a symlink, the link's
/// target grows and the link stays. No backup, no write.
///
/// Appends in this process run one at a time, so two windows adding the same alias at once add it
/// once. Another program can still change the config between the check and the append. A change
/// to its size after the backup is caught and refused; one before it (say, the same alias added
/// elsewhere a moment earlier) is not, and ssh then uses the first of the two blocks. Nor is a new
/// config renamed over the path after it was opened: the block then goes to the replaced file, and
/// the append still reports success.
public enum SSHConfigAppender {
    static let backupName = "config.shellforge-backup"

    /// What is wrong with `host`, or nil when it can be added. `existing` is every host the config
    /// already reads, `Include`s too. Each field is checked against what it may hold, not against
    /// what it may not: ssh refuses the whole config — every host, not just this one — over a
    /// stray quote, backslash or `#`, so only characters known to be safe get through.
    public static func problem(with host: NewSSHHost, existing: [SSHHost]) -> String? {
        let host = host.trimmed
        if host.alias.isEmpty { return "Give the host a name." }
        if !only(host.alias, "._-") || host.alias.hasPrefix("-") {
            return "A host name can use letters, digits, dots, dashes and underscores."
        }
        // OpenSSH matches `Host` patterns case-sensitively, but two hosts differing only in case are
        // easy to confuse, so Shellforge refuses the twin.
        let alias = host.alias.lowercased()
        if existing.contains(where: { $0.alias.lowercased() == alias }) { return "“\(host.alias)” is already in your SSH config." }
        if host.hostName.isEmpty { return "Give the host’s address." }
        // `:` and `%` for an IPv6 address and its zone.
        // A leading `-` could read as an option where a `ProxyCommand` expands `%h` or `%r`.
        if !only(host.hostName, ".-_:%") || host.hostName.hasPrefix("-") {
            return "The address can use letters, digits, dots, dashes, underscores, colons and %."
        }
        if !only(host.user, "._-@") || host.user.hasPrefix("-") { return "The user name can use letters, digits, dots, dashes, underscores and @." }
        if !host.port.isEmpty {
            guard only(host.port, ""), host.port.allSatisfy(\.isNumber),
                  let port = Int(host.port), (1...65535).contains(port) else { return "The port is a number from 1 to 65535." }
        }
        let unsafeInPath = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "'\"\\#"))
        // ssh expands `${NAME}` in IdentityFile from the environment; `%` is written `%%` instead.
        if host.identityFile.contains(where: \.isNewline) || host.identityFile.unicodeScalars.contains(where: unsafeInPath.contains)
            || host.identityFile.contains("${") {
            return "The identity file’s path can’t contain quotes, backslashes, #, ${ or line breaks."
        }
        return nil
    }

    /// Whether `text` is only ASCII letters, ASCII digits and the characters in `extra`.
    private static func only(_ text: String, _ extra: String) -> Bool {
        text.unicodeScalars.allSatisfy { scalar in
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
                || extra.unicodeScalars.contains(scalar)
        }
    }

    /// The block for `host`, four-space indented, each line ending in a newline. An IdentityFile
    /// with a space is quoted. A `%` in HostName — an IPv6 zone — or in IdentityFile is written
    /// `%%`, which ssh reads as a plain `%` rather than the start of a token, so the path is used
    /// as typed.
    public static func block(for host: NewSSHHost) -> String {
        let host = host.trimmed
        let identityFile = host.identityFile.replacingOccurrences(of: "%", with: "%%")
        let identity = identityFile.contains(" ") ? "\"\(identityFile)\"" : identityFile
        let hostName = host.hostName.replacingOccurrences(of: "%", with: "%%")
        let lines = [("HostName", hostName), ("User", host.user), ("Port", host.port), ("IdentityFile", identity)]
            .filter { !$0.1.isEmpty }
            .map { "    \($0.0) \($0.1)\n" }
        return "Host \(host.alias)\n" + lines.joined()
    }

    /// The steps a test replaces to force a failure the file system won't give on demand.
    struct Seams {
        /// Writes all of the data to the descriptor, or throws.
        var write: (Int32, Data) throws -> Void = SSHConfigAppender.writeAll
        /// `ftruncate`.
        var truncate: (Int32, off_t) -> Int32 = { ftruncate($0, $1) }
        /// Runs after the backup, before the config is opened for appending.
        var afterBackup: () -> Void = {}
    }

    /// Appends `host` to `source.file`, after reading the hosts again and refusing one with a
    /// problem. A missing `~/.ssh` is made `0700` and a missing config `0600`, holding the block.
    @discardableResult
    public static func append(_ host: NewSSHHost, to source: SSHConfigSource) throws -> AppendResult {
        try append(host, to: source, seams: Seams())
    }

    /// Held for a whole append: one at a time in this process, so the check against the file and
    /// the write that follows it are not interleaved with another window's.
    private static let lock = NSLock()

    @discardableResult
    static func append(_ host: NewSSHHost, to source: SSHConfigSource, seams: Seams) throws -> AppendResult {
        lock.lock()
        defer { lock.unlock() }
        if let problem = problem(with: host, existing: SSHConfig.hosts(in: source.file, home: source.home)) {
            throw SSHConfigAppendError.refused(problem)
        }
        let block = block(for: host)
        let folder = source.file.deletingLastPathComponent()
        let target = source.file.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: target.path) else {
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: source.file.path)) != nil {
                throw SSHConfigAppendError.brokenLink
            }
            try create(source.file, in: folder, holding: block, seams: seams)
            return AppendResult(backup: nil, created: true)
        }

        let backup = folder.appendingPathComponent(backupName)
        removeLeftoverBackups(in: folder)
        let old: Data
        do {
            old = try Data(contentsOf: target)
            try writeBackup(old, to: backup)
            guard try Data(contentsOf: backup) == old else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            throw SSHConfigAppendError.backupFailed(error.localizedDescription)
        }
        seams.afterBackup()

        let descriptor = open(target.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else { throw lastPOSIXError }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let error = lastPOSIXError
            close(descriptor)
            throw error
        }
        let size = info.st_size
        guard size == off_t(old.count) else {
            close(descriptor)
            throw SSHConfigAppendError.changedWhileAdding
        }
        let separator = old.isEmpty || old.last == UInt8(ascii: "\n") ? "\n" : "\n\n"
        do {
            try seams.write(descriptor, Data((separator + block).utf8))
        } catch {
            // Cut the file back to exactly its old bytes, so no half line is left behind.
            let undone = seams.truncate(descriptor, size) == 0
            close(descriptor)
            throw undone ? SSHConfigAppendError.writeFailed(error.localizedDescription) : SSHConfigAppendError.damaged
        }
        closeAfterWriting(descriptor, target)
        return AppendResult(backup: backup, created: false)
    }

    /// Temporary backups a crash left between writing and renaming one: `.config.shellforge-backup.*`
    /// in the config's own folder, nothing else.
    private static func removeLeftoverBackups(in folder: URL) {
        let prefix = temporaryBackupPrefix
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder.path) else { return }
        for name in names where name.hasPrefix(prefix) {
            let path = folder.appendingPathComponent(name).path
            // Only a file Shellforge could have left: never a folder or a link someone put there.
            guard (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeRegular else { continue }
            unlink(path)
        }
    }

    static let temporaryBackupPrefix = ".\(backupName)."

    /// `old` at `backup`, made `0600` from the start in a file beside it and renamed over any older
    /// backup.
    private static func writeBackup(_ old: Data, to backup: URL) throws {
        let temporary = backup.deletingLastPathComponent().appendingPathComponent(temporaryBackupPrefix + UUID().uuidString)
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw posixError }
        do {
            fchmod(descriptor, 0o600)
            try writeAll(descriptor, old)
            guard fsync(descriptor) == 0 else { throw posixError }
        } catch {
            close(descriptor)
            unlink(temporary.path)
            throw error
        }
        guard close(descriptor) == 0, rename(temporary.path, backup.path) == 0 else {
            let error = posixError
            unlink(temporary.path)
            throw error
        }
    }

    /// The failure a system call just reported.
    private static var posixError: POSIXError { POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

    private static var lastPOSIXError: SSHConfigAppendError { .writeFailed(posixError.localizedDescription) }

    /// Writes every byte of `data`, retrying short writes and interrupted calls.
    static func writeAll(_ descriptor: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError
                }
                // A regular file never takes nothing; looping on it would never end.
                if written == 0 { throw POSIXError(.EIO) }
                offset += written
            }
        }
    }

    /// Closes a file every byte was written to. A failure here doesn't undo the write — the host
    /// was added — so it is logged, not reported.
    private static func closeAfterWriting(_ descriptor: Int32, _ file: URL) {
        if close(descriptor) != 0 { ErrorLogging.record("ssh", "Closing \(file.path) after adding a host failed: \(posixError)") }
    }

    /// A new config holding only `block`: the folder made `0700` if it is missing, the file `0600`,
    /// and never over a file — or a link — already there.
    private static func create(_ file: URL, in folder: URL, holding block: String, seams: Seams) throws {
        do {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        } catch {
            throw SSHConfigAppendError.writeFailed(error.localizedDescription)
        }
        let descriptor = open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw lastPOSIXError }
        fchmod(descriptor, 0o600)
        do {
            try seams.write(descriptor, Data(block.utf8))
        } catch {
            // The file is new and Shellforge's own: a half-written one is removed.
            close(descriptor)
            unlink(file.path)
            throw SSHConfigAppendError.writeFailed(error.localizedDescription)
        }
        closeAfterWriting(descriptor, file)
    }
}
