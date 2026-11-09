import Testing
@testable import ShellforgeCore

@Suite struct TerminalSignalsTests {
    /// Review Focus 1: the terminal echoing what the user types is not the agent working.
    @Test func typingEchoIsNotOutput() {
        var s = TerminalSignals()
        s.output(300, sinceInput: 0.2)
        #expect(s.outputBytes == 0)
        s.output(300, sinceInput: 0.6)
        #expect(s.outputBytes == 300)
    }

    @Test func attentionCounts() {
        var s = TerminalSignals()
        #expect(s.attention == 0)
        s.attentionRequested(); s.attentionRequested()
        #expect(s.attention == 2)
    }
}
