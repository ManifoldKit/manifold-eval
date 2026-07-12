import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// A snapshot of the machine a bench ran on. Carried on every ``BenchResult``
/// so a report reader can tell "same hardware, different lane" apart from
/// "different hardware" without cross-referencing an out-of-band run log.
public struct HardwareSnapshot: Codable, Sendable, Equatable {
    public let chip: String
    public let memoryGB: Double
    public let os: String

    public init(chip: String, memoryGB: Double, os: String) {
        self.chip = chip
        self.memoryGB = memoryGB
        self.os = os
    }

    /// Probes the current machine. Best-effort: `sysctlbyname` failures fall
    /// back to a labeled placeholder rather than throwing — a perf report is
    /// still useful without a hardware header, and this must never be the
    /// reason a bench run aborts.
    public static func current() -> HardwareSnapshot {
        HardwareSnapshot(
            chip: chipModel() ?? "unknown",
            memoryGB: (Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded(),
            os: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    private static func chipModel() -> String? {
        #if canImport(Darwin)
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        return String(cString: buffer).trimmingCharacters(in: .whitespaces)
        #else
        return nil
        #endif
    }
}
