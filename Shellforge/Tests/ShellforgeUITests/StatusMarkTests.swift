// Ported from AiTerm (app/Tests/AiTermTests/StatusMarkTests.swift), GPLv3, Laurens D'Hondt.
import AppKit
import SwiftUI
import ShellforgeDesign
import Testing
@testable import ShellforgeTestSupport
@testable import ShellforgeCore
@testable import ShellforgeUI

@MainActor
struct StatusMarkTests {
    private let size: CGFloat = 40

    @Test func spinnerRotationUsesAContinuousSharedClock() {
        let start = Date(timeIntervalSinceReferenceDate: 220)
        let quarterTurn = start.addingTimeInterval(0.275)
        let nextCycle = start.addingTimeInterval(1.1)
        let startRotation = StatusMark.spinnerRotation(at: start)
        let quarterRotation = StatusMark.spinnerRotation(at: quarterTurn)
        let nextCycleRotation = StatusMark.spinnerRotation(at: nextCycle)
        let quarterAdvance = (quarterRotation - startRotation + 360)
            .truncatingRemainder(dividingBy: 360)

        #expect(abs(quarterAdvance - 90) < 0.0001)
        let cycleDifference = abs(nextCycleRotation - startRotation)
        #expect(min(cycleDifference, 360 - cycleDifference) < 0.0001)
    }

