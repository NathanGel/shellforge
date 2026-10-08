import AppKit
import SwiftUI

/// The sidebar on the left of a Shellforge window: projects → tasks → tabs. In M0 it is a
/// placeholder that proves the window can hold it; the tree arrives in M1.
@MainActor
public enum ShellforgeSidebar {
    /// Its width in points. The window's layout gives the session area what is left.
    public static let width: CGFloat = 240

    /// The view the window places at its left edge: as wide as the sidebar, and only its height
    /// follows the window's.
    public static func makeView() -> NSView {
        let host = NSHostingView(rootView: SidebarView())
        host.frame = NSRect(x: 0, y: 0, width: width, height: 400)
        host.autoresizingMask = [.height]
        return host
    }
}

struct SidebarView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Shellforge")
                .font(.headline)
            Text("No projects yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(16)
        .frame(width: ShellforgeSidebar.width, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.regularMaterial)
    }
}
