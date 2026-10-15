import AppKit
import SwiftUI
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
import ShellforgeDesign
@testable import ShellforgeUI

@MainActor @Suite struct NewTaskSheetTests {
    private func model() -> NewTaskModel {
        NewTaskModel(project: Project(name: "demo", path: "/tmp/demo"), agents: AgentPresets.all, available: ["claude"],
                     draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), rememberedModels: [:],
                     catalogue: { _ in [] }, branches: { ["main"] }, submit: { _ in },
                     home: TestScratch.root.appendingPathComponent("nts-home-\(UUID().uuidString)"))
    }

    @Test func theSheetIsAiTermsSizeAndLightInALightWindow() throws {
        let parent = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        parent.appearance = NSAppearance(named: .aqua)
        let slot = PanelSlot()
        let panel = slot.present(over: parent) { dismiss in NewTaskSheet(model: model(), dismiss: dismiss) }
        defer { slot.dismiss() }
        let content = try #require(panel.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(content.fittingSize.width == Sheet.width)
        let bitmap = try #require(Snapshot.bitmap(of: content))
        let ground = try #require(bitmap.colorAt(x: Int((content.bounds.width - 6) * Snapshot.scale), y: Int(content.bounds.height / 2 * Snapshot.scale))?.usingColorSpace(.sRGB))
        #expect(ground.brightnessComponent > 0.7, "a light window's sheet draws light: \(ground)")
    }

    /// ⎋ and Back are one move: a step back, or the sheet closed from the first step — and while a
    /// create runs, the create cancelled: the way out of one stuck in a checkout hook.
    @Test func escapeGoesBackThenCancels() {
        #expect(NewTaskSheet.back(from: 3, creating: false) == .step(2))
        #expect(NewTaskSheet.back(from: 2, creating: false) == .step(1))
        #expect(NewTaskSheet.back(from: 1, creating: false) == .dismiss)
        #expect(NewTaskSheet.back(from: 3, creating: true) == .cancelCreate)
    }

    /// While creating, the footer says the step — and its Cancel, live, cancels.
    @Test func theFooterSaysWhatACreateIsDoing() {
        #expect(CreationFooter.progressText(nil, cancelling: false) == "Creating…")
        #expect(CreationFooter.progressText(.fetching(base: "main"), cancelling: false) == "Fetching origin/main…")
        #expect(CreationFooter.progressText(.creatingWorktree(runsHook: false), cancelling: false) == "Creating the worktree…")
        #expect(CreationFooter.progressText(.creatingWorktree(runsHook: true), cancelling: false)
                == "Running the repository’s checkout hook…")
        #expect(CreationFooter.progressText(.fetching(base: "main"), cancelling: true) == "Cancelling…")
    }

    /// While a create runs, ⎋ is Cancel even when a completion popup was left open: the popup's
    /// list is never asked, so one ⎋ always reaches the way out.
    @Test func escapeCancelsACreateEvenWithAListOpen() {
        var asked = false
        let open = { asked = true; return true }
        #expect(!CreationFooter.listCloser(creating: true, open)())
        #expect(!asked)
        #expect(CreationFooter.listCloser(creating: false, open)())
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

    /// As AiTerm: the footer warns only when no agent can run at all; the Agent step names the
    /// missing ones either way.
    @Test func theFooterWarnsOnlyWhenNoAgentIsInstalled() {
        #expect(NewTaskSheet.footerNote(agents: AgentPresets.all, available: ["claude"]) == nil)
        #expect(NewTaskSheet.footerNote(agents: AgentPresets.all, available: [])
                == "Claude Code, Codex, Grok Build and PI aren’t installed. Install them, then click Reload in Settings › Core › Environment.")
    }

    /// Once Create is pressed nothing in the sheet takes typing: the prompt and every field are
    /// locked until the create ends — the draft is already on its way.
    @Test func whileCreatingNothingTakesTyping() async throws {
        let opus = AgentModel(id: "opus", label: "Opus", detail: nil, efforts: ["low", "high"], defaultEffort: "high")
        let model = NewTaskModel(project: Project(name: "demo", path: "/tmp/demo"), agents: AgentPresets.all, available: ["claude"],
                                 draft: TaskDraft(baseBranch: "main", agentId: "claude", model: "", reasoning: nil), rememberedModels: [:],
                                 catalogue: { _ in [opus] }, branches: { ["main"] }, submit: { _ in
                                     while CreationContext.cancellation?.isCancelled == false { try await Task.sleep(for: .milliseconds(5)) }
                                     throw CreationCancelled() },
                                 home: TestScratch.root.appendingPathComponent("lock-home-\(UUID().uuidString)"))
        model.draft.setTitle("Login")
        await model.loadCatalogue()
        for step in [1, 3] {
            let host = NSHostingView(rootView: NewTaskSheet(model: model, dismiss: {}).seeded(step: step))
            host.frame = NSRect(x: 0, y: 0, width: Sheet.width, height: Sheet.height)
            let window = NSWindow(contentRect: host.frame, styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            async let created = model.create()
            #expect(await eventually(describing: "the editors to lock on step \(step)") {
                host.layoutSubtreeIfNeeded()
                let fields = descendants(of: NSTextField.self, in: host).filter { $0.isEditable || !$0.isEnabled }
                let texts = descendants(of: NSTextView.self, in: host)
                return !fields.isEmpty || !texts.isEmpty ? (fields.allSatisfy { !$0.isEditable } && texts.allSatisfy { !$0.isEditable }) : false
            })
            model.cancelCreate()
            _ = await created
            window.close()
        }
    }

    private func descendants<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        view.subviews.compactMap { $0 as? T } + view.subviews.flatMap { descendants(of: type, in: $0) }
    }
}

