// Ported from AiTerm (app/Tests/AiTermCoreTests/SleepRuleTests.swift), GPLv3, Laurens D'Hondt.
import Testing
@testable import ShellforgeCore

@Suite struct SleepRuleTests {
    @Test func theRuleAllowsExactlyTheTwoPmsetCommandsForTheUser() throws {
        let text = try #require(SleepRule.text(user: "laurensdhondt"))
        #expect(text == """
            # Installed by Shellforge for backpack mode. Remove with Mac Settings > Remove.
            laurensdhondt ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1

            """)
        #expect(!text.contains("ALL=(ALL)") && !text.contains("*"))
    }

    @Test func unsafeUserNamesGetNoRule() {
        for user in ["", "-root", "two words", "DOMAIN\\me", "me,root", "me\nroot ALL=(ALL) ALL", "jürgen"] {
            #expect(SleepRule.text(user: user) == nil, "\(user)")
            #expect(SleepRule.installCommand(user: user) == nil, "\(user)")
        }
        #expect(SleepRule.text(user: "first.last-2_x") != nil)
    }

    /// Validated before it is installed, installed root:wheel 0440, and the temporary file always goes.
    @Test func theInstallCommandValidatesBeforeInstalling() throws {
        let command = try #require(SleepRule.installCommand(user: "me"))
        let visudo = try #require(command.range(of: "/usr/sbin/visudo -cf"))
        let install = try #require(command.range(of: "/usr/bin/install -m 0440 -o root -g wheel"))
        #expect(visudo.lowerBound < install.lowerBound)
        #expect(command.contains("/etc/sudoers.d/shellforge"))
        #expect(command.contains("/bin/rm -f \"$t\""))
        #expect(SleepRule.removeCommand == "/bin/rm -f /etc/sudoers.d/shellforge")
    }

    @Test func theAppleScriptEscapesQuotesAndBackslashes() {
        #expect(SleepRule.appleScript(running: #"printf "%s\n" x"#)
                == #"do shell script "printf \"%s\\n\" x" with administrator privileges"#)
    }

    /// Each line of the rule travels inside single quotes in the install command, so a quote in the
    /// rule's own text would end the word early and break the command.
    @Test func theRuleHasNoQuoteThatWouldBreakItsInstallCommand() {
        #expect(SleepRule.text(user: "nathan").map { !$0.contains("'") } == true)
    }
}
