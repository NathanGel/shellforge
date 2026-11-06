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
        let selection = iTermWarning.show(withTitle: FeedbackFormPresentation.githubWarning,
                                          actions: [iTermWarningAction.localOnlyAction(withLabel: "Open in GitHub"), iTermLocalizedCancel()],
                                          actionMapping: nil,
                                          accessory: nil,
                                          identifier: nil,
                                          silenceable: .kiTermWarningTypePersistent,
                                          heading: "Send Feedback",
                                          cancelLabel: iTermLocalizedCancel(),
                                          window: nil)
        guard selection == .kiTermWarningSelection0 else { return }
        let empty = FeedbackSubmission(versions: .current, good: "", bad: "", rating: nil)
        NSWorkspace.shared.open(FeedbackLink.form(empty).url)
    }
}
