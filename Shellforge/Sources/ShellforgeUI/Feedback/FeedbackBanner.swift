import ShellforgeDesign
import SwiftUI

/// The sidebar's now-and-then ask: how Shellforge is working, with three ways to answer.
struct FeedbackBanner: View {
    enum Choice { case give, notNow, never }

    static let text = "How’s Shellforge working for you?"

    static func title(_ choice: Choice) -> String {
        switch choice {
        case .give: "Give Feedback…"
        case .notNow: "Not Now"
        case .never: "Don’t Ask Again"
        }
    }

    @ObservedObject var prompt: FeedbackPrompt
    let giveFeedback: () -> Void
    @Environment(\.interfaceScale) private var scale

    /// Giving feedback only asks for the form; the form counts the ask when it really opens.
    /// The other answers move the next ask.
    func answer(_ choice: Choice) {
        switch choice {
        case .give: giveFeedback()
        case .notNow: prompt.notNow()
        case .never: prompt.dontAskAgain()
        }
    }

    var body: some View {
        NoticeGround(tone: .info) {
            VStack(alignment: .leading, spacing: scale(Space.snug)) {
                NoticeLine(text: Self.text, tone: .info)
                // Side by side while they fit; stacked at a large zoom, so none is cut off.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: scale(Space.block)) { buttons }
                    VStack(alignment: .leading, spacing: scale(Space.tight)) { buttons }
                }
                .padding(.leading, scale(Space.block))
            }
        }
    }

    @ViewBuilder private var buttons: some View {
        button(.give)
        button(.notNow)
        button(.never)
    }

    private func button(_ choice: Choice) -> some View {
        Button(Self.title(choice)) { answer(choice) }
            .buttonStyle(.link).font(Typography.help)
    }
}
