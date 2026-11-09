import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct ExactStatusLinesTests {
    @Test func genericLinesQuoteAPathWithASpace() {
        #expect(ExactStatusLines.generic(statusCommand: "/App Support/shellforge-status")
                == "'/App Support/shellforge-status' working\n'/App Support/shellforge-status' needs-input\n'/App Support/shellforge-status' done")
    }

    @Test func genericLines() {
        #expect(ExactStatusLines.generic(statusCommand: "/x/shellforge-status")
                == "/x/shellforge-status working\n/x/shellforge-status needs-input\n/x/shellforge-status done")
    }

    @Test func pathWithSpacesQuoted() {
        let agent = AgentDefinition(id: "a", name: "A", command: "a", status: .eventProtocol,
                                    statusSetup: .init(file: "~/a.toml", snippet: "run = {shellforge-status} done"))
        #expect(ExactStatusLines.lines(for: agent, statusCommand: "/App Support/shellforge-status")
                == "run = '/App Support/shellforge-status' done")
    }

    @Test func jsonSnippetEscaped() {
        let agent = AgentDefinition(id: "a", name: "A", command: "a", status: .eventProtocol,
                                    statusSetup: .init(file: "~/a.json", snippet: #"{"command": "{shellforge-status} done"}"#))
        let line = ExactStatusLines.lines(for: agent, statusCommand: #"/a b/"x"/status"#)
        #expect(line == #"{"command": "'/a b/\"x\"/status' done"}"#)
        #expect((try? JSONSerialization.jsonObject(with: Data(line.utf8))) != nil)
    }

    @Test func noSetupFallsBackToGeneric() {
        let agent = AgentDefinition(id: "a", name: "A", command: "a")
        #expect(ExactStatusLines.lines(for: agent, statusCommand: "s") == ExactStatusLines.generic(statusCommand: "s"))
    }
}
