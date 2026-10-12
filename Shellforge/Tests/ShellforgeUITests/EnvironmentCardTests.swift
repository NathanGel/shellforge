import Foundation
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// Settings › Core › Environment: the report, read off the main actor, and Reload — one read at a
/// time. Launchers are scripted: no login shell runs.
@MainActor @Suite struct EnvironmentCardTests {
    /// A resolver that counts its reads and can be held, to catch a second Reload during the first.
    private final class Resolver: @unchecked Sendable {
        let reads = Locked(0)
        let gate = DispatchSemaphore(value: 0)
        let held: Bool
        let source: ResolvedEnvironment.Source
        init(held: Bool = false, source: ResolvedEnvironment.Source = .loginShell("/bin/zsh")) { self.held = held; self.source = source }
        func read() -> ResolvedEnvironment {
            let n = reads.withLock { (count: inout Int) -> Int in count += 1; return count }
            if held, n > 1 { gate.wait() }
            return ResolvedEnvironment(variables: ["PATH": "/usr/bin:/bin"], source: source)
        }
    }

    @Test func loadShowsTheReport() async {
        let resolver = Resolver()
        let model = EnvironmentModel(launcher: CommandLauncher(resolve: resolver.read), agents: [AgentPresets.claude])
        await model.load()
        #expect(model.report?.shell == "/bin/zsh")
        #expect(model.report?.path == ["/usr/bin", "/bin"])
        #expect(model.report?.tools.map(\.name).last == "claude")
    }

    @Test func reloadReadsAgain() async {
        let resolver = Resolver()
        let model = EnvironmentModel(launcher: CommandLauncher(resolve: resolver.read), agents: [])
        await model.load()
        await model.reload()
        #expect(resolver.reads.withLock { $0 } == 2)
    }

    @Test func reloadIsOneAtATime() async {
        let resolver = Resolver(held: true)
        var reloaded = 0
        let model = EnvironmentModel(launcher: CommandLauncher(resolve: resolver.read), agents: [])
        model.onReloaded = { reloaded += 1 }
        await model.load()
        let first = Task { await model.reload() }
        // The first Reload's read under way, held at the gate.
        #expect(await eventually { model.reading && resolver.reads.withLock { $0 } == 2 })
        await model.reload()
        #expect(resolver.reads.withLock { $0 } == 2, "the second press while reading reads nothing")
        resolver.gate.signal()
        await first.value
        #expect(!model.reading && reloaded == 1)
    }

    @Test func theStatusLineSaysTheShellOrWhy() {
        let now = Date(timeIntervalSince1970: 10_000)
        let read = EnvironmentReport(shell: "/bin/zsh", fallbackReason: nil, readAt: now.addingTimeInterval(-120), path: [], tools: [])
        #expect(EnvironmentCard.status(read, now: now) == SettingsStatus(.ready, "Read from /bin/zsh 2 minutes ago"))
        let fallback = EnvironmentReport(shell: nil, fallbackReason: "/bin/zsh did not answer within 15 s", readAt: now, path: [], tools: [])
        #expect(EnvironmentCard.status(fallback, now: now) == SettingsStatus(.attention, "A fallback PATH: /bin/zsh did not answer within 15 s"))
        #expect(EnvironmentCard.status(nil, now: now) == SettingsStatus(.idle, "Reading your login shell…"))
    }
}
