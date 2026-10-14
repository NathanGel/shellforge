import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

/// Nothing Shellforge draws forces an appearance: the sidebar, its sheets and its folder picker take
/// their window's, which is macOS's or iTerm2's Appearance setting.
@MainActor @Suite struct AppearanceTests {
    private func sidebar() -> NSView {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("appearance-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("appearance-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        return ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                          machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                          backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                          zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                          terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()))
    }

    @Test func theSidebarFollowsItsWindow() {
        let view = sidebar()
        #expect(view.appearance == nil)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(view.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        window.close()
    }

    @Test func aSheetPanelFollowsItsWindow() {
        let panel = ShellforgePanel.present(Text(verbatim: "x"), over: nil)
        #expect(panel.appearance == nil)
        #expect(panel.contentView?.appearance == nil)
        ShellforgePanel.dismiss(panel)
    }

    @Test func theFolderPickerFollowsTheApp() {
        #expect(FolderChooser.panel().appearance == nil)
    }
}
