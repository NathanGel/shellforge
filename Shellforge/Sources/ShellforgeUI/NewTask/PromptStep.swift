// Ported from AiTerm (app/Sources/AiTerm/Views/Steps/PromptStep.swift), GPLv3, Laurens D'Hondt.
import ShellforgeDesign
import SwiftUI

/// Step 3: the first prompt, with AiTerm's `/` popup of the agent's commands and skills and its
/// hint. New Task's Jira checkbox arrives with M1d.
struct PromptStep: View {
    @Binding var text: String
    let agentId: String
    let completions: PromptCompletions
    @State private var editorFocused = false

    /// The empty-prompt placeholder sits where `PromptEditor`'s first glyph would: across, its text
    /// inset plus the container's line-fragment padding; down, its text inset plus
    /// ``placeholderDrop``. Read from the editor, so the two move together if its inset changes.
    private static var placeholderInsetX: CGFloat { PromptEditor.textInset.width + PromptEditor.lineFragmentPadding }
    private static var placeholderInsetY: CGFloat { PromptEditor.textInset.height + placeholderDrop }
    /// A point further down, fitted to where the text view draws its first line rather than derived
    /// from it; bespoke to this one overlay.
    private static var placeholderDrop: CGFloat { 1 }
    /// Trimmed further than the sheet's own gutters (`Space.margin` on each side) so the completion
    /// popup doesn't run to the prompt field's own edge. Tuned by eye, not derived from a scale.
    private static var completionPopupTrim: CGFloat { 40 }
    /// The prompt editor's height. Moved with the step; it was a literal here before.
    private static var editorHeight: CGFloat { 150 }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            FormField("First prompt (optional)") {
                ZStack(alignment: .topLeading) {
                    PromptEditor(text: $text, agentId: agentId, completions: completions,
                                 onFocusChange: { if editorFocused != $0 { editorFocused = $0 } }, focusOnAppear: true)
                        .frame(height: Self.editorHeight)
                        .fieldBox(focused: editorFocused)
                    if text.isEmpty {
                        Text("Describe what the agent should do.").font(Typography.promptMono).foregroundStyle(Palette.placeholder)
                            .padding(.horizontal, Self.placeholderInsetX).padding(.top, Self.placeholderInsetY).allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .topLeading) {
                    CompletionPopup(completions: completions,
                                    width: Sheet.width - 2 * Space.margin - Self.completionPopupTrim)
                }
                // Over the hint below it: AiTerm's FrontToBackStack, which needs macOS 15.
                .zIndex(1)
                CompletionHint()
            }
        }
    }
}
