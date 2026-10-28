// Ported from AiTerm (app/Sources/AiTerm/Prompter.swift), GPLv3, Laurens D'Hondt.
import AppKit

/// One modal question: a message, the detail under it, its buttons and an optional checkbox — with,
/// under it, an optional second one that only counts while the first is ticked. A value, so a test can read what was asked and answer it without a window.
///
/// The first button is the one default: it answers ↩ and is drawn blue — or red, with
/// `defaultDeletes`, when it deletes files or commits. Every other button is the plain grey one; no
/// other button can be marked destructive, because nothing here says so. ⎋ answers `escapeButton`,
/// the safe choice, which may be the default itself (Keep Task).
public struct AlertPrompt: Equatable, Sendable {
    public var message: String
    public var detail = ""
    public var buttons = ["OK"]
    public var checkbox: String?
    /// Indented under `checkbox`, and enabled only while that is ticked: Also delete branch, under
    /// Also delete the worktree — git keeps a branch a worktree has checked out.
    public var subCheckbox: String?
    /// The default button deletes files or commits: Remove on a task, Delete Branch.
    public var defaultDeletes = false
    /// The button ⎋ answers, when it is not the one titled Cancel or the only one.
    public var escape: Int?

    public init(message: String, detail: String = "", buttons: [String] = ["OK"], checkbox: String? = nil,
                subCheckbox: String? = nil, defaultDeletes: Bool = false, escape: Int? = nil) {
        self.message = message; self.detail = detail; self.buttons = buttons; self.checkbox = checkbox
        self.subCheckbox = subCheckbox; self.defaultDeletes = defaultDeletes; self.escape = escape
    }

    /// Which button ⎋ answers: `escape`, else the one titled Cancel, else a lone button. `nil` leaves
    /// ⎋ unanswered — an alert with no safe choice.
    public var escapeButton: Int? {
        escape ?? buttons.firstIndex(of: "Cancel") ?? (buttons.count == 1 ? 0 : nil)
    }
}

public struct AlertAnswer: Equatable, Sendable {
    /// Index into `AlertPrompt.buttons`.
    public var button: Int
    public var checked = false
    /// `subCheckbox` ticked — never without `checked`.
    public var subChecked = false
    /// Whether the default — first — button was chosen: Remove, Delete Branch.
    public var confirmed: Bool { button == 0 }

    public init(button: Int, checked: Bool = false, subChecked: Bool = false) {
        self.button = button; self.checked = checked; self.subChecked = checked && subChecked
    }
}

/// Where the sidebar's modal questions go. `ModalPrompter` shows them; tests answer them from a
/// script.
///
/// A question is an `await`. While it is up, anything else the app does can run — a tab closing,
/// another Remove — and the caller re-checks after it. The alert itself comes up on a later turn of
/// the main run loop, so it is never run inside a SwiftUI menu action, where one comes up without
/// its accessory view.
@MainActor
public protocol Prompter: AnyObject {
    func ask(_ prompt: AlertPrompt) async -> AlertAnswer
}

/// Answers every question with its safe choice: a sidebar the app has not handed a prompter yet
/// changes nothing it would have asked about.
@MainActor
final class NullPrompter: Prompter {
    func ask(_ prompt: AlertPrompt) async -> AlertAnswer { AlertAnswer(button: prompt.escapeButton ?? 1) }
}

@MainActor
public final class ModalPrompter: Prompter {
    public init() {}

    /// ⎋ as `NSButton.keyEquivalent` spells it.
    static let escapeKey = "\u{1b}"

    /// The alert `prompt` describes, not yet shown. NSAlert gives the first button ↩ and a button
    /// titled Cancel ⎋ by itself; any other safe button is handed ⎋ here. A safe button that is also
    /// the default keeps ↩ — a button holds one key — and `ask` answers ⎋ for it instead.
    static func alert(for prompt: AlertPrompt) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = prompt.message
        alert.informativeText = prompt.detail
        for title in prompt.buttons { alert.addButton(withTitle: title) }
        alert.buttons.first?.hasDestructiveAction = prompt.defaultDeletes
        if let escape = prompt.escapeButton, escape > 0, alert.buttons.indices.contains(escape) {
            alert.buttons[escape].keyEquivalent = escapeKey
        }
        alert.accessoryView = prompt.checkbox.map { title in
            prompt.subCheckbox.map { CheckboxPair(title, sub: $0) } ?? NSButton(checkboxWithTitle: title, target: nil, action: nil)
        }
        return alert
    }

    /// On the next turn of the main run loop rather than under the caller.
    public func ask(_ prompt: AlertPrompt) async -> AlertAnswer {
        await withCheckedContinuation { answered in
            RunLoop.main.perform { MainActor.assumeIsolated { answered.resume(returning: Self.askBlocking(prompt)) } }
        }
    }

    private static func askBlocking(_ prompt: AlertPrompt) -> AlertAnswer {
        let alert = alert(for: prompt)
        // ⎋ for a safe default, which is holding ↩: pressed through the button, as a click would be.
        let monitor = prompt.escapeButton == 0 ? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.window === alert.window, event.charactersIgnoringModifiers == escapeKey,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
            alert.buttons.first?.performClick(nil)
            return nil
        } : nil
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        let response = alert.runModal()
        let pair = alert.accessoryView as? CheckboxPair
        return AlertAnswer(button: response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue,
                           checked: (pair?.main ?? alert.accessoryView as? NSButton)?.state == .on,
                           subChecked: pair?.sub.state == .on)
    }
}

/// Two checkboxes, the second indented under the first and enabled only while it is ticked;
/// unticking the first unticks the second. Laid out by frame.
final class CheckboxPair: NSView {
    let main: NSButton
    let sub: NSButton

    init(_ title: String, sub subTitle: String) {
        main = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        sub = NSButton(checkboxWithTitle: subTitle, target: nil, action: nil)
        main.sizeToFit(); sub.sizeToFit()
        let indent: CGFloat = 20, gap: CGFloat = 6
        let height = main.frame.height + gap + sub.frame.height
        super.init(frame: NSRect(x: 0, y: 0, width: max(main.frame.width, indent + sub.frame.width), height: height))
        main.setFrameOrigin(NSPoint(x: 0, y: sub.frame.height + gap))
        sub.setFrameOrigin(NSPoint(x: indent, y: 0))
        sub.isEnabled = false
        main.target = self
        main.action = #selector(mainToggled)
        addSubview(main); addSubview(sub)
    }

    required init?(coder: NSCoder) { nil }

    @objc private func mainToggled() {
        sub.isEnabled = main.state == .on
        if main.state != .on { sub.state = .off }
    }
}
