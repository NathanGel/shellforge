//
//  iTermShellforgeFeedback.swift
//  Shellforge
//
//  Help › Send Feedback…: the feedback sheet on the key window's sidebar, or GitHub's form when no
//  window can show it.
//

import AppKit
import ShellforgeCore
import ShellforgeUI

@objc(iTermShellforgeFeedback)
@MainActor
final class iTermShellforgeFeedback: NSObject {
    /// Opens the sheet over the key terminal window. With none, says what GitHub's form is, and opens it on a click.
    @objc static func sendFeedback() {
        if iTermShellforgeSidebar.feedbackSheets.present(for: iTermShellforgeSidebar.keyTerminal) {
            DLog("Shellforge: Send Feedback shows the sheet")
            return
        }
        DLog("Shellforge: Send Feedback has no window to show the sheet; offering GitHub")
        let openInGitHub = String(localized: "Shellforge.Feedback.OpenInGitHub",
                                  defaultValue: "Open in GitHub",
                                  comment: "Button in the Send Feedback warning, shown when no window can show the feedback sheet: opens Shellforge’s feedback form on GitHub")
        let heading = String(localized: "Shellforge.Feedback.Heading",
                             defaultValue: "Send Feedback",
                             comment: "Heading of the warning shown by Help › Send Feedback… when no window can show the feedback sheet")
        let selection = iTermWarning.show(withTitle: FeedbackFormPresentation.githubWarning,
                                          actions: [iTermWarningAction.localOnlyAction(withLabel: openInGitHub), iTermLocalizedCancel()],
                                          actionMapping: nil,
                                          accessory: nil,
                                          identifier: nil,
                                          silenceable: .kiTermWarningTypePersistent,
                                          heading: heading,
                                          cancelLabel: iTermLocalizedCancel(),
                                          window: nil)
        guard selection == .kiTermWarningSelection0 else { return }
        let empty = FeedbackSubmission(versions: .current, good: "", bad: "", rating: nil)
        NSWorkspace.shared.open(FeedbackLink.form(empty).url)
    }
}
