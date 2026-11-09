import Foundation
import Testing
@testable import ShellforgeCore

/// The typed-in prompt's driver: what the host feeds it from a tab's terminal, and what it gives
/// back to write, once.
@Suite struct TypedPromptDriverTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func launch(_ prompt: String?) -> AgentLaunch {
        AgentLaunch(command: "'/r/shellforge-run' aider -- 'aider'", typedPrompt: prompt, agentId: "aider", environment: [:],
                    needsArming: true, agentProgram: "aider")
    }

    @Test func noTypedPromptNeedsNoDriver() {
        #expect(TypedPromptDriver(launch: launch(nil), armedAt: t0) == nil)
        #expect(TypedPromptDriver(launch: launch(""), armedAt: t0) == nil)
    }

    /// The paste is `TypedPrompt.paste` of the launch's prompt, given once; every later tick says finished.
    @Test func typesThePasteExactlyOnce() throws {
        var driver = try #require(TypedPromptDriver(launch: launch("fix\r\nit"), armedAt: t0))
        var typed: [String] = []
        var bytes = 0
        for tick in 0..<80 {
            // The agent prints for the first second, then nothing.
            if tick < 4 { bytes += 500 }
            switch driver.observe(commandLine: "aider", outputBytes: bytes, now: t0.addingTimeInterval(Double(tick) * 0.25)) {
            case .type(let text): typed.append(text)
            case .wait, .finished: break
            case .abandon: Issue.record("abandoned at tick \(tick)")
            }
        }
        #expect(typed == [TypedPrompt.paste("fix\r\nit")])
        #expect(driver.observe(commandLine: "aider", outputBytes: bytes, now: t0.addingTimeInterval(60)) == .finished)
    }

    /// An agent that ends before the prompt went: nothing is typed, into what is now a shell, and
    /// the host is told the agent exited.
    @Test func anAgentThatExitsAbandonsAndSaysSo() throws {
        var driver = try #require(TypedPromptDriver(launch: launch("fix it"), armedAt: t0))
        #expect(driver.observe(commandLine: "aider", outputBytes: 100, now: t0) == .wait)
        #expect(driver.observe(commandLine: "-zsh", outputBytes: 100, now: t0.addingTimeInterval(0.25)) == .abandon(agentExited: true))
        #expect(driver.observe(commandLine: "aider", outputBytes: 100, now: t0.addingTimeInterval(9)) == .finished)
    }

    /// An agent that never started (the runner refused, say) gives up quietly: the runner said why.
    @Test func anAgentThatNeverRanGivesUpWithoutANote() throws {
        var driver = try #require(TypedPromptDriver(launch: launch("fix it"), armedAt: t0))
        #expect(driver.observe(commandLine: "-zsh", outputBytes: 0, now: t0.addingTimeInterval(1)) == .wait)
        #expect(driver.observe(commandLine: "-zsh", outputBytes: 0, now: t0.addingTimeInterval(TypingReadiness.giveUp))
                == .abandon(agentExited: false))
    }

    private let runnerLine = "/usr/local/bin/python3 -I /r/../daemon/shellforged/run_agent.py aider -- aider"

    /// C1: the runner waits past the ceiling for a late take, fails and exits. The paste must never
    /// go: the shell would run it as a command.
    @Test func aRunnerThatExitsBeforeTheAgentRanNeverTypes() throws {
        var driver = try #require(TypedPromptDriver(launch: launch("rm -rf ~ # from a ticket"), armedAt: t0))
        var steps: [TypedPromptDriver.Step] = []
        steps.append(driver.observe(commandLine: "-zsh", outputBytes: 0, now: t0))
        steps.append(driver.observe(commandLine: "/bin/zsh -f /r/shellforge-run aider -- aider", outputBytes: 0, now: t0.addingTimeInterval(0.25)))
        for tick in 2...48 {
            steps.append(driver.observe(commandLine: runnerLine, outputBytes: 0, now: t0.addingTimeInterval(Double(tick) * 0.25)))
        }
        steps.append(driver.observe(commandLine: "-zsh", outputBytes: 120, now: t0.addingTimeInterval(12.25)))
        #expect(!steps.contains { if case .type = $0 { true } else { false } })
        #expect(steps.last == .abandon(agentExited: false))
        #expect(driver.observe(commandLine: "aider", outputBytes: 120, now: t0.addingTimeInterval(13)) == .finished)
    }

    /// The agent shows up after 9 s of the runner: the prompt goes after the agent's own quiet window.
    @Test func anAgentAfterALongTakeTypesOnceItSettles() throws {
        var driver = try #require(TypedPromptDriver(launch: launch("fix it"), armedAt: t0))
        for tick in 0..<36 {
            #expect(driver.observe(commandLine: runnerLine, outputBytes: 0, now: t0.addingTimeInterval(Double(tick) * 0.25)) == .wait)
        }
        var typedAt: TimeInterval?
        var bytes = 0
        for tick in 36..<80 where typedAt == nil {
            let t = Double(tick) * 0.25
            if tick < 40 { bytes += 500 }
            if case .type = driver.observe(commandLine: "/usr/local/bin/aider", outputBytes: bytes, now: t0.addingTimeInterval(t)) { typedAt = t }
        }
        let at = try #require(typedAt)
        // The agent printed until 9.75 s: at least the quiet window after it began, well before its own ceiling.
        #expect(at >= 9 + TypingReadiness.quiet && at < 9 + TypingReadiness.ceiling)
    }

    /// A program that is not the agent (the user opened an editor) is never typed into.
    @Test func anotherProgramIsNeverTypedInto() throws {
        var driver = try #require(TypedPromptDriver(launch: launch("fix it"), armedAt: t0))
        var steps: [TypedPromptDriver.Step] = []
        for tick in 0...Int(TypingReadiness.giveUp * 4) {
            steps.append(driver.observe(commandLine: "vim notes.md", outputBytes: tick * 10, now: t0.addingTimeInterval(Double(tick) * 0.25)))
        }
        #expect(!steps.contains { if case .type = $0 { true } else { false } })
        #expect(steps.last == .abandon(agentExited: false))
    }

    /// A launch whose command names no program can't be told from the runner: nothing is typed.
    @Test func aLaunchWithNoAgentProgramNeedsNoDriver() {
        let bare = AgentLaunch(command: "x", typedPrompt: "fix it", agentId: "aider", environment: [:], agentProgram: nil)
        #expect(TypedPromptDriver(launch: bare, armedAt: t0) == nil)
    }

    /// R3: the fresh read taken right before writing decides. Only the agent's own program gets the
    /// paste; a shell back in the foreground means the agent exited.
    @Test func theFreshReadDecides() throws {
        let driver = try #require(TypedPromptDriver(launch: launch("fix it"), armedAt: t0))
        #expect(driver.confirm(commandLine: "aider --yes") == .type(TypedPrompt.paste("fix it")))
        #expect(driver.confirm(commandLine: "python3 /x/aider") == .type(TypedPrompt.paste("fix it")))
        #expect(driver.confirm(commandLine: "-zsh") == .abandon(agentExited: true))
        #expect(driver.confirm(commandLine: nil) == .abandon(agentExited: true))
        #expect(driver.confirm(commandLine: "vim notes.md") == .abandon(agentExited: false))
        #expect(driver.confirm(commandLine: "/bin/zsh /r/shellforge-run aider -- aider") == .abandon(agentExited: false))
    }
}

