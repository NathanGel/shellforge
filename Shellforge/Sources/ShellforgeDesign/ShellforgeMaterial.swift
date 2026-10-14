import AppKit
import SwiftUI

/// How a Shellforge surface is translucent, decided in one place: macOS 26's glass, the system
/// sidebar material before it, and the opaque window colour whenever Reduce Transparency is on.
public enum ShellforgeMaterial {
    public enum Kind: Equatable, Sendable { case glass, sidebar, opaque }

    public static func kind(macOSMajor: Int, reduceTransparency: Bool) -> Kind {
        if reduceTransparency { return .opaque }
        return macOSMajor >= 26 ? .glass : .sidebar
    }

    /// This Mac's kind, now.
    @MainActor public static var current: Kind {
        kind(macOSMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion,
             reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
    }
}

/// `shape` filled with a Shellforge material.
public struct MaterialBackground<S: Shape>: View {
    let shape: S
    let kind: ShellforgeMaterial.Kind

    @MainActor public init(_ shape: S, kind: ShellforgeMaterial.Kind = ShellforgeMaterial.current) {
        self.shape = shape
        self.kind = kind
    }

    public var body: some View {
        switch kind {
        case .glass:
            if #available(macOS 26, *) {
                shape.fill(Color.clear).glassEffect(.regular, in: shape)
            } else {
                SidebarMaterial().clipShape(shape)
            }
        case .sidebar:
            SidebarMaterial().clipShape(shape)
        case .opaque:
            shape.fill(Palette.surface)
        }
    }
}

/// The system sidebar material, behind the window.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
