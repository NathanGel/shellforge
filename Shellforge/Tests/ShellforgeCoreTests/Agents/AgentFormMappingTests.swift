import Foundation
import Testing
@testable import ShellforgeCore

/// The agent form's two text fields, Command and the prompt's arguments, read from and back into an
/// agent's command and argument groups.
@Suite struct AgentFormMappingTests {
    @Test func thePresetsCommandTextRoundTripsToTheSameGroups() throws {
        for preset in AgentPresets.all {
            let parsed = try #require(AgentDefinition.parseCommand(preset.commandText), "\(preset.id)")
            #expect(parsed.command == preset.command, "\(preset.id)")
            #expect(parsed.arguments == preset.arguments, "\(preset.id): \(preset.commandText)")
        }
    }

    @Test func aPlaceholderJoinsTheFlagBeforeIt() throws {
        let parsed = try #require(AgentDefinition.parseCommand("gemini --model {model} --yolo"))
        #expect(parsed.command == "gemini")
        #expect(parsed.arguments == [["--model", "{model}"], ["--yolo"]])
    }

    @Test func aPlaceholderAfterAPlainWordIsItsOwnGroup() throws {
        let parsed = try #require(AgentDefinition.parseCommand("tool run {model} -x {a} {b}"))
        #expect(parsed.arguments == [["run"], ["{model}"], ["-x", "{a}"], ["{b}"]])
    }

    @Test func anUnclosedQuoteOrNothingIsNoCommand() {
        #expect(AgentDefinition.parseCommand("tool 'open") == nil)
        #expect(AgentDefinition.parseCommand("   ") == nil)
    }

    @Test func theCommandTextLeavesThePromptGroupToItsOwnField() {
        let gemini = AgentDefinition(id: "gemini", name: "Gemini CLI", command: "gemini",
                                     arguments: [["--yolo"], ["-i", "{prompt}"]])
        #expect(gemini.commandText == "gemini --yolo")
        #expect(gemini.promptArgumentsText == "-i {prompt}")
        #expect(AgentPresets.claude.promptArgumentsText == "{prompt}")
    }

    @Test func wordsWithSpacesOrQuotesAreQuotedAndReadBack() throws {
        let agent = AgentDefinition(id: "x", name: "X", command: "/Applications/My Tool/bin/tool",
                                    arguments: [["--name", "it’s"], ["--say", "a 'b'"], [""]])
        let parsed = try #require(AgentDefinition.parseCommand(agent.commandText))
        #expect(parsed.command == agent.command)
        #expect(parsed.arguments.joined().map { $0 } == agent.arguments.joined().map { $0 })
    }

    @Test func anUnsafeWordIsCoresOwnRefusal() {
        let control = AgentDefinition(id: "x", name: "X", command: "tool", arguments: [["--a\u{7F}"]])
        #expect(control.unsafeWord() == AgentCommand.UnsafeWord(field: "arguments", reason: .control))
        let backslash = AgentDefinition(id: "x", name: "X", command: "to\\ol")
        #expect(backslash.unsafeWord() == AgentCommand.UnsafeWord(field: "command", reason: .backslash))
        #expect(AgentPresets.codex.unsafeWord() == nil)
    }

    @Test func theReadyMadeNotesAreRead() throws {
        let json = #"""
        {"id": "g", "name": "G", "command": "g", "arguments": [], "prompt": "argument", "models": {"fixed": {"_0": []}},
         "reasoningLevels": [], "environment": {}, "secrets": {}, "status": {"terminal": {}},
         "x-description": "About it.", "x-statusSetupNote": "Merge it."}
        """#
        let agent = try JSONDecoder().decode(AgentDefinition.self, from: Data(json.utf8))
        #expect(agent.about == "About it.")
        #expect(agent.statusSetupNote == "Merge it.")
    }
}
