import Foundation
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore

/// Add Host: one block appended to the config after a backup, the old bytes left exactly as they
/// were. Every test has its own temporary home; the real `~/.ssh` is never read or written.
@Suite struct SSHConfigAppenderTests {
    let home: URL
    let ssh: URL
    let config: URL
    let source: SSHConfigSource
    let staging = NewSSHHost(alias: "staging", hostName: "staging.example.com", user: "deploy", port: "2222", identityFile: "~/.ssh/id_ed25519")

    init() throws {
        home = TestScratch.root.appendingPathComponent("ssh-append-\(UUID().uuidString)")
        ssh = home.appendingPathComponent(".ssh")
        config = ssh.appendingPathComponent("config")
        source = SSHConfigSource(file: config, home: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    private func write(_ text: String, to url: URL? = nil) throws {
        let url = url ?? config
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private var backup: URL { ssh.appendingPathComponent("config.shellforge-backup") }

    private func mode(_ url: URL) throws -> Int {
        try (FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func host(alias: String = "staging", hostName: String = "staging.example.com", user: String = "",
                      port: String = "", identityFile: String = "") -> NewSSHHost {
        NewSSHHost(alias: alias, hostName: hostName, user: user, port: port, identityFile: identityFile)
    }

    // MARK: The block

    @Test func theBlockHasTheGivenFields() {
        #expect(SSHConfigAppender.block(for: staging) == """
        Host staging
            HostName staging.example.com
            User deploy
            Port 2222
            IdentityFile ~/.ssh/id_ed25519

        """)
    }

    @Test func optionalFieldsAreLeftOut() {
        #expect(SSHConfigAppender.block(for: host(alias: " staging ", hostName: " staging.example.com ", user: "  ")) == """
        Host staging
            HostName staging.example.com

        """)
    }

    @Test func anIdentityFileWithSpacesIsQuoted() {
        let block = SSHConfigAppender.block(for: host(identityFile: "~/My Keys/id_ed25519"))
        #expect(block.contains("    IdentityFile \"~/My Keys/id_ed25519\"\n"))
    }

    // MARK: Problems

    @Test func anEmptyAliasIsAProblem() {
        #expect(SSHConfigAppender.problem(with: host(alias: "  "), existing: []) == "Give the host a name.")
    }

    @Test func aTakenAliasIsAProblem() {
        let existing = [SSHHost(alias: "staging", forwards: [])]
        #expect(SSHConfigAppender.problem(with: host(), existing: existing) == "“staging” is already in your SSH config.")
    }

    @Test func aBadAliasIsAProblem() {
        for alias in ["web-*", "web?", "!web", "web box", "-web", "web\u{7}", "it's", "#web", "sta\nging", "web\\", "café"] {
            #expect(SSHConfigAppender.problem(with: host(alias: alias), existing: [])
                == "A host name can use letters, digits, dots, dashes and underscores.", "\(alias)")
        }
        #expect(SSHConfigAppender.problem(with: host(alias: "build_box.2-a"), existing: []) == nil)
    }

    @Test func anEmptyHostNameIsAProblem() {
        #expect(SSHConfigAppender.problem(with: host(hostName: " "), existing: []) == "Give the host’s address.")
    }

    @Test func aBadAddressIsAProblem() {
        for hostName in ["#web", "staging example.com", "a\tb", "a\rb", "o'brien.example.com", "a\"b", "a\\b", "staging.example.com\u{A0}x"] {
            #expect(SSHConfigAppender.problem(with: host(hostName: hostName), existing: [])
                == "The address can use letters, digits, dots, dashes and colons.", "\(hostName)")
        }
        for hostName in ["10.0.0.5", "fe80::1%en0", "staging_2.example.com"] {
            #expect(SSHConfigAppender.problem(with: host(hostName: hostName), existing: []) == nil, "\(hostName)")
        }
    }

    @Test func aBadUserIsAProblem() {
        for user in ["o'brien", "de ploy", "de\tploy", "deploy\nHost evil", "#deploy", "de\\ploy", "\"deploy\""] {
            #expect(SSHConfigAppender.problem(with: host(user: user), existing: [])
                == "The user name can use letters, digits, dots, dashes, underscores and @.", "\(user)")
        }
        #expect(SSHConfigAppender.problem(with: host(user: "deploy.bot_1-a@example.com"), existing: []) == nil)
    }

    @Test func aBadIdentityFileIsAProblem() {
        for path in ["~/My Keys/k\\", "~/.ssh/\"key\"", "~/keys/it's", "~/keys/#1", "~/keys/a\tb", "~/keys/a\nb", "~/keys/a\u{2028}b"] {
            #expect(SSHConfigAppender.problem(with: host(identityFile: path), existing: [])
                == "The identity file’s path can’t contain quotes, backslashes, # or line breaks.", "\(path)")
        }
        #expect(SSHConfigAppender.problem(with: host(identityFile: "~/My Keys/id_ed25519"), existing: []) == nil)
    }

    @Test func aBadPortIsAProblem() {
        for port in ["0", "65536", "22a", "-1", "+22", "2 2", "٢٢"] {
            #expect(SSHConfigAppender.problem(with: host(port: port), existing: []) == "The port is a number from 1 to 65535.", "\(port)")
        }
        #expect(SSHConfigAppender.problem(with: staging, existing: []) == nil)
        #expect(SSHConfigAppender.problem(with: host(port: "65535"), existing: []) == nil)
    }

    @Test func aPercentInTheAddressIsWrittenDoubled() {
        #expect(SSHConfigAppender.block(for: host(hostName: "fe80::1%en0")).contains("    HostName fe80::1%%en0\n"))
    }

    // MARK: Appending

    @Test func theOldBytesStayAPrefix() throws {
        let old = """
        Host *
            ServerAliveInterval 30
        Match host *.internal
            User admin
        Host build-box
            HostName build.example.com

        """
        try write(old)
        let result = try SSHConfigAppender.append(staging, to: source)
        let now = try Data(contentsOf: config)
        #expect(now == Data((old + "\n" + SSHConfigAppender.block(for: staging)).utf8))
        #expect(now.starts(with: Data(old.utf8)))
        #expect(result == AppendResult(backup: backup, created: false))
        #expect(SSHConfig.hosts(in: config, home: home).map(\.alias) == ["build-box", "staging"])
    }

    @Test func aFileWithoutTrailingNewlineGetsOne() throws {
        let old = "Host build-box\n    HostName build.example.com"
        try write(old)
        try SSHConfigAppender.append(staging, to: source)
        #expect(try String(contentsOf: config, encoding: .utf8) == old + "\n\n" + SSHConfigAppender.block(for: staging))
    }

    @Test func theBackupIsTheOldFile() throws {
        let old = "Host build-box\n    HostName build.example.com\n"
        try write(old)
        try write("an older backup\n", to: backup)
        try SSHConfigAppender.append(staging, to: source)
        #expect(try Data(contentsOf: backup) == Data(old.utf8))
    }

    @Test func aMissingConfigIsCreatedPrivately() throws {
        let result = try SSHConfigAppender.append(staging, to: source)
        #expect(result == AppendResult(backup: nil, created: true))
        #expect(try mode(ssh) == 0o700)
        #expect(try mode(config) == 0o600)
        #expect(try String(contentsOf: config, encoding: .utf8) == SSHConfigAppender.block(for: staging))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func aSymlinkedConfigIsAppendedThroughTheLink() throws {
        let target = home.appendingPathComponent("dotfiles/ssh_config")
        let old = "Host build-box\n    HostName build.example.com\n"
        try write(old, to: target)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        let result = try SSHConfigAppender.append(staging, to: source)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == target.path)
        #expect(try String(contentsOf: target, encoding: .utf8) == old + "\n" + SSHConfigAppender.block(for: staging))
        #expect(result.backup == backup)
        #expect(try Data(contentsOf: backup) == Data(old.utf8))
    }

    @Test func anAliasFromAnIncludeIsTaken() throws {
        let old = "Include conf.d/*\nHost build-box\n    HostName build.example.com\n"
        try write(old)
        try write("Host staging\n    HostName other.example.com\n", to: ssh.appendingPathComponent("conf.d/work"))
        #expect(throws: SSHConfigAppendError.refused("“staging” is already in your SSH config.")) {
            try SSHConfigAppender.append(staging, to: source)
        }
        #expect(try Data(contentsOf: config) == Data(old.utf8))
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test func theFileModeIsKept() throws {
        try write("Host build-box\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        try SSHConfigAppender.append(staging, to: source)
        #expect(try mode(config) == 0o644)
    }

    @Test func theCacheSeesTheNewHost() throws {
        try write("Host build-box\n    HostName build.example.com\n")
        let cache = SSHConfigCache()
        #expect(cache.hosts(in: config, home: home).map(\.alias) == ["build-box"])
        try SSHConfigAppender.append(staging, to: source)
        #expect(cache.hosts(in: config, home: home).map(\.alias) == ["build-box", "staging"])
    }

    // MARK: Failures leave the config as it was

    private func errorText(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch { return error.localizedDescription }
    }

    @Test func aFailedBackupAppendsNothing() throws {
        let old = "Host build-box\n    HostName build.example.com\n"
        try write(old)
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        #expect {
            try SSHConfigAppender.append(staging, to: source)
        } throws: { error in
            if case .backupFailed = error as? SSHConfigAppendError { return true }
            return false
        }
        #expect(try Data(contentsOf: config) == Data(old.utf8))
    }

    /// A write that gets part of the way and fails, as a full disk would.
    private func shortWrite(_ descriptor: Int32, _ data: Data) throws {
        try SSHConfigAppender.writeAll(descriptor, data.prefix(7))
        throw POSIXError(.ENOSPC)
    }

    @Test func aFailedWriteIsCutBackToTheOldBytes() throws {
        let old = "Host build-box\n    HostName build.example.com\n"
        try write(old)
        var seams = SSHConfigAppender.Seams()
        seams.write = shortWrite
        #expect {
            try SSHConfigAppender.append(staging, to: source, seams: seams)
        } throws: { error in
            if case .writeFailed = error as? SSHConfigAppendError { return true }
            return false
        }
        #expect(try Data(contentsOf: config) == Data(old.utf8))
    }

    @Test func aWriteThatCannotBeUndoneNamesTheBackup() throws {
        let old = "Host build-box\n    HostName build.example.com\n"
        try write(old)
        var seams = SSHConfigAppender.Seams()
        seams.write = shortWrite
        seams.truncate = { _, _ in -1 }
        #expect(errorText { try SSHConfigAppender.append(staging, to: source, seams: seams) }
            == "The host couldn’t be added to your SSH config, and it may be damaged. Your previous config is in config.shellforge-backup.")
        #expect(try Data(contentsOf: backup) == Data(old.utf8))
    }

    @Test func aConfigChangedAfterTheBackupIsLeftAlone() throws {
        let old = "Host build-box\n    HostName build.example.com\n"
        let changed = old + "Host db-tunnel\n"
        try write(old)
        let config = config
        var seams = SSHConfigAppender.Seams()
        seams.afterBackup = { try? Data(changed.utf8).write(to: config) }
        #expect(throws: SSHConfigAppendError.changedWhileAdding) { try SSHConfigAppender.append(staging, to: source, seams: seams) }
        #expect(SSHConfigAppendError.changedWhileAdding.localizedDescription == "Your SSH config changed while adding the host. Try again.")
        #expect(try Data(contentsOf: config) == Data(changed.utf8))
    }

    @Test func aBrokenLinkIsRefused() throws {
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let missing = home.appendingPathComponent("dotfiles/ssh_config")
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: missing)
        #expect(errorText { try SSHConfigAppender.append(staging, to: source) }
            == "~/.ssh/config is a link to a file that doesn’t exist. Fix the link, then add the host.")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == missing.path)
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    // MARK: More shapes of config

    @Test func aRelativeSymlinkIsAppendedThroughTheLink() throws {
        let target = home.appendingPathComponent("dotfiles/ssh_config")
        let old = "Host build-box\n    HostName build.example.com\n"
        try write(old, to: target)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: config.path, withDestinationPath: "../dotfiles/ssh_config")
        try SSHConfigAppender.append(staging, to: source)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == "../dotfiles/ssh_config")
        #expect(try String(contentsOf: target, encoding: .utf8) == old + "\n" + SSHConfigAppender.block(for: staging))
        #expect(try Data(contentsOf: backup) == Data(old.utf8))
    }

    @Test func anEmptyConfigGetsOneNewlineBeforeTheBlock() throws {
        try write("")
        let result = try SSHConfigAppender.append(staging, to: source)
        #expect(result == AppendResult(backup: backup, created: false))
        #expect(try String(contentsOf: config, encoding: .utf8) == "\n" + SSHConfigAppender.block(for: staging))
    }

    @Test func theBackupIsPrivate() throws {
        try write("Host build-box\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: config.path)
        try SSHConfigAppender.append(staging, to: source)
        #expect(try mode(backup) == 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: ssh.path).filter { $0.hasPrefix(".config.shellforge-backup") }
        #expect(leftovers.isEmpty)
    }

    @Test func aHalfWrittenNewConfigIsRemoved() throws {
        var seams = SSHConfigAppender.Seams()
        seams.write = shortWrite
        #expect {
            try SSHConfigAppender.append(staging, to: source, seams: seams)
        } throws: { error in
            if case .writeFailed = error as? SSHConfigAppendError { return true }
            return false
        }
        #expect(!FileManager.default.fileExists(atPath: config.path))
    }

    @Test func aChangeThroughALinkIsCaught() throws {
        let target = home.appendingPathComponent("dotfiles/ssh_config")
        let old = "Host build-box\n    HostName build.example.com\n"
        let changed = old + "Host db-tunnel\n"
        try write(old, to: target)
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        var seams = SSHConfigAppender.Seams()
        seams.afterBackup = { try? Data(changed.utf8).write(to: target) }
        #expect(throws: SSHConfigAppendError.changedWhileAdding) { try SSHConfigAppender.append(staging, to: source, seams: seams) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: config.path) == target.path)
        #expect(try Data(contentsOf: target) == Data(changed.utf8))
    }

    @Test func aLeftoverTemporaryBackupIsRemoved() throws {
        try write("Host build-box\n")
        let leftover = ssh.appendingPathComponent(SSHConfigAppender.temporaryBackupPrefix + "crashed")
        let folder = ssh.appendingPathComponent(SSHConfigAppender.temporaryBackupPrefix + "folder")
        let other = ssh.appendingPathComponent("config.shellforge-backup-notes")
        try write("old\n", to: leftover)
        try write("keep\n", to: other)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try SSHConfigAppender.append(staging, to: source)
        #expect(!FileManager.default.fileExists(atPath: leftover.path))
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(FileManager.default.fileExists(atPath: other.path))
    }

    // MARK: The safety net: ssh itself reads what was written

    /// `ssh -G` for `alias` against `config`: its settings, or nil when it refused the file. No
    /// connection is made; only the scratch config is read.
    private func sshSettings(_ alias: String, in config: URL) throws -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = ["-G", "-F", config.path, alias]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var settings: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let space = line.firstIndex(of: " ") else { continue }
            let key = String(line[..<space])
            if settings[key] == nil { settings[key] = String(line[line.index(after: space)...]) }
        }
        return settings
    }

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh")))
    func everyAcceptedHostIsReadableBySSH() throws {
        try write("Host *\n    ServerAliveInterval 30\nHost build-box\n    HostName build.example.com\n")
        let samples = [
            staging,
            NewSSHHost(alias: "db-tunnel", hostName: "fe80::1%en0", user: "deploy@example.com", port: "", identityFile: "~/My Keys/id_ed25519"),
            NewSSHHost(alias: "build_box.2", hostName: "10.0.0.5", user: "ci.bot_1-a", port: "65535", identityFile: "~/keys/build box"),
            NewSSHHost(alias: "Demo-Web", hostName: "acme-web.example.com"),
        ]
        for sample in samples {
            #expect(SSHConfigAppender.problem(with: sample, existing: SSHConfig.hosts(in: config, home: home)) == nil)
            try SSHConfigAppender.append(sample, to: source)
        }
        for sample in samples + [NewSSHHost(alias: "build-box", hostName: "build.example.com")] {
            let settings = try #require(try sshSettings(sample.alias, in: config), "\(sample.alias)")
            #expect(settings["hostname"] == sample.hostName, "\(sample.alias)")
            #expect(settings["port"] == (sample.port.isEmpty ? "22" : sample.port), "\(sample.alias)")
            if !sample.user.isEmpty { #expect(settings["user"] == sample.user, "\(sample.alias)") }
            if !sample.identityFile.isEmpty { #expect(settings["identityfile"] == sample.identityFile, "\(sample.alias)") }
        }
    }
}
