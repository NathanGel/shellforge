import SwiftUI
import ShellforgeCore
import ShellforgeDesign

/// The feedback form: the public warning first, then the fields, and nothing typed is lost on a failure.
struct FeedbackSheet: View {
    @ObservedObject var model: FeedbackFormModel
    private typealias Copy = FeedbackFormPresentation

    var body: some View {
        SheetLayout(title: "Send Feedback", height: Sheet.height, locked: model.phase == .sending) {
            // Never cut off: why it matters, then the warning, which is the point of the sheet.
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(Copy.purpose).font(Typography.caption).foregroundStyle(Palette.text)
                Text(model.viaRelay ? Copy.relayWarning : Copy.githubWarning)
                    .font(Typography.caption).foregroundStyle(Palette.muted)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } content: {
            VStack(alignment: .leading, spacing: Space.block) {
                FormField(Copy.goodLabel) { editor($model.good) }
                FormField(Copy.missingLabel) { editor($model.bad) }
                FormField("How likely are you to keep using Shellforge?") {
                    SegmentedControl(values: [1, 2, 3, 4, 5] as [Int?], selection: $model.rating) { value, on in
                        Text(value.map(String.init) ?? "").font(on ? Typography.bodyEmphasis : Typography.body)
                    }
                }
                VStack(alignment: .leading, spacing: Space.tight) {
                    HelpText(Copy.alsoSent(model.versions))
                    if model.viaRelay { HelpText(Copy.ipNote) }
                }
                outcome
            }
        } footer: {
            SheetFooter(secondary: posted == nil ? "Cancel" : nil, primary: primary,
                        canSubmit: posted != nil || model.handedOff || model.canSend,
                        cancel: model.cancel,
                        submit: { posted != nil || model.handedOff ? model.done() : model.send() }) {
                if model.phase == .sending {
                    HStack(spacing: Space.base) {
                        ProgressView().controlSize(.small)
                        Text(Copy.sending).font(Typography.caption).foregroundStyle(Palette.muted)
                    }
                }
            }
        }
    }

    private var posted: Int? {
        if case .posted(let n) = model.phase { return n }
        return nil
    }

    private var primary: String? {
        switch model.phase {
        case .editing, .failed: return model.handedOff ? "Done" : Copy.primaryTitle(viaRelay: model.viaRelay)
        case .posted: return "Done"
        case .sending: return nil
        }
    }

    /// Return inserts a newline; Send is ⌘↩.
    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(Typography.body).foregroundStyle(Palette.text)
            .scrollContentBackground(.hidden)
            .padding(Space.snug)
            .frame(minHeight: Size.row * 1.5)
            .fieldBox()
    }

    @ViewBuilder private var outcome: some View {
        switch model.phase {
        case .failed(let failure):
            VStack(alignment: .leading, spacing: Space.base) {
                Text(failure.sentence).font(Typography.caption).foregroundStyle(Palette.amber)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: Space.base) {
                    VStack(alignment: .leading, spacing: Space.tight) {
                        Button("Open in GitHub") { model.openInGitHub() }
                        HelpText(Copy.githubWarning)
                    }
                    Button("Copy") { model.copyAll() }
                }
                if let note = model.note { HelpText(note) }
            }
        case .posted(let n):
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(Copy.thanks(n)).font(Typography.body).foregroundStyle(Palette.text)
                Link(FeedbackLink.issue(n).absoluteString, destination: FeedbackLink.issue(n)).font(Typography.caption)
            }
        default:
            VStack(alignment: .leading, spacing: Space.base) {
                if let until = model.blockedUntil {
                    Text(Copy.sentRecently(until)).font(Typography.caption).foregroundStyle(Palette.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    VStack(alignment: .leading, spacing: Space.tight) {
                        Button("Open in GitHub") { model.openInGitHub() }
                        HelpText(Copy.githubWarning)
                    }
                }
                if let note = model.note { HelpText(note) }
            }
        }
    }
}
