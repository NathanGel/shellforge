import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

/// The floating sidebar is a rounded panel: its corners show what is behind it, its edge is the
/// panel's outline. The classic sidebar fills its column to the corner.
@MainActor @Suite struct FloatingPanelTests {
    private func render(panelCornerRadius: CGFloat?) throws -> NSBitmapImageRep {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("float-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("float-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let view = ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                                              panelCornerRadius: panelCornerRadius)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: view.frame.width, height: 400), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .systemRed
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.close()
        return rep
    }

    private func isRedOrClear(_ color: NSColor?) -> Bool {
        guard let c = color?.usingColorSpace(.sRGB) else { return true }
        return c.alphaComponent < 0.1 || (c.redComponent > 0.8 && c.greenComponent < 0.3)
    }

    /// The ground alone, opaque, over red: glass does not draw into an offscreen cache, so the shape
    /// is pinned with the material Reduce Transparency gives.
    private func renderGround(cornerRadius: CGFloat?) throws -> NSBitmapImageRep {
        let view = NSHostingView(rootView: SidebarGround(cornerRadius: cornerRadius, kind: .opaque).frame(width: 200, height: 200))
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.backgroundColor = .systemRed
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        let rep = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        window.close()
        return rep
    }

    @Test func aFloatingPanelHasRoundCorners() throws {
        let rep = try renderGround(cornerRadius: 8)
        #expect(isRedOrClear(rep.colorAt(x: 0, y: 0)), "the top-left corner shows what is behind the panel")
        #expect(!isRedOrClear(rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)), "the panel's middle is the panel")
    }

    @Test func theClassicGroundFillsItsCorner() throws {
        let rep = try renderGround(cornerRadius: nil)
        #expect(!isRedOrClear(rep.colorAt(x: 0, y: 0)))
    }

    @Test func theFloatingSidebarLeavesItsCornersClear() throws {
        let rep = try render(panelCornerRadius: 8)
        #expect(isRedOrClear(rep.colorAt(x: 0, y: 0)), "a whole floating sidebar: its corner is not filled")
    }

    /// Review fix: in a window that moves by its background, a click on the sidebar must not drag
    /// the window.
    @Test func theSidebarNeverMovesTheWindow() throws {
        let document = WorkspaceDocument(store: WorkspaceStore(folder: TestScratch.root.appendingPathComponent("move-\(UUID().uuidString)")))
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        let model = SidebarModel(host: FakeTerminalHost(), document: document, launcher: launcher, jiraSettings: { nil })
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("move-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let view = ShellforgeSidebar.makeView(model: model, chooseFolder: { nil }, hooks: hooks,
                                              machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                                              backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                                              zoom: SidebarZoom(settings: SidebarLayoutSettings(defaults: ScratchDefaults.make())),
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                                              panelCornerRadius: 8)
        #expect(!view.mouseDownCanMoveWindow)
    }
}
