import Foundation
import IOKit
import Metal

enum HardwareInfo {
    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    static func sysctlInt(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    /// GPU core count from the Apple GPU's IORegistry entry (no subprocess, no permissions).
    static func gpuCores() -> Int? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            if let n = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int {
                return n
            }
        }
        return nil
    }

    /// "MacBook Air", "Mac mini", … from system_profiler (about a second, so run off the main thread).
    static func machineName() -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["SPHardwareDataType", "-json"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let hw = (json["SPHardwareDataType"] as? [[String: Any]])?.first,
               let name = hw["machine_name"] as? String { return name }
        } catch {}
        return "Mac"
    }

    static func freeDiskBytes() -> Int64 {
        let v = try? Paths.models.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func detect() async -> Hardware {
        let name = await Task.detached { machineName() }.value
        let chip = sysctlString("machdep.cpu.brand_string") ?? "Unknown chip"
        let (family, variant) = Chips.parse(chip)
        let cores = gpuCores()
        let device = MTLCreateSystemDefaultDevice()
        let arm = sysctlInt("hw.optional.arm64") == 1
        return Hardware(
            machineName: name,
            chip: chip,
            chipFamily: family,
            chipVariant: variant,
            ramBytes: Int64(ProcessInfo.processInfo.physicalMemory),
            gpuCores: cores,
            gpuWorkingSetBytes: device.map { Int64($0.recommendedMaxWorkingSetSize) },
            freeDiskBytes: freeDiskBytes(),
            appleSilicon: arm,
            bandwidthGBs: Chips.bandwidth(family: family, variant: variant, gpuCores: cores)
        )
    }
}
