import AppKit

/// What a view draws, for tests that read pixels: always at 2×. A view's own
/// `bitmapImageRepForCachingDisplay` follows the screens attached, and a 1× monitor beside a
/// Retina display moved a measured edge by whole points.
public enum Snapshot {
    public static let scale: CGFloat = 2

    @MainActor
    public static func bitmap(of view: NSView, in rect: NSRect? = nil) -> NSBitmapImageRep? {
        let bounds = rect ?? view.bounds
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded(.up)),
                                            pixelsHigh: Int((bounds.height * scale).rounded(.up)), bitsPerSample: 8,
                                            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                            bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        bitmap.size = bounds.size
        view.cacheDisplay(in: bounds, to: bitmap)
        return bitmap
    }
}
