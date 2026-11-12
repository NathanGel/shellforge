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
        for alias in ["web-*", "web?", "!web", "web box", "-web", "web\u{7}"] {
            #expect(SSHConfigAppender.problem(with: host(alias: alias), existing: [])
                == "A host name can’t contain spaces, *, ?, ! or start with -.", "\(alias)")
        }
    }

    @Test func anEmptyHostNameIsAProblem() {
        #expect(SSHConfigAppender.problem(with: host(hostName: " "), existing: []) == "Give the host’s address.")
    }

    @Test func aLineBreakOrDoubleQuoteIsAProblem() {
        for bad in [host(user: "deploy\nHost evil"), host(identityFile: "~/.ssh/\"key\""), host(hostName: "a\rb"), host(alias: "sta\nging")] {
            #expect(SSHConfigAppender.problem(with: bad, existing: []) == "Fields can’t contain line breaks or double quotes.")
        }
    }

    @Test func aBadPortIsAProblem() {
        for port in ["0", "65536", "22a", "-1", "+22", "2 2"] {
            #expect(SSHConfigAppender.problem(with: host(port: port), existing: []) == "The port is a number from 1 to 65535.", "\(port)")
        }
        #expect(SSHConfigAppender.problem(with: staging, existing: []) == nil)
        #expect(SSHConfigAppender.problem(with: host(port: "65535"), existing: []) == nil)
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
}
