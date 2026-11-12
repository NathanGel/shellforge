// Ported from AiTerm (app/Sources/AiTerm/Prompter.swift), GPLv3, Laurens D'Hondt.
import Foundation

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

/// Where the sidebar's modal questions go. The app's `WarningPrompter` shows them; tests answer them
/// from a script.
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
