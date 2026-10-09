import AppKit
import SwiftUI
import Testing
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

@MainActor @Suite struct NewTaskSheetTests {
    private func model() -> NewTaskModel {
        NewTaskModel(project: Project(name: "demo", path: "/tmp/demo"), agents: AgentPresets.all, available: ["claude"],
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), rememberedModels: [:],
                     catalogue: { _ in [] }, branches: { ["main"] }, submit: { _ in })
    }

    @Test func theSheetIsAiTermsSizeAndDarkInALightWindow() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        let slot = PanelSlot()
        let panel = slot.present(over: parent) { dismiss in NewTaskSheet(model: model(), dismiss: dismiss) }
        defer { slot.dismiss() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.fittingSize.width == Sheet.width)
        let bitmap = try #require(content.bitmapImageRepForCachingDisplay(in: content.bounds))
        content.cacheDisplay(in: content.bounds, to: bitmap)
        let ground = try #require(bitmap.colorAt(x: Int(content.bounds.width) - 6, y: Int(content.bounds.height) / 2)?.usingColorSpace(.sRGB))
        #expect(ground.brightnessComponent < 0.3, "the sheet draws light: \(ground)")
    }

    /// ⎋ and Back are one move: a step back, or the sheet closed from the first step — never while
    /// a create runs.
    @Test func escapeGoesBackThenCancels() {
        #expect(NewTaskSheet.back(from: 3, creating: false) == .step(2))
        #expect(NewTaskSheet.back(from: 2, creating: false) == .step(1))
        #expect(NewTaskSheet.back(from: 1, creating: false) == .dismiss)
        #expect(NewTaskSheet.back(from: 3, creating: true) == .stay)
    }

    @Test func theDestinationNamesTheWorktreeAndBranch() {
        let project = Project(name: "demo", path: "/tmp/demo")
        #expect(Destination.worktree(project: project, slug: "login-2", branch: "feat/login").text
                == "Opens in Shellforge · demo/.worktrees/login-2 · feat/login")
        #expect(Destination.isShown(onStep: 1) && !Destination.isShown(onStep: 2) && Destination.isShown(onStep: 3))
    }

    @Test func anUninstalledAgentsSegmentIsNotSelectable() {
        #expect(AgentSegmented.isSelectable(AgentPresets.claude, available: ["claude"]))
        #expect(!AgentSegmented.isSelectable(AgentPresets.pi, available: ["claude"]))
    }
}
