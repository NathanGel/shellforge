// Ported from AiTerm (app/Sources/AiTerm/Views/SidebarEmptyState.swift), GPLv3, Laurens D'Hondt.
import SwiftUI
import ShellforgeDesign

/// What sits under `PROJECTS` while there are none: what to add, what that gives you, and the
/// header's own Add Project action as a push button. Its text starts where the heading's does.
///
/// It is in the sidebar, so it reads its tokens through `scale`; the push button is an AppKit
/// bezel, which stops at `.large`, so it steps from `.regular` at ×1 to `.large` above it.
struct SidebarEmptyState: View {
    let canAdd: Bool
    let add: () -> Void
    @Environment(\.interfaceScale) private var scale

    var body: some View {
        VStack(alignment: .leading, spacing: scale(Space.base)) {
            VStack(alignment: .leading, spacing: scale(Space.tight)) {
                Text("Add a git repository to start.").font(Typography.body).foregroundStyle(Palette.text)
                    .fixedSize(horizontal: false, vertical: true)
                HelpText("Each task gets its own worktree and iTerm2 window.")
            }
            Button("Add Project…", action: add)
                .buttonStyle(.bordered)
                .controlSize(scale == .standard ? .regular : .large)
                .disabled(!canAdd)
                .padding(.top, scale(Space.tight))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, scale(Space.base))
        .padding(.top, scale(Space.tight)).padding(.bottom, scale(Space.block))
    }
}
