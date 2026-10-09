// Ported from AiTerm (app/Tests/AiTermUITests/TestSupport.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import Testing
@testable import ShellforgeDesign

// Helpers every ShellforgeDesign suite shares: hosting a view in a window, letting it settle, reading what
// it drew, and reading the environment it was drawn in.

/// Hosts `host` as the content of a titled window at its current frame — key and on screen unless
/// `orderFront` is false, for a test that needs a window but not the keyboard. The caller orders an
/// on-screen one out when done.
@MainActor func window(hosting host: NSView, orderFront: Bool = true) -> NSWindow {
    let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    window.contentView = host
    if orderFront { window.makeKeyAndOrderFront(nil) }
    return window
}

/// One turn of the run loop, then layout: long enough for SwiftUI to push a state change into a
/// hosted AppKit view.
@MainActor func settle(_ host: NSView) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    host.layoutSubtreeIfNeeded()
}

/// What `view` drew, as PNG data, for comparing two renders.
@MainActor func pixels(in view: NSView) throws -> Data {
    let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
    view.cacheDisplay(in: view.bounds, to: bitmap)
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

/// The brightest pixel `view` draws over black — composited, so a translucent grey stays grey and
/// an amber stays amber. Drawn under `.darkAqua`, the only appearance AiTerm draws in: left to the
/// system's, a Mac set to switch automatically draws the semantic colours light by day.
@MainActor func brightestPixel(of view: some View) -> NSColor? {
    let host = NSHostingView(rootView: view.fixedSize().padding(4).background(Color.black))
    host.appearance = NSAppearance(named: .darkAqua)
    host.frame = NSRect(origin: .zero, size: host.fittingSize)
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    var best: NSColor?
    var bestLight: CGFloat = -1
    for x in 0..<bitmap.pixelsWide {
        for y in 0..<bitmap.pixelsHigh {
            guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let light = pixel.redComponent + pixel.greenComponent + pixel.blueComponent
            if light > bestLight { bestLight = light; best = pixel }
        }
    }
    return best
}

extension NSView {
    /// The first descendant of `type`, depth first.
    func firstSubview<T: NSView>(of type: T.Type) -> T? {
        for subview in subviews {
            if let match = subview as? T ?? subview.firstSubview(of: type) { return match }
        }
        return nil
    }
}

/// What each `EnvironmentReader` saw, by its id.
final class EnvironmentLog {
    var surface: [Int: Surface] = [:]
    var isEnabled: [Int: Bool] = [:]
}

/// Records the surface and the enabled state it is drawn in, so a test can ask what ground and
/// state a primitive hands its content without rendering pixels.
struct EnvironmentReader: View {
    var id = 0
    let log: EnvironmentLog
    @Environment(\.surface) private var surface
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        log.surface[id] = surface
        log.isEnabled[id] = isEnabled
        return Text("\(id)")
    }
}
