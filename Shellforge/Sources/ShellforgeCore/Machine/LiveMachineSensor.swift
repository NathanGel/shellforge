// Ported from AiTerm (app/Sources/AiTermCore/Machine/LiveMachineSensor.swift), GPLv3, Laurens D'Hondt.
import Darwin
import Foundation

/// The Mac's load from the kernel: Mach host statistics for the CPU and memory, `thermalState` and
/// the `kern.memorystatus_vm_pressure_level` sysctl for macOS's two warnings. In-process and
/// unprivileged — no `top`, no `vm_stat`: a telemetry subprocess is how the Codex usage poll failed.
public struct LiveMachineSensor: MachineSensor {
    public init() {}

    /// One send right, taken once: `mach_host_self()` hands out a new one per call.
    private static let host = mach_host_self()

    public func sample() -> MachineSample {
        MachineSample(cpu: Self.cpuTicks(), memory: Self.memoryUse(),
                      throttled: ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue,
                      memoryPressure: Self.pressureLevel() >= Self.pressureWarn)
    }

    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics(host, HOST_CPU_LOAD_INFO, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        let ticks = info.cpu_ticks
        return CPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }

    static func memoryUse() -> MemoryUse? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { host_statistics64(host, HOST_VM_INFO64, $0, &count) }
        }
        guard result == KERN_SUCCESS else { return nil }
        // Activity Monitor's "Memory Used": app memory (anonymous pages less the purgeable ones),
        // wired, and what the compressor holds.
        let app = UInt64(stats.internal_page_count) - min(UInt64(stats.internal_page_count), UInt64(stats.purgeable_count))
        let pages = app + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)
        return MemoryUse(used: pages * UInt64(getpagesize()), total: ProcessInfo.processInfo.physicalMemory)
    }

    /// `kern.memorystatus_vm_pressure_level`: 1 normal, 2 warn, 4 critical — Activity Monitor's
    /// green, yellow and red. 0 when the sysctl would not answer.
    static func pressureLevel() -> Int32 {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 ? level : 0
    }

    static let pressureWarn: Int32 = 2
}
