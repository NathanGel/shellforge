import AppKit
import Testing
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

@MainActor @Suite struct SidebarTests {
    private func sidebarModel() throws -> SidebarModel {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-view-\(UUID().uuidString)")
        return SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)), launcher: try GitRepoForUI().launcher)
    }

    /// An Agent hooks sheet on a scratch home: building the view reads no file.
    private func hooks() -> AgentHooksModel {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("shellforge-view-home-\(UUID().uuidString)")
        return AgentHooksModel(integrations: HookIntegrations(home: home, resources: .bundled(resourceURL: nil)), names: [:])
    }

    @Test func theHostViewIsAsWideAsTheSidebar() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }, hooks: hooks(), machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()), backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })).frame.width == ShellforgeSidebar.width)
    }

    @Test func theSidebarStretchesWithTheWindowsHeightOnly() throws {
        #expect(ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }, hooks: hooks(), machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()), backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in })).autoresizingMask == [.height])
    }

    @Test func theSidebarIsAiTermsWidth() throws {
        #expect(ShellforgeSidebar.width == Size.sidebarWidth)
    }

    /// Inside a light iTerm2 window the sidebar still draws AiTerm's dark ground: its host is dark,
    /// whatever the window around it.
    @Test func theSidebarDrawsDarkInALightWindow() throws {
        let host = ShellforgeSidebar.makeView(model: try sidebarModel(), chooseFolder: { nil }, hooks: hooks(), machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()), backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }))
        host.frame.size.height = 400
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        #expect(host.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let ground = try #require(bitmap.colorAt(x: Int(host.bounds.width) - 4, y: Int(host.bounds.height) - 4)?.usingColorSpace(.sRGB))
        #expect(ground.brightnessComponent < 0.3, "the sidebar's ground is light: \(ground)")
    }
}

/// A battery that reads as mains: the footer's Mac row with no `bat`.
struct InertPower: PowerSource { func reading() -> PowerReading { .mains } }
