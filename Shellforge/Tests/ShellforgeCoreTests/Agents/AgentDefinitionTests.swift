import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct AgentDefinitionTests {
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

    @Test func oldFileDecodes() throws {
        let old = #"""
        {"id": "mine", "name": "Mine", "command": "mine", "arguments": [["-x"]], "prompt": "argument",
         "models": {"fixed": {"_0": ["a"]}}, "reasoningLevels": [], "environment": {}, "secrets": {}, "status": {"terminal": {}}}
        """#
        let agent = try JSONDecoder().decode(AgentDefinition.self, from: Data(old.utf8))
        #expect(agent.statusSetup == nil && agent.status == .terminal && agent.prompt == .argument)
        let again = try String(decoding: JSONEncoder().encode(agent), as: UTF8.self)
        #expect(!again.contains("statusSetup"))
    }

    @Test func statusSetupRoundTrips() throws {
        var agent = AgentDefinition(id: "g", name: "G", command: "g", status: .eventProtocol)
        agent.statusSetup = .init(file: "~/.g/settings.json", snippet: "{shellforge-status} done")
        let back = try JSONDecoder().decode(AgentDefinition.self, from: JSONEncoder().encode(agent))
        #expect(back == agent)
    }

    @Test func noneRawValueIsNone() throws {
        #expect(AgentDefinition.PromptDelivery.noPrompt.rawValue == "none")
        #expect(try JSONDecoder().decode(AgentDefinition.PromptDelivery.self, from: Data("\"none\"".utf8)) == .noPrompt)
    }

    @Test func splitHandlesQuotes() {
        #expect(ShellWords.split("a 'b c' \"d\"") == ["a", "b c", "d"])
        #expect(ShellWords.split("a 'b") == nil)
        #expect(ShellWords.split("a \"b") == nil)
        #expect(ShellWords.split(#"x\ y 'it'\''s' "q\"r" ''"#) == ["x y", "it's", "q\"r", ""])
        #expect(ShellWords.split("  ") == [])
    }

    @Test func splitReadsWhatQuoteWrote() {
        let nasty = "a 'b' $HOME `x`; \\ \"z\""
        #expect(ShellWords.split(ShellWords.quote(nasty)) == [nasty])
    }

    @Test func builtInsAreTheFourPresets() {
        #expect(["claude", "codex", "grok", "pi"].allSatisfy(AgentPresets.isBuiltIn))
        #expect(!AgentPresets.isBuiltIn("shell") && !AgentPresets.isBuiltIn("gemini"))
    }
}
