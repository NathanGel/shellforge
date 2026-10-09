import Testing
@testable import ShellforgeCore

@Suite struct HelperStatusTests {
    @Test func everyProblemSaysWhatToDo() {
        #expect(HelperStatus.pythonMissing.text == "Shellforge needs Python 3.11 or newer on your login shell’s PATH.")
        #expect(HelperStatus.helperMissing.text == "Shellforge’s helper is missing from the app; reinstall Shellforge.")
        #expect(HelperStatus.helperFailing("exited with status 1").text == "Shellforge’s helper keeps stopping (exited with status 1). Its log is in ~/Library/Application Support/Shellforge/shellforged.log.")
        #expect(HelperStatus.helperMismatch.text == "Shellforge’s helper is from another version. Quit Shellforge, wait a minute for the old helper to stop, then open Shellforge again.")
        #expect(HelperStatus.helperUnreachable.text == "Reconnecting to Shellforge’s helper…")
    }

    @Test func onlyStartingAndConnectedAreNotProblems() {
        let all: [HelperStatus] = [.starting, .helperMissing, .pythonMissing, .helperFailing("x"), .helperMismatch, .helperUnreachable, .connected]
        #expect(all.filter { !$0.isProblem } == [.starting, .connected])
    }
}
