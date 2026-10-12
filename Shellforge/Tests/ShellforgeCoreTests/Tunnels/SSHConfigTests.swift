import Foundation
import Testing
@testable import ShellforgeCore

/// What Shellforge reads of `~/.ssh/config`: the concrete hosts that forward local ports, with
/// their ports. Config text comes from temporary files; the real one is never read.
@Suite struct SSHConfigTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("ssh-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent(".ssh"), withIntermediateDirectories: true)
    }

    private func write(_ text: String, to name: String = "config") throws -> URL {
        let url = home.appendingPathComponent(".ssh/" + name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test func aliasesWithForwardsAndTheirPorts() throws {
        let config = try write("""
        # staging
        Host db-staging
            HostName bastion.example.net
            LocalForward 5432 db.internal:5432
            LocalForward 127.0.0.1:6380 cache.internal:6379
        Host v6
            LocalForward [::1]:8080 web.internal:80
        Host plain
            HostName plain.example.net
        """)
        let hosts = SSHConfig.hosts(in: config, home: home)
        #expect(hosts.map(\.alias) == ["db-staging", "v6", "plain"])
        #expect(hosts[0].forwards == [
            LocalForward(bind: nil, localPort: 5432, remoteHost: "db.internal", remotePort: 5432),
            LocalForward(bind: "127.0.0.1", localPort: 6380, remoteHost: "cache.internal", remotePort: 6379),
        ])
        #expect(hosts[1].forwards == [LocalForward(bind: "::1", localPort: 8080, remoteHost: "web.internal", remotePort: 80)])
        #expect(hosts[2].forwards.isEmpty)
    }

    @Test func wildcardsAndMatchBlocksAreSkipped() throws {
        let config = try write("""
        Host *
            ServerAliveInterval 30
        Host web-? !web-x
            LocalForward 9000 a:9000
        Host real other
            LocalForward 7000 b:7000
        Match host foo
            LocalForward 7100 c:7100
        """)
        let hosts = SSHConfig.hosts(in: config, home: home)
        #expect(hosts.map(\.alias) == ["real", "other"])
        #expect(hosts.allSatisfy { $0.forwards == [LocalForward(bind: nil, localPort: 7000, remoteHost: "b", remotePort: 7000)] })
    }

    @Test func includeIsFollowedRelativeToDotSSHAndGlobbed() throws {
        _ = try write("Host one\n  LocalForward 1111 a:1\n", to: "config.d/one.conf")
        _ = try write("Host two\n  LocalForward 2222 b:2\n", to: "config.d/two.conf")
        let config = try write("Include config.d/*.conf\nHost three\n  LocalForward 3333 c:3\n")
        #expect(SSHConfig.hosts(in: config, home: home).map(\.alias) == ["one", "two", "three"])
    }

    @Test func keywordsAreCaseInsensitiveAndTakeEquals() throws {
        let config = try write("host Quoted\n  localforward=4444 \"d.internal:4\"\n")
        #expect(SSHConfig.hosts(in: config, home: home) == [
            SSHHost(alias: "Quoted", forwards: [LocalForward(bind: nil, localPort: 4444, remoteHost: "d.internal", remotePort: 4)])
        ])
    }

    @Test func aRepeatedHostMergesItsForwards() throws {
        let config = try write("Host x\n  LocalForward 1 a:1\nHost x\n  LocalForward 2 b:2\n")
        #expect(SSHConfig.hosts(in: config, home: home).map { $0.forwards.map(\.localPort) } == [[1, 2]])
    }

    @Test func aMissingFileHasNoHosts() {
        #expect(SSHConfig.hosts(in: home.appendingPathComponent(".ssh/nope"), home: home).isEmpty)
    }

    @Test func anIncludeLoopEnds() throws {
        let config = try write("Include config\nHost loop\n  LocalForward 5 a:5\n")
        #expect(SSHConfig.hosts(in: config, home: home).map(\.alias).first == "loop")
    }

    /// An alias is typed into a terminal — the tunnel's tab, the pane beside an agent — where a
    /// control character acts before the shell sees any quoting, and ssh reads a leading `-` as an
    /// option. Such an alias is never offered.
    @Test func anAliasATerminalWouldActOnIsNotAHost() throws {
        let config = try write("Host ok\nHost bad\u{15}touch${IFS}/tmp/x\nHost -oProxyCommand=x\nHost tab\u{7f}x\nHost also-ok\n")
        #expect(SSHConfig.hosts(in: config, home: home).map(\.alias) == ["ok", "also-ok"])
    }
}
