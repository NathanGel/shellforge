import Testing
@testable import ShellforgeCore

@Suite struct AgentLaunchTests {
    @Test func claudeLaunchesAsInAiTerm() {
        #expect(AgentPresets.claude.launchWords(model: "opus", reasoning: "high")
            == ["claude", "--model", "opus", "--effort", "high"])
    }

    @Test func aGroupWhosePlaceholderHasNoValueIsLeftOut() {
        #expect(AgentPresets.claude.launchWords(model: "opus", reasoning: nil) == ["claude", "--model", "opus"])
    }

    @Test func codexKeepsItsApprovalBypassAndReasoningSetting() {
        #expect(AgentPresets.codex.launchWords(model: "gpt-5", reasoning: "medium")
            == ["codex", "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt-5", "-c", "model_reasoning_effort=medium"])
    }

    @Test func grokAndPiUseTheirOwnFlags() {
        #expect(AgentPresets.grok.launchWords(model: "grok-4", reasoning: "high")
            == ["grok", "-m", "grok-4", "--reasoning-effort", "high"])
        #expect(AgentPresets.pi.launchWords(model: "sonnet", reasoning: "low") == ["pi", "--model", "sonnet", "--thinking", "low"])
    }

    @Test func aCustomAgentFillsItsOwnTemplate() {
        let local = AgentDefinition(id: "ollama-coder", name: "Local coder", command: "aider",
                                    arguments: [["--model", "ollama_chat/{model}"], ["--subtree-only"]])
        #expect(local.launchWords(model: "qwen3-coder", reasoning: nil)
            == ["aider", "--model", "ollama_chat/qwen3-coder", "--subtree-only"])
    }

    @Test func thePromptIsQuotedOntoTheCommandLineWhenPassedAsAnArgument() {
        #expect(AgentPresets.claude.commandLine(model: "opus", reasoning: nil, prompt: "fix the user's bug")
            == "claude --model opus 'fix the user'\\''s bug'")
    }

    @Test func aPromptTypedIntoTheRunningAgentIsNotOnTheCommandLine() {
        var typed = AgentPresets.claude
        typed.prompt = .typed
        #expect(typed.commandLine(model: "opus", reasoning: nil, prompt: "hello") == "claude --model opus")
    }

    @Test func theFourPresetsComeInAiTermsOrder() {
        #expect(AgentPresets.all.map(\.id) == ["claude", "codex", "grok", "pi"])
        #expect(AgentPresets.all.map(\.status) == [.preset("claude"), .preset("codex"), .preset("grok"), .preset("pi")])
    }
}
