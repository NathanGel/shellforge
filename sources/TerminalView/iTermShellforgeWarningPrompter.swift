//
//  iTermShellforgeWarningPrompter.swift
//  Shellforge
//
//  Shows the Shellforge package's modal questions (`AlertPrompt`) as iTermWarnings, so the paired
//  iTerm2 Buddy app can see and answer them as it does every other warning.
//

import AppKit
import ShellforgeUI

/// Asks an `AlertPrompt` as an app-modal `iTermWarning`: the message is its bold heading, the detail
/// the text under it, and the buttons come in the prompt's order, the first the default — red when
/// `defaultDeletes`. ⎋ answers `escapeButton`. No button has a ⌘-letter shortcut, as with a plain
/// NSAlert: a reflex ⌘D must not press Delete Branch. The checkbox, and the sub-checkbox under it,
/// are the accessory view; the phone can set the checkbox, not the sub-checkbox, which counts as
/// it stands on the Mac. Never silenced: each is asked every time.
///
/// Every button is offered remotely: each one acts only in Shellforge.
@MainActor
final class WarningPrompter: Prompter {
    init() {}

    /// ⎋ as `NSButton.keyEquivalent` spells it.
    static let escapeKey = "\u{1b}"
    /// ↩, which NSAlert gives its first button.
    static let returnKey = "\r"

    /// One question, built and not yet shown, with the checkboxes its answer is read from.
    @MainActor
    struct Question {
        let warning: iTermWarning
        let checkbox: NSButton?
        let subCheckbox: NSButton?

        /// The answer `selection` (what `runModal` reported) gives to `prompt`. A warning that
        /// ended without a button — aborted — answers the safe choice, with nothing ticked, as
        /// `NullPrompter` does. With no safe choice, an index past the buttons: no button, never
        /// `confirmed`.
        func answer(_ selection: iTermWarningSelection, to prompt: AlertPrompt) -> AlertAnswer {
            let index = selection.rawValue
            guard prompt.buttons.indices.contains(index) else {
                DLog("Warning for \(prompt.message) ended with \(selection.rawValue); answering the safe choice")
                return AlertAnswer(button: prompt.escapeButton ?? prompt.buttons.count)
            }
            return AlertAnswer(button: index, checked: checkbox?.state == .on, subChecked: subCheckbox?.state == .on)
        }
    }

    /// The warning `prompt` describes. NSAlert gives the first button ↩ and a button titled Cancel ⎋
    /// by itself; any other safe button is handed ⎋ here. A safe button that is also the default
    /// keeps ↩ — a button holds one key — and `ask` answers ⎋ for it instead.
    static func question(for prompt: AlertPrompt) -> Question {
        it_assert(prompt.escapeButton != nil, "Every question needs a safe choice: \(prompt.message)")
        let warning = iTermWarning()
        warning.heading = prompt.message
        warning.title = prompt.detail
        warning.warningType = .kiTermWarningTypePersistent
        let actions = prompt.buttons.map { iTermWarningAction(label: $0, block: nil) }
        for action in actions {
            action.noAutomaticKeyEquivalent = true
        }
        actions.first?.destructive = prompt.defaultDeletes
        if let escape = prompt.escapeButton, actions.indices.contains(escape) {
            // The safe choice, for the phone as for ⎋ here.
            actions[escape].isCancel = true
            if escape > 0 {
                actions[escape].keyEquivalent = escapeKey
            }
        }
        warning.warningActions = actions
        guard let title = prompt.checkbox else {
            return Question(warning: warning, checkbox: nil, subCheckbox: nil)
        }
        let checkbox: NSButton
        let subCheckbox: NSButton?
        if let subTitle = prompt.subCheckbox {
            let pair = CheckboxPair(title, sub: subTitle)
            warning.accessory = pair
            checkbox = pair.main
            subCheckbox = pair.sub
        } else {
            checkbox = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            warning.accessory = checkbox
            subCheckbox = nil
        }
        // The phone shows and sets it as it does a warning's own “don't ask again” box. The
        // sub-checkbox has no such place, so the phone is told more is shown on the Mac.
        warning.remoteCheckbox = checkbox
        return Question(warning: warning, checkbox: checkbox, subCheckbox: subCheckbox)
    }

    /// The button ⎋ presses in `window`, an alert asking `prompt`, when its safe choice is its
    /// default: the ↩ button, titled as the prompt's first. Nil for any other key or prompt.
    static func defaultButton(answeringEscape event: NSEvent, in window: NSWindow, for prompt: AlertPrompt) -> NSButton? {
        guard prompt.escapeButton == 0, let first = prompt.buttons.first,
              event.charactersIgnoringModifiers == escapeKey,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else {
            return nil
        }
        return window.contentView.flatMap { button(in: $0) { $0.keyEquivalent == returnKey && $0.title == first } }
    }

    private static func button(in view: NSView, matching test: (NSButton) -> Bool) -> NSButton? {
        if let button = view as? NSButton, test(button) {
            return button
        }
        for subview in view.subviews {
            if let found = button(in: subview, matching: test) {
                return found
            }
        }
        return nil
    }

    /// On the next turn of the main run loop rather than under the caller, so never inside a
    /// SwiftUI menu action.
    func ask(_ prompt: AlertPrompt) async -> AlertAnswer {
        await withCheckedContinuation { answered in
            RunLoop.main.perform { MainActor.assumeIsolated { answered.resume(returning: Self.askBlocking(prompt)) } }
        }
    }

    private static func askBlocking(_ prompt: AlertPrompt) -> AlertAnswer {
        let question = question(for: prompt)
        // ⎋ for a safe default, which is holding ↩: pressed through the button, as a click would
        // be. Only in the modal alert in front, which while this waits is this warning's.
        let monitor = prompt.escapeButton == 0 ? NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard let window = event.window, window === NSApp.modalWindow,
                  let button = defaultButton(answeringEscape: event, in: window, for: prompt) else {
                return event
            }
            button.performClick(nil)
            return nil
        } : nil
        defer {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
        return question.answer(question.warning.runModal(), to: prompt)
    }

    /// Two checkboxes, the second indented under the first and enabled only while it is ticked;
    /// unticking the first unticks the second. Laid out by frame.
    final class CheckboxPair: NSView {
        let main: NSButton
        let sub: NSButton

        init(_ title: String, sub subTitle: String) {
            main = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            sub = NSButton(checkboxWithTitle: subTitle, target: nil, action: nil)
            main.sizeToFit()
            sub.sizeToFit()
            let indent: CGFloat = 20
            let gap: CGFloat = 6
            let height = main.frame.height + gap + sub.frame.height
            super.init(frame: NSRect(x: 0, y: 0, width: max(main.frame.width, indent + sub.frame.width), height: height))
            main.setFrameOrigin(NSPoint(x: 0, y: sub.frame.height + gap))
            sub.setFrameOrigin(NSPoint(x: indent, y: 0))
            sub.isEnabled = false
            main.target = self
            main.action = #selector(mainToggled)
            addSubview(main)
            addSubview(sub)
        }

        required init?(coder: NSCoder) {
            it_fatalError("init(coder:) is not supported")
        }

        @objc private func mainToggled() {
            sub.isEnabled = main.state == .on
            if main.state != .on {
                sub.state = .off
            }
        }
    }
}
