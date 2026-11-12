import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct SSHPanelLayoutTests {
    private func project(_ name: String, host: String? = nil, tunnels: [String] = []) -> Project {
        var p = Project(name: name, path: "/tmp/\(name)")
        p.sshHost = host
        p.tunnels = tunnels.map { TunnelDefinition(alias: $0) }
        return p
    }
    private func hosts(_ aliases: String...) -> [SSHHost] { aliases.map { SSHHost(alias: $0, forwards: []) } }

    @Test func projectsKeepTheirOrder() {
        let b = project("demo", host: "staging"), a = project("acme-web", host: "build-box")
        let s = SSHPanelLayout.sections(projects: [b, a], hosts: hosts("staging", "build-box"))
        #expect(s.map(\.title) == ["demo", "acme-web"])
        #expect(s.map(\.id) == ["project:\(b.id.uuidString)", "project:\(a.id.uuidString)"])
    }

    @Test func aHostThatIsAlsoATunnelShowsOnce() {
        let p = project("demo", host: "staging", tunnels: ["staging", "db-tunnel"])
        let s = SSHPanelLayout.sections(projects: [p], hosts: hosts("staging", "db-tunnel"))
        #expect(s[0].entries == [
            SSHPanelEntry(alias: "staging", isProjectHost: true, isTunnel: true, inConfig: true),
            SSHPanelEntry(alias: "db-tunnel", isProjectHost: false, isTunnel: true, inConfig: true),
        ])
    }

    @Test func aProjectWithoutHostsHasNoSection() {
        #expect(SSHPanelLayout.sections(projects: [project("demo")], hosts: []).isEmpty)
    }

    @Test func otherHostsAreTheRestSorted() {
        let p = project("demo", host: "staging")
        let s = SSHPanelLayout.sections(projects: [p], hosts: hosts("build-box", "Zeta", "staging", "alpha"))
        #expect(s.last?.kind == .other)
        #expect(s.last?.id == "other")
        #expect(s.last?.entries.map(\.alias) == ["alpha", "build-box", "Zeta"])
    }

    @Test func aNamedHostMissingFromTheConfigIsMarked() {
        let p = project("demo", host: "staging", tunnels: ["db-tunnel"])
        let s = SSHPanelLayout.sections(projects: [p], hosts: hosts("db-tunnel"))
        #expect(s[0].entries.map(\.inConfig) == [false, true])
    }

    @Test func beforeTheConfigIsReadNothingIsMissing() {
        let p = project("demo", host: "staging", tunnels: ["db-tunnel"])
        let s = SSHPanelLayout.sections(projects: [p], hosts: nil)
        #expect(s.count == 1)
        #expect(s[0].entries.allSatisfy { $0.inConfig })
    }
}
