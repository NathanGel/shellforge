import AppKit
import Foundation
import ShellforgeDesign
import SwiftUI
import Testing
@testable import ShellforgeCore
@testable import ShellforgeUI
@testable import ShellforgeTestSupport

/// The two-line metrics strip under every panel, and the Metrics panel it opens.
@MainActor @Suite struct MetricsStripTests {
    private let week = UsageLine(window: .weekly, percent: 84, reset: "Wed 16:28", warning: true)
    private let fiveHour = UsageLine(window: .fiveHour, percent: 42, reset: "14:05", warning: false)
    /// A vendor reporting both windows, `wk` first as `UsageRows` orders them.
    private func vendor(_ agent: SessionAgent) -> UsageVendorRow { UsageVendorRow(vendor: agent, lines: [week, fiveHour], note: nil) }
    private let cpu = [UsageLine(window: .cpu, percent: 23, warning: false), UsageLine(window: .ram, percent: 61, warning: false),
                       UsageLine(window: .battery, percent: 40, warning: false)]

    /// Two menu rows on the card: the Mac's line, then the vendors'.
    @Test func theStripIsTwoLinesHigh() {
        let scale = InterfaceScale.standard
        #expect(MetricsStrip.height(scale) == 2 * scale(Size.menuRow) + 2 * scale(Space.tight) + scale(Space.base))
    }

    /// Trailing vendors fold into “+N” rather than wrap, two windows each: the leading ones that fit are shown.
    @Test func theStripNeverWrapsWithTwoWindowsPerVendor() {
        let vendors = [vendor(.claude), vendor(.codex), vendor(.custom("a")), vendor(.custom("b"))]
        let folded = MetricsStrip.visible(vendors, fitting: 2)
        #expect(folded.shown.map(\.vendor) == [.claude, .codex])
        #expect(folded.shown.map { MetricsStrip.windows($0).count } == [2, 2])
        #expect(folded.hidden == 2)
        let all = MetricsStrip.visible(vendors, fitting: 9)
        #expect(all.shown.count == 4 && all.hidden == 0)
        let none = MetricsStrip.visible(vendors, fitting: 0)
        #expect(none.shown.isEmpty && none.hidden == 4)
        #expect(MetricsStrip.visible(vendors, fitting: -1).hidden == 4)
        // Drawn at the narrowest panel, four vendors with both windows still take two lines.
        let width = Size.sidebarMinWidth - ActivityBar.width(.standard)
        let strip = NSHostingView(rootView: AnyView(MetricsStrip(machine: cpu, vendors: vendors, open: {})
            .interfaceScale(.standard).frame(width: width)))
        strip.frame = NSRect(x: 0, y: 0, width: width, height: strip.fittingSize.height)
        strip.layoutSubtreeIfNeeded()
        #expect(abs(strip.fittingSize.height - MetricsStrip.height(.standard)) < 0.5)
    }

    /// Line 1 is the Mac's CPU and memory, not its battery.
    @Test func theStripShowsCPUAndMemory() {
        #expect(MetricsStrip.machineGauges(cpu).map(\.window) == [.cpu, .ram])
    }

    /// Line 2 draws `5h` before `wk` — the one that runs out during a session leads — whatever order
    /// the row has them in; a window the vendor did not report is left out, and a note draws none.
    @Test func eachVendorShowsFiveHourThenWeek() {
        #expect(MetricsStrip.windows(vendor(.claude)).map(\.window) == [.fiveHour, .weekly])
        #expect(MetricsStrip.windows(UsageVendorRow(vendor: .claude, lines: [fiveHour, week], note: nil)).map(\.window) == [.fiveHour, .weekly])
        #expect(MetricsStrip.windows(UsageVendorRow(vendor: .codex, lines: [week], note: nil)).map(\.window) == [.weekly])
        #expect(MetricsStrip.windows(UsageVendorRow(vendor: .codex, lines: [], note: "No usage data yet")).isEmpty)
    }

    /// Each window takes its own colour: amber past the threshold, the text ink below it.
    @Test func warningsAreColouredPerWindow() {
        let inks = MetricsStrip.windows(vendor(.claude)).map(MetricsStrip.ink)
        #expect(inks == [Palette.text, Palette.amber])
    }

    /// VoiceOver reads the Mac's readings, then each vendor by name with both windows, or its note.
    @Test func theLabelReadsBothWindows() {
        let label = MetricsStrip.label(machine: MetricsStrip.machineGauges(cpu), vendors: [
            vendor(.claude), UsageVendorRow(vendor: .codex, lines: [UsageLine(window: .weekly, percent: 21, warning: false)], note: nil),
        ])
        #expect(label == "CPU 23 % busy, Memory 61 % used, Claude: 5-hour limit 42 % used, weekly limit 84 % used, Codex: weekly limit 21 % used")
        let waiting = MetricsStrip.label(machine: [], vendors: [UsageVendorRow(vendor: .claude, lines: [], note: "Usage disconnected", warning: true)])
        #expect(waiting == "Claude: Usage disconnected")
    }

