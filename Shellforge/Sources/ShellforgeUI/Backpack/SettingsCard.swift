// Ported from AiTerm (app/Sources/AiTerm/Views/SettingsCard.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign

/// A card's status line: a tone and one sentence. A test result replaces it in place, so the
/// answer lands beside the thing that was tested rather than in the sheet's footer.
struct SettingsStatus: Equatable {
    var tone: SettingsTone
    var text: String

    /// A status line is not a sentence, so it carries no full stop — including the one ending an
    /// error's own description ("Driver is not installed.", "Couldn’t connect to Jira. …") that
    /// arrives here as the line. An ellipsis stays.
    init(_ tone: SettingsTone, _ text: String) {
        self.tone = tone
        self.text = text.hasSuffix(".") && !text.hasSuffix("..") ? String(text.dropLast()) : text
    }
}

/// One row of a Settings section — the Mac, Jira, GitLab — drawn in its `SettingsSection`'s box,
/// as a grouped form's row is: no box of its own. Its header is a sidebar row's anatomy: a round
/// mark, a title with optional chips beside it, a status line under it, and the row's actions
/// trailing. Fields sit under the header.
struct SettingsCard<Mark: View, Chips: View, Actions: View, Content: View>: View {
    let title: String
    let status: SettingsStatus
    let mark: Mark
    let chips: Chips
    let actions: Actions
    let content: Content

    /// The mark matches the actions beside it, so the header's two ends share one height.
    static var markSize: CGFloat { Size.control }
    /// Every button in a sheet is a `Size.control` control — the footer's Cancel and Save included.
    static var actionControlSize: ControlSize { .large }

    init(title: String, status: SettingsStatus,
         @ViewBuilder mark: () -> Mark,
         @ViewBuilder chips: () -> Chips,
         @ViewBuilder actions: () -> Actions,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.status = status
        self.mark = mark()
        self.chips = chips()
        self.actions = actions()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.block) {
            header
            content
        }
        .padding(Space.block)
    }

    private var header: some View {
        HStack(spacing: Space.inset) {
            mark.frame(width: Self.markSize, height: Self.markSize)
            VStack(alignment: .leading, spacing: Space.tight) {
                HStack(spacing: Space.snug) {
                    Text(title).font(Typography.card).foregroundStyle(Palette.text)
                    chips
                }
                HStack(spacing: Space.tight) {
                    ToneDot(tone: status.tone, size: Size.statusMarkSmall)
                    Text(status.text).font(Typography.help).foregroundStyle(status.tone.color)
                        .lineLimit(1).truncationMode(.tail)
                        .help(status.text)
                }
            }
            Spacer(minLength: Space.base)
            HStack(spacing: Space.base) { actions }
                .controlSize(Self.actionControlSize)
        }
    }
}

extension SettingsCard where Chips == EmptyView, Actions == EmptyView {
    /// A card with nothing beside its title and no actions: a service's, or iTerm2's.
    init(title: String, status: SettingsStatus,
         @ViewBuilder mark: () -> Mark,
         @ViewBuilder content: () -> Content) {
        self.init(title: title, status: status, mark: mark, chips: { EmptyView() }, actions: { EmptyView() }, content: content)
    }
}

/// A Settings group that connects and tests nothing — Sidebar size, Sidebar badges, each keyboard
/// group: a `SettingsCard`'s box and rule without its mark, status line or actions. A heading over
/// one line of `HelpText`, a `Hairline`, then the rows, one heading gap (`Space.gap`) either side of
/// the rule and between the rows, so every group in Settings starts its rows at the same depth.
/// The rows draw their own `Hairline` between them where they want one.
struct SettingsGroup<Rows: View>: View {
    let title: String
    let help: String
    let rows: Rows

    init(title: String, help: String, @ViewBuilder rows: () -> Rows) {
        self.title = title
        self.help = help
        self.rows = rows()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            VStack(alignment: .leading, spacing: Space.tight) {
                Text(title).font(Typography.card).foregroundStyle(Palette.text)
                HelpText(help)
            }
            Hairline()
            rows
        }
        .padding(Space.block)
        .groupChrome()
    }
}

/// A Settings switch: a small trailing toggle whose title, hidden, is what VoiceOver reads. The
/// row beside it shows the same title in its own type.
struct SettingsSwitch: View {
    let title: String
    let isOn: Binding<Bool>

    var body: some View {
        Toggle(title, isOn: isOn).labelsHidden().toggleStyle(.switch).controlSize(.small)
    }
}

/// A service's round mark on a Settings card, drawn to `VendorMark`'s recipe — a filled disc with
/// the logo placed by `LogoFit` — so Jira, GitLab, GitHub and iTerm2 sit in the same family as the harness
/// marks.
struct IntegrationMark: View {
    enum Service { case jira, gitlab, github, iterm }

    let service: Service
    let size: CGFloat

    var body: some View {
        ZStack {
            switch service {
            case .jira:
                Circle().fill(Palette.jira.color)
                Icon(.brand(Palette.jira), size: size * LogoFit.jira.scale, tint: Palette.markPaper)
                    .offset(x: size * LogoFit.jira.dx, y: size * LogoFit.jira.dy)
            case .gitlab:
                // White, as the Codex disc is: the four-colour tanuki is drawn for a
                // light ground.
                Circle().fill(Palette.markPaper)
                Icon(.gitlabTanuki, size: size * LogoFit.standard.scale)
            case .github:
                // White, as GitLab's disc is, with the mark in black.
                Circle().fill(Palette.markPaper)
                Icon(.brand(Palette.github), size: size * LogoFit.standard.scale, tint: Palette.markInk)
            case .iterm:
                // iTerm2's own icon is a terminal prompt on black, which is the shell mark already.
                VendorMark(agent: .shell, size: size)
            }
        }
        .frame(width: size, height: size)
    }
}

/// Numbered steps below a card's rule, or on a sheet: a `Typography.mono` number in
/// `Palette.muted` beside a `Typography.caption` step, `Space.snug` apart. The iTerm2 card's mending
/// steps, the Mac card's missing permissions and the Backpack sheet's phone steps.
struct NumberedSteps: View {
    let steps: [String]
    /// Steps already done, kept as help: the text in `Palette.muted` like the numbers.
    let receded: Bool

    init(_ steps: [String], receded: Bool = false) {
        self.steps = steps
        self.receded = receded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.snug) {
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: Space.base) {
                    Text("\(index + 1)").font(Typography.mono).foregroundStyle(Palette.muted)
                    Text(step).font(Typography.caption).foregroundStyle(receded ? Palette.muted : Palette.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// The rule between two rows of a Settings section, as a grouped form draws it: inset past the
/// row's mark, so the marks run down the box's edge unbroken.
struct SettingsRowDivider: View {
    var body: some View {
        Hairline().padding(.leading, Space.block + SettingsCard<EmptyView, EmptyView, EmptyView, EmptyView>.markSize + Space.inset)
    }
}

/// A Settings section as macOS's grouped form draws one — Core, Services: a heading in
/// `Typography.bodyEmphasis` lined up with the rows' marks, then one filled box holding the rows,
/// a `SettingsRowDivider` between each two.
struct SettingsSection<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.gap) {
            Text(title).font(Typography.bodyEmphasis).foregroundStyle(Palette.text)
                .padding(.leading, Space.block)
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: Radius.group, style: .continuous).fill(Palette.groupFill))
        }
    }
}
