import AppKit
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

/// The sidebar's right edge draws a hairline, so the sidebar reads apart from the terminal beside it.
@MainActor @Suite struct SidebarEdgeTests {
    @Test func theRightEdgeIsNotTheSurface() throws {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("edge-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("edge-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let view = ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        // Half-way down, inside the empty list: the last column against one well inside.
        let y = rep.pixelsHigh / 2
        let edge = try #require(rep.colorAt(x: rep.pixelsWide - 1, y: y)?.usingColorSpace(.sRGB))
        let inside = try #require(rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.sRGB))
        let difference = abs(edge.redComponent - inside.redComponent) + abs(edge.greenComponent - inside.greenComponent)
            + abs(edge.blueComponent - inside.blueComponent)
        #expect(difference > 0.03, "edge \(edge), inside \(inside)")
        window.close()
    }

    /// The sidebar's content fits the narrowest floating panel — the narrowest column less the
    /// panel's inset — and a zoomed sidebar's too: content wider than its panel spilled past the
    /// panel's edges, eating the gap between the panel and the window on the left.
    @Test func theContentNeverAsksForMoreThanItsPanel() {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("fit-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("fit-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let zoom = SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make()))
        zoom.bigger(); zoom.bigger()
        let view = ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: zoom, terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                                              panelCornerRadius: 8)
        #expect(view.fittingSize.width <= Size.sidebarMinWidth - Space.inset, "the content asks for \(view.fittingSize.width) pt")
    }
}

