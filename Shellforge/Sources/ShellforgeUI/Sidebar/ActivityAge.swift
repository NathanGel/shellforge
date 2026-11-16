import Foundation
import ShellforgeCore
import ShellforgeDesign
import SwiftUI

/// How long ago a task's agent last reported its state: the word at the end of its row's title line.
enum ActivityAge {
    /// `now` under a minute (and for a clock a little ahead), then the largest whole unit: `4m`,
    /// `3h`, `2d`.
    static func text(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        let minutes = Int(seconds) / 60
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        return "\(hours / 24)d"
    }

    /// The newest exact report among `sessions`; nil while none has reported (a guessed status).
    static func lastReport(_ sessions: [SessionInfo]) -> Date? {
        sessions.compactMap(\.reportedAt).max().map { Date(timeIntervalSince1970: $0) }
    }
}

/// The age, redrawn each minute; nothing when there is no report.
struct ActivityAgeLabel: View {
    let since: Date?

    var body: some View {
        if let since {
            TimelineView(.periodic(from: since, by: 60)) { context in
                AgeText(text: ActivityAge.text(since: since, now: context.date))
            }
            .help(Self.help(since))
        }
    }

    static func help(_ since: Date) -> String {
        "Last report " + since.formatted(date: .omitted, time: .shortened)
    }
}

private struct AgeText: View {
    let text: String
    @Environment(\.surface) private var surface

    var body: some View {
        Text(text).font(Typography.help).foregroundStyle(surface.secondaryInk).lineLimit(1).fixedSize()
    }
}
