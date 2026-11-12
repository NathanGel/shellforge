import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct PanelTabTests {
    private let project = UUID()

    @Test func tagValuesRoundTrip() {
        let cases: [PanelTab] = [
            .ssh(alias: "staging"),
            .file(project: project, path: "src/app.ts"),
            .file(project: project, path: "src/a:b.ts"),
            .diff(repo: "project:\(project.uuidString)", path: "src/app.ts"),
            .diff(repo: "task:\(UUID().uuidString)", path: "src/a:b.ts"),
        ]
        for panel in cases {
            #expect(PanelTab(tagValue: panel.tagValue) == panel)
        }
        #expect(PanelTab.file(project: project, path: "x").tagValue == "files:\(project.uuidString.lowercased()):x")
        #expect(PanelTab(tagValue: "nonsense") == nil)
        #expect(PanelTab(tagValue: "files:not-a-uuid:x") == nil)
    }

    /// A damaged tag names no owner, so its tab stays reachable under Other Tabs.
    @Test func malformedValuesAreNil() {
        let id = UUID().uuidString
        #expect(PanelTab(tagValue: "ssh:") == nil)
        #expect(PanelTab(tagValue: "files:\(id):") == nil)
        #expect(PanelTab(tagValue: "git:project:\(id):") == nil)
        #expect(PanelTab(tagValue: "git:other:\(id):src/app.ts") == nil)
        #expect(PanelTab(tagValue: "git:task:not-a-uuid:src/app.ts") == nil)
    }

    @Test func theFocusedPaneNamesThePanelFirst() {
        let a = PanelTab.ssh(alias: "staging").tagValue
        let b = PanelTab.ssh(alias: "db").tagValue
        #expect(TabSnapshot.panel(ofPanes: [nil, b, a]) == .ssh(alias: "db"))
        #expect(TabSnapshot.panel(ofPanes: [nil, "junk"]) == nil)
    }
}
