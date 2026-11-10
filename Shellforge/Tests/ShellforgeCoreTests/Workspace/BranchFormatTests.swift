import Foundation
import Testing
@testable import ShellforgeCore

/// A project's choice of how its tasks' branches are named: type and name, or the ticket key alone.
@Suite struct BranchFormatTests {
    private func draft(_ format: BranchFormat? = nil) -> TaskDraft {
        var d = TaskDraft(baseBranch: "main", agentId: "claude", model: "opus", reasoning: nil)
        if let format { d.branchFormat = format }
        return d
    }
    private let ticket = JiraTicket(key: "JVS-5819", summary: "Jarvis alarms and relay", description: nil, issueType: "Bug", status: nil, url: "")

    @Test func theDefaultIsTodaysTypeAndName() {
        var d = draft()
        d.apply(ticket: ticket)
        #expect(d.branchFormat == .typeAndName)
        #expect(d.branch == "fix/jvs-5819-jarvis-alarms-and-relay")
    }

    @Test func ticketKeyNamesTheBranchAfterTheKeyAlone() {
        var d = draft(.ticketKey)
        d.apply(ticket: ticket)
        #expect(d.branch == "JVS-5819")
        #expect(d.branchFieldText == "JVS-5819" && d.usesTicketKey)
        #expect(d.worktreeSlug == "jvs-5819-jarvis-alarms-and-relay", "the folder keeps its readable slug")
    }

    @Test func withoutATicketItFallsBackToTypeAndName() {
        var d = draft(.ticketKey)
        d.setTitle("Sidebar avatars")
        #expect(d.branch == "feat/sidebar-avatars")
        #expect(!d.usesTicketKey)
        d.apply(ticket: ticket)
        #expect(d.branch == "JVS-5819")
        d.apply(ticket: nil)
        #expect(d.branch.hasPrefix("fix/") || d.branch.hasPrefix("feat/"))
        #expect(d.branchName == "sidebar-avatars")
    }

    @Test func aBranchTypedByHandWins() {
        var d = draft(.ticketKey)
        d.apply(ticket: ticket)
        d.setBranch("fix/my-own")
        #expect(d.branch == "fix/my-own" && !d.usesTicketKey && !d.namesWholeBranch)
    }

    /// In a Ticket Key Only project the field holds the whole branch: one typed there with no known
    /// type prefix is the branch exactly as typed, and the Type select stays hidden.
    @Test func underTicketKeyOnlyABranchTypedWithoutATypeIsTheWholeBranch() {
        var d = draft(.ticketKey)
        d.apply(ticket: ticket)
        d.setBranch("JVS-5819-v2")
        #expect(d.branch == "JVS-5819-v2")
        #expect(d.branchFieldText == "JVS-5819-v2")
        #expect(d.namesWholeBranch && !d.usesTicketKey)
        #expect(d.worktreeSlug == "jvs-5819-v2")
        // SwiftUI writing the same text back changes nothing.
        d.setBranch(d.branchFieldText)
        #expect(d.branch == "JVS-5819-v2" && d.namesWholeBranch)
        // Typing a known type prefix after all picks the type, and the select is back.
        d.setBranch("fix/alarms")
        #expect(d.branch == "fix/alarms" && d.branchType == .fix && !d.namesWholeBranch)
    }

    /// A project using Type and Name is as it was: a branch typed without a type is the name half.
    @Test func underTypeAndNameABranchTypedWithoutATypeIsStillTheName() {
        var d = draft()
        d.apply(ticket: ticket)
        #expect(!d.namesWholeBranch)
        d.setBranch("JVS-5819-v2")
        #expect(d.branch == "fix/JVS-5819-v2")
        #expect(!d.namesWholeBranch)
    }

    @Test func aWriteOfTheShownKeyIsNotAnEdit() {
        var d = draft(.ticketKey)
        d.apply(ticket: ticket)
        d.setBranch(d.branchFieldText)
        #expect(d.branch == "JVS-5819")
    }

    @Test func oldWorkspaceLoadsTheDefaultAndDoesNotWriteTheKey() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"api","path":"/api","addedAt":0}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.branchFormat == .typeAndName)
        let out = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        #expect(!out.contains("branchFormat"))
    }

    /// A format only a newer build knows reads as the default, rather than setting the whole
    /// workspace aside.
    @Test func anUnknownFormatReadsAsTheDefault() throws {
        let id = UUID()
        let json = #"{"id":"\#(id.uuidString)","name":"api","path":"/api","addedAt":0,"branchFormat":"ticketKeyAndName"}"#
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        #expect(project.branchFormat == .typeAndName)
        #expect(project.id == id && project.name == "api")
    }

    @Test func aChosenFormatRoundTrips() throws {
        var project = Project(name: "api", path: "/api")
        project.branchFormat = .ticketKey
        let data = try JSONEncoder().encode(project)
        #expect(String(decoding: data, as: UTF8.self).contains("\"branchFormat\":\"ticketKey\""))
        #expect(try JSONDecoder().decode(Project.self, from: data).branchFormat == .ticketKey)
    }
}
