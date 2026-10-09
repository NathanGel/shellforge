// Ported from AiTerm (app/Tests/AiTermCoreTests/MachineReadingsTests.swift), GPLv3, Laurens D'Hondt.
import Foundation
import Testing
@testable import ShellforgeCore

@Suite struct MachineReadingsTests {
    private let gigabyte: UInt64 = 1 << 30

    private func sample(_ cpu: CPUTicks?, used: UInt64 = 10, throttled: Bool = false, pressure: Bool = false) -> MachineSample {
        MachineSample(cpu: cpu, memory: MemoryUse(used: used * gigabyte, total: 16 * gigabyte),
                      throttled: throttled, memoryPressure: pressure)
    }

    private func ticks(_ user: UInt32, _ system: UInt32, _ idle: UInt32, _ nice: UInt32 = 0) -> CPUTicks {
        CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    /// Busy is user, system and nice; the share is of the ticks that passed between the two samples.
    @Test func theCPUShareIsTheBusyTicksSinceTheLastSample() {
        #expect(ticks(130, 50, 900, 20).busyPercent(since: ticks(100, 40, 850, 10)) == 50)
        #expect(ticks(100, 40, 940).busyPercent(since: ticks(100, 40, 840)) == 0)
        #expect(ticks(100, 40, 840).busyPercent(since: ticks(100, 40, 840)) == nil, "no tick passed")
    }

    /// The counters are 32 bits wide and wrap on a long uptime: the difference still comes out right.
    @Test func theCPUShareSurvivesTheCountersWrapping() {
        let before = ticks(UInt32.max - 9, 0, UInt32.max - 29)
        let after = ticks(10, 0, 50)
        #expect(after.busyPercent(since: before) == 20)
    }

    @Test func memoryIsUsedOverInstalledAndNeverPastFull() {
        #expect(MemoryUse(used: 10 * gigabyte, total: 16 * gigabyte).percent == 63)
        #expect(MemoryUse(used: 20 * gigabyte, total: 16 * gigabyte).percent == 100)
        #expect(MemoryUse(used: 1, total: 0).percent == nil)
    }

    /// On mains: cpu then ram, each drawn in ink while macOS raises no warning.
    @Test func atTheDeskTheRowIsCPUThenRAM() {
        let lines = MachineReadings.lines(previous: sample(ticks(100, 40, 840)), current: sample(ticks(130, 50, 900, 20)),
                                          power: .mains)
        #expect(lines.map(\.window) == [.cpu, .ram])
        #expect(lines.map(\.percent) == [50, 63])
        #expect(lines.allSatisfy { !$0.warning })
    }

    /// The CPU's share needs a sample before it; the first draws ram alone rather than a guess.
    @Test func theFirstSampleHasNoCPU() {
        let lines = MachineReadings.lines(previous: nil, current: sample(ticks(130, 50, 900)), power: .mains)
        #expect(lines.map(\.window) == [.ram])
    }

    /// Amber only where macOS says so: heat for the CPU, pressure for memory — never a percentage.
    @Test func amberIsMacOSsOwnWarning() {
        let busy = MachineReadings.lines(previous: sample(ticks(0, 0, 0)), current: sample(ticks(99, 0, 1), used: 15), power: .mains)
        #expect(busy.allSatisfy { !$0.warning }, "99 % busy and 94 % used is the Mac working, not failing")
        let warned = MachineReadings.lines(previous: sample(ticks(0, 0, 0)),
                                           current: sample(ticks(10, 0, 90), used: 4, throttled: true, pressure: true), power: .mains)
        #expect(warned.allSatisfy { $0.warning })
    }

    /// `bat` joins while the Mac runs on its battery, amber within five points of Backpack Mode's
    /// cutoff — the threshold the mode itself uses.
    @Test func theBatteryJoinsOnBatteryAndWarnsNearTheCutoff() {
        func battery(_ power: PowerReading) -> UsageLine? {
            MachineReadings.lines(previous: nil, current: sample(nil), power: power).first { $0.window == .battery }
        }
        #expect(battery(PowerReading(level: 64, onBattery: false)) == nil, "on the charger the battery says nothing")
        #expect(battery(PowerReading(level: nil, onBattery: true)) == nil)
        #expect(battery(PowerReading(level: 64, onBattery: true)) == UsageLine(window: .battery, percent: 64, warning: false))
        #expect(battery(PowerReading(level: 15, onBattery: true))?.warning == true)
        #expect(battery(PowerReading(level: 16, onBattery: true))?.warning == false)
    }

    @Test func eachReadingIsReadInWords() {
        #expect(UsageLine(window: .cpu, percent: 23, warning: false).help == "CPU 23 % busy")
        #expect(UsageLine(window: .cpu, percent: 87, warning: true).help == "CPU 87 % busy, slowed by heat")
        #expect(UsageLine(window: .ram, percent: 61, warning: false).help == "Memory 61 % used")
        #expect(UsageLine(window: .ram, percent: 78, warning: true).help == "Memory 78 % used, under pressure")
        #expect(UsageLine(window: .battery, percent: 64, warning: false).help == "Battery 64 %")
        #expect(UsageLine(window: .battery, percent: 14, warning: true).help == "Battery 14 %, running low")
        #expect([UsageLine.Window.cpu, .ram, .battery].map(\.shortLabel) == ["cpu", "ram", "bat"])
    }

    /// The live sensor reads this Mac without a subprocess: two samples a moment apart give a share
    /// and a memory figure inside their ranges.
    @Test func theLiveSensorReadsThisMac() throws {
        let sensor = LiveMachineSensor()
        let first = sensor.sample()
        Thread.sleep(forTimeInterval: 0.2)
        let second = sensor.sample()
        let earlier = try #require(first.cpu)
        let busy = try #require(second.cpu?.busyPercent(since: earlier))
        #expect((0...100).contains(busy))
        let used = try #require(second.memory?.percent)
        #expect((1...100).contains(used))
    }
}