    @Test func clickingTheStripOpensMetrics() {
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        MetricsStrip.opener(activity)()
        #expect(activity.layout.selected == .metrics)
    }

    // MARK: - in the sidebar

    private func sidebarModel() -> SidebarModel {
        let folder = TestScratch.root.appendingPathComponent("shellforge-metrics-\(UUID().uuidString)")
        let launcher = CommandLauncher(resolve: { ResolvedEnvironment(variables: ["PATH": "/usr/bin"], source: .loginShell("/bin/zsh")) })
        return SidebarModel(host: FakeTerminalHost(), document: WorkspaceDocument(store: WorkspaceStore(folder: folder)),
                            launcher: launcher, jiraSettings: { nil })
    }

    private func hosted(_ activity: ActivityModel, controls: SidebarWindowControls?) -> (NSHostingView<AnyView>, NSWindow) {
        let hooks = AgentHooksModel(integrations: HookIntegrations(home: TestScratch.root.appendingPathComponent("metrics-home-\(UUID().uuidString)"),
                                                                   resources: .bundled(resourceURL: nil)), names: [:])
        let chrome = SidebarChrome()
        chrome.windowControls = controls
        let view = SidebarView(model: sidebarModel(), activity: activity, chooseFolder: { nil }, hooks: hooks,
                               machine: MachineMonitor(sensor: InertMachineSensor(), power: InertPower()),
                               backpack: BackpackController(ports: .inert, settings: BackpackSettings(defaults: nil), toast: { _ in }),
                               terminalMatch: TerminalMatchSettings(defaults: ScratchDefaults.make()),
                               feedback: FeedbackPrompt(defaults: ScratchDefaults.make(), channel: .dev), chrome: chrome,
                               showBackpack: { _ in }, showFeedback: { _ in }, hideSidebar: {}, agentTools: .none, agentsChanged: {})
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 600)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (host, window)
    }

    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap(descendants) }

    /// The marks named `name` that are drawn: no view between one and `host` hidden or transparent.
    private func shown(_ name: String, in host: NSView) -> [NSView] {
        host.layoutSubtreeIfNeeded()
        return descendants(of: host).filter { mark in
            mark.identifier?.rawValue == name
                && !sequence(first: mark, next: \.superview).prefix { $0 !== host }.contains { $0.isHidden || $0.alphaValue == 0 }
        }
    }

    /// With no vendor in use the Metrics panel leaves out USAGE, heading and rule; one vendor brings it back.
    @Test func theUsageGroupIsLeftOutWithoutVendors() {
        for (rows, expected) in [([UsageVendorRow](), 0), ([vendor(.claude)], 1)] {
            let footer = NSHostingView(rootView: AnyView(SidebarFooter(task: nil, rows: rows, machine: cpu)
                .interfaceScale(.standard).frame(width: Size.sidebarWidth)))
            footer.frame = NSRect(x: 0, y: 0, width: Size.sidebarWidth, height: 300)
            footer.layoutSubtreeIfNeeded()
            #expect(shown(SidebarFooter.usageMarkName, in: footer).count == expected, "\(rows.count) vendor rows")
        }
    }

    /// One strip under whichever panel shows, at the panel's foot; the full footer only on Metrics.
    @Test(arguments: [nil, SidebarWindowControls(buttonsMaxX: 70, buttonsMidY: 20)])
    func theStripIsPinnedUnderEveryPanel(controls: SidebarWindowControls?) throws {
        let activity = ActivityModel(source: ActivityOrderSource(defaults: nil))
        let (host, window) = hosted(activity, controls: controls)
        defer { window.close() }
        for panel in ActivityPanel.allCases {
            activity.select(panel)
            let strips = shown(MetricsStrip.markName, in: host)
            #expect(strips.count == 1, "\(strips.count) strips on \(panel.title)")
            let strip = try #require(strips.first)
            // In window coordinates the origin is the bottom-left: the strip sits on the bottom edge.
            let frame = strip.convert(strip.bounds, to: nil)
            #expect(frame.minY < 1, "the strip on \(panel.title) is not at the foot (\(frame))")
            #expect(abs(frame.height - MetricsStrip.height(.standard)) < 0.5, "the strip on \(panel.title) is \(frame.height) high")
            // The panel above ends where the strip begins: the two lines cover none of its content.
            if panel == .metrics, let content = shown(MetricsPanel.markName, in: host).first {
                #expect(content.convert(content.bounds, to: nil).minY >= frame.maxY - 0.5, "the strip overlaps the Metrics panel")
            }
            #expect(shown(MetricsPanel.markName, in: host).count == (panel == .metrics ? 1 : 0),
                    "the full footer on \(panel.title)")
        }
    }
}
