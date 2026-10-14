import AppKit
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

/// Which side of a window was clicked last, for ⌘+ / ⌘− / ⌘0: the sidebar, anywhere in it, until a
/// click outside it. Each window keeps its own.
@MainActor @Suite struct SidebarClicksTests {
    private func sidebar() throws -> NSView {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("clicks-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        return ShellforgeSidebar.makeView(model: model, chooseFolder: { nil },
                                          hooks: AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("clicks-home-\(UUID().uuidString)"),
                                                                                                resources: .bundled(resourceURL: nil)), names: [:]),
                                          machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                          backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                          zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())))
    }

    private func window() -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }

    @Test func aClickInsideTheSidebarMakesItActive() throws {
        let sidebar = try sidebar()
        let inside = NSView()
        sidebar.addSubview(inside)
        let clicks = SidebarClicks()
        let window = window()
        clicks.clicked(in: window, on: inside)
        #expect(clicks.sidebarIsActive(in: window))
    }

    @Test func aClickOutsideTheSidebarMakesTheTerminalActive() throws {
        let clicks = SidebarClicks()
        let window = window()
        clicks.clicked(in: window, on: try sidebar())
        clicks.clicked(in: window, on: NSView())
        #expect(!clicks.sidebarIsActive(in: window))
    }

    @Test func eachWindowKeepsItsOwnSide() throws {
        let clicks = SidebarClicks()
        let (first, second) = (window(), window())
        clicks.clicked(in: first, on: try sidebar())
        #expect(clicks.sidebarIsActive(in: first))
        #expect(!clicks.sidebarIsActive(in: second))
        #expect(!clicks.sidebarIsActive(in: nil))
    }
}