    private func solidFillRatio(for status: SessionState, color: Color) throws -> Double {
        let view = StatusMark(status: status, size: size)
            .background(Color.black)
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: size, height: size)
        host.appearance = NSAppearance(named: .darkAqua)
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(Snapshot.bitmap(of: host))
        let expected = try #require(NSColor(color).usingColorSpace(.sRGB))
        let scale = CGFloat(bitmap.pixelsWide) / size
        let center = CGFloat(bitmap.pixelsWide - 1) / 2
        let sampleRadius = size * scale * 0.3
        var matching = 0
        var sampled = 0

        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                guard hypot(CGFloat(x) - center, CGFloat(y) - center) <= sampleRadius,
                      let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                sampled += 1
                let difference = abs(pixel.redComponent - expected.redComponent)
                    + abs(pixel.greenComponent - expected.greenComponent)
                    + abs(pixel.blueComponent - expected.blueComponent)
                if difference < 0.08 { matching += 1 }
            }
        }

        return Double(matching) / Double(sampled)
    }

    @Test func doneIsASolidBlueDot() throws {
        #expect(try solidFillRatio(for: .done, color: Palette.done) > 0.98)
    }

    @Test func needsInputIsASolidAmberDot() throws {
        #expect(try solidFillRatio(for: .needsInput, color: Palette.amber) > 0.98)
    }

    /// A window the mark is really in, so SwiftUI runs its animations: a view that is not on
    /// screen never ticks.
    private func hostInWindow(_ view: some View) -> (NSWindow, NSHostingView<some View>) {
        let host = NSHostingView(rootView: view.background(Color.black))
        host.appearance = NSAppearance(named: .darkAqua)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        return (window, host)
    }

    @Observable fileprivate final class StatusModel {
        var status = SessionState.working
        var surface = Surface.sidebar
    }

    fileprivate struct Mark: View {
        let model: StatusModel
        let size: CGFloat
        var body: some View { StatusMark(status: model.status, size: size).surface(model.surface) }
    }

    /// How far the arc is from where the shared clock puts it, in degrees, read off the pixels: the
    /// bright pixels' direction (clockwise from three o'clock, the way the arc turns) less the
    /// arc's own midpoint (27 degrees: it spans 15 % of the circle) less the clock's rotation now.
    private func offsetFromClock(_ host: NSView) throws -> Double {
        let bitmap = try #require(Snapshot.bitmap(of: host))
        let centre = CGFloat(bitmap.pixelsWide - 1) / 2
        var sumX = 0.0, sumY = 0.0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                // The track is a dim grey on black; the arc is `muted`, well above it.
                guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      pixel.redComponent > 0.35 else { continue }
                let direction = atan2(CGFloat(y) - centre, CGFloat(x) - centre)
                sumX += Double(cos(direction)); sumY += Double(sin(direction))
            }
        }
        let measured = atan2(sumY, sumX) * 180 / .pi
        let offset = measured - 27 - StatusMark.spinnerRotation(at: Date())
        return (offset.truncatingRemainder(dividingBy: 360) + 540).truncatingRemainder(dividingBy: 360) - 180
    }

    private func circularDistance(_ a: Double, _ b: Double) -> Double {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    private func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func snapshot(_ host: NSView) throws -> [UInt8] {
        let bitmap = try #require(Snapshot.bitmap(of: host))
        return Array(UnsafeBufferPointer(start: bitmap.bitmapData, count: bitmap.bytesPerRow * bitmap.pixelsHigh))
    }

    /// The arc turns on SwiftUI's one repeating animation, not on a body re-run per frame: over
    /// half a second (some fifteen frames at the old 30 fps) its body does not run at all, and the
    /// arc has still moved.
    @Test func aWorkingMarkTurnsWithoutEvaluatingItsBodyEveryFrame() throws {
        let (window, host) = hostInWindow(StatusMark(status: .working, size: size))
        defer { window.orderOut(nil) }
        pump(0.1)
        let before = StatusMark.arcEvaluations
        let first = try snapshot(host)
        pump(0.55)
        let second = try snapshot(host)

        #expect(StatusMark.arcEvaluations - before == 0, "the arc re-ran its body \(StatusMark.arcEvaluations - before) times in 0.55 s")
        #expect(first != second, "the arc did not turn")
    }

    /// Many working marks cost no more bodies than one does: the number of body runs does not
    /// grow with the frames, nor does it start a timer each.
    @Test func manyWorkingMarksEvaluateNoMoreBodiesPerFrame() {
        let marks = HStack(spacing: 0) {
            ForEach(0..<20, id: \.self) { _ in StatusMark(status: .working, size: size) }
            ForEach(0..<20, id: \.self) { _ in StatusMark(status: .idle, size: size) }
        }
        let (window, _) = hostInWindow(marks)
        defer { window.orderOut(nil) }
        pump(0.1)
        let before = StatusMark.arcEvaluations
        pump(0.55)

        #expect(StatusMark.arcEvaluations - before == 0, "twenty arcs ran \(StatusMark.arcEvaluations - before) bodies in 0.55 s")
    }

    /// The spell after a pause turns too. An animation flag that outlived the working branch once
    /// latched on, and every later spell drew a still arc (docs/status-model.md, "The frozen
    /// spinner"); the flag lives in the arc now, so a new spell starts from nothing.
    @Test func aMarkThatWorksAgainTurnsAgain() throws {
        let model = StatusModel()
        let (window, host) = hostInWindow(Mark(model: model, size: size))
        defer { window.orderOut(nil) }
        pump(0.2)
        model.status = .done
        pump(0.2)
        model.status = .working
        pump(0.1)
        let first = try snapshot(host)
        pump(0.3)
        let second = try snapshot(host)

        #expect(first != second, "the second spell's arc did not turn")
    }

    /// A row's hover or selection changes the surface, which re-runs `StatusMark`'s body and builds
    /// the arc again. The arc must carry on from where it was, not take a fresh seed from the clock:
    /// each re-seed shifted its phase (by hundreds of degrees, in the first version), so marks that
    /// had been in step stopped being so.
    @Test func aSurfaceChangeLeavesTheArcInPhase() throws {
        let model = StatusModel()
        let (window, host) = hostInWindow(Mark(model: model, size: size))
        defer { window.orderOut(nil) }
        pump(0.35)
        let before = try offsetFromClock(host)
        var after = before
        for surface in [Surface.hover, .sidebar, .hover] {
            model.surface = surface
            pump(0.17)
            after = try offsetFromClock(host)
            #expect(circularDistance(before, after) < 45, "the arc's phase moved from \(before) to \(after) degrees off the clock")
        }
    }

    /// A list recycles a row's cell: the view leaves its window and comes back, with the arc's
    /// state kept and its animation possibly dropped. The arc must be turning again, and back on
    /// the clock's phase. A window keeps the animation through the swap, so this guards the
    /// restart — it failed for an arc rewound in place — rather than reproducing a dropped
    /// animation, which only a recycling list does: it passes without the restart too.
    @Test func aRecycledMarkTurnsAgainOnTheClock() throws {
        let model = StatusModel()
        let (window, host) = hostInWindow(Mark(model: model, size: size))
        defer { window.orderOut(nil) }
        pump(0.3)
        let before = try offsetFromClock(host)
        window.contentView = NSView()
        pump(0.3)
        window.contentView = host
        pump(0.2)
        let first = try snapshot(host)
        pump(0.3)
        let second = try snapshot(host)
        let after = try offsetFromClock(host)

        #expect(first != second, "the recycled arc did not turn")
        #expect(circularDistance(before, after) < 45, "the recycled arc was \(after) degrees off the clock, not \(before)")
    }
}
