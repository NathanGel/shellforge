import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeDesign
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
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), theme: ThemeSettings(defaults: ScratchDefaults.make()), terminalEditorDefaults: ScratchDefaults.make(), feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev),
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

    /// The ground under `theme`, with `kind` as this Mac's material: its centre pixel, and whether
    /// it holds the system material's view.
    private func ground(cornerRadius: CGFloat?, kind: ShellforgeMaterial.Kind, theme: Theme) throws -> (centre: NSColor?, material: Bool) {
        try ThemeRuntime.$override.withValue(theme) {
            let view = NSHostingView(rootView: SidebarGround(cornerRadius: cornerRadius, kind: kind).frame(width: 200, height: 200))
            view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
            let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .darkAqua)
            window.backgroundColor = .systemRed
            window.contentView = view
            view.layoutSubtreeIfNeeded()
            // `Snapshot`'s device-RGB bitmap, as the theme tests read colours: the view's own cache
            // is in the screen's colour space.
            let rep = try #require(Snapshot.bitmap(of: view))
            @MainActor func holdsMaterial(_ view: NSView) -> Bool { view is NSVisualEffectView || view.subviews.contains(where: holdsMaterial) }
            let material = holdsMaterial(view)
            window.close()
            return (rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?.usingColorSpace(.sRGB), material)
        }
    }

    /// Final-review fix: under a theme the sidebar's ground is the theme's opaque chrome, floating
    /// or flush, on every Mac's material; under Shellforge it is the material, as before.
    @Test(arguments: [CGFloat(10), nil], [ShellforgeMaterial.Kind.glass, .sidebar, .opaque])
    func aThemeGroundsTheSidebarInItsChrome(cornerRadius: CGFloat?, kind: ShellforgeMaterial.Kind) throws {
        let dracula = ThemeCatalog.theme(id: "dracula")
        let chrome = try #require(dracula.colors).sidebar
        #expect(chrome == SRGB(red: 0x21 / 255.0, green: 0x22 / 255.0, blue: 0x2C / 255.0))
        let themed = try ground(cornerRadius: cornerRadius, kind: kind, theme: dracula)
        let centre = try #require(themed.centre)
        #expect(abs(centre.redComponent - chrome.red) <= 1.5 / 255 && abs(centre.greenComponent - chrome.green) <= 1.5 / 255
                && abs(centre.blueComponent - chrome.blue) <= 1.5 / 255 && centre.alphaComponent > 0.99, "\(centre)")
        #expect(!themed.material, "a theme's ground is its colour, not the Mac's material")
    }

    @Test(arguments: [CGFloat(10), nil])
    func theShellforgeGroundIsTheMaterial(cornerRadius: CGFloat?) throws {
        #expect(try ground(cornerRadius: cornerRadius, kind: .sidebar, theme: ThemeCatalog.shellforge).material,
                "the system sidebar material, as before themes")
        let opaque = try ground(cornerRadius: cornerRadius, kind: .opaque, theme: ThemeCatalog.shellforge)
        #expect(!opaque.material)
        #expect(!isRedOrClear(opaque.centre), "Reduce Transparency's opaque surface, as before")
    }

    /// A ground on screen when the theme changes follows it: from the material to the chrome and
    /// back, without being made again.
    @Test func aThemeChangeRegroundsAShownSidebar() throws {
        @MainActor func holdsMaterial(_ view: NSView) -> Bool { view is NSVisualEffectView || view.subviews.contains(where: holdsMaterial) }
        /// Turns of the run loop until `done`, for SwiftUI to apply the state change; bounded by
        /// turns, not by time, so a slow machine only takes longer.
        func pump(_ view: NSView, until done: () -> Bool) {
            for _ in 0..<500 where !done() {
                RunLoop.main.run(mode: .default, before: Date())
                view.layoutSubtreeIfNeeded()
            }
        }
        let view = ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) {
            NSHostingView(rootView: SidebarGround(cornerRadius: 10, kind: .sidebar).frame(width: 200, height: 200))
        }
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 200)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        defer { window.close() }
        ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) { view.layoutSubtreeIfNeeded() }
        #expect(holdsMaterial(view))

        ThemeRuntime.$override.withValue(ThemeCatalog.theme(id: "nord")) {
            NotificationCenter.default.post(name: ThemeRuntime.didChange, object: nil)
            pump(view) { !holdsMaterial(view) }
        }
        #expect(!holdsMaterial(view), "under Nord the ground is the chrome")

        ThemeRuntime.$override.withValue(ThemeCatalog.shellforge) {
            NotificationCenter.default.post(name: ThemeRuntime.didChange, object: nil)
            pump(view) { holdsMaterial(view) }
        }
        #expect(holdsMaterial(view), "back under Shellforge, the material again")
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
                                              terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()), theme: ThemeSettings(defaults: ScratchDefaults.make()), terminalEditorDefaults: ScratchDefaults.make(), feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev),
                                              panelCornerRadius: 8)
        #expect(!view.mouseDownCanMoveWindow)
    }
}
