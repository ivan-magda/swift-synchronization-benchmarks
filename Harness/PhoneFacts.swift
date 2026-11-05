import Darwin
import Foundation

extension PhoneFacts {
    /// Unavailable hardware fields use -1 (counts/sizes), 0 (memory), or "unknown".
    /// Optional kernel tuning values are omitted when the query is denied or unsupported.
    static func read() -> PhoneFacts {
        let process = ProcessInfo.processInfo
        let version = process.operatingSystemVersion
        let performanceLevelCount = integer("hw.nperflevels") ?? 0
        let performanceLevels = (0..<performanceLevelCount).map { index in
            let prefix = "hw.perflevel\(index)."
            return PerformanceLevel(
                index: index,
                name: string(prefix + "name") ?? "unknown",
                logicalCPUCount: integer(prefix + "logicalcpu") ?? -1,
                physicalCPUCount: integer(prefix + "physicalcpu") ?? -1,
                l1DataCacheBytes: integer(prefix + "l1dcachesize") ?? -1,
                l2CacheBytes: integer(prefix + "l2cachesize") ?? -1,
                cpusPerL2: integer(prefix + "cpusperl2") ?? -1)
        }
        let policy = integer("kern.pthread_mutex_default_policy").map { value in
            switch value {
            case Int(PTHREAD_MUTEX_POLICY_FAIRSHARE_NP): "fairshare"
            case Int(PTHREAD_MUTEX_POLICY_FIRSTFIT_NP): "firstfit"
            default: String(value)
            }
        }
        return PhoneFacts(
            machine: string("hw.machine") ?? "unknown",
            osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            osBuild: string("kern.osversion") ?? "unknown",
            cpuCount: integer("hw.ncpu") ?? process.processorCount,
            activeCPUCount: integer("hw.activecpu") ?? process.activeProcessorCount,
            performanceLevels: performanceLevels,
            cacheLineBytes: integer("hw.cachelinesize") ?? -1,
            memoryBytes: unsignedInteger("hw.memsize") ?? 0,
            timebaseNumerator: Clock.timebase.numer,
            timebaseDenominator: Clock.timebase.denom,
            mainThreadQoSClass: qos_class_main().rawValue,
            mutexDefaultPolicy: policy,
            ulockAdaptiveSpinMicroseconds: integer("kern.ulock_adaptive_spin_usecs"))
    }

    private static func integer(_ name: String) -> Int? {
        unsignedInteger(name).flatMap(Int.init(exactly:))
    }

    /// Darwin hardware sysctls use either a 32-bit or 64-bit integer payload.
    private static func unsignedInteger(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        switch size {
        case MemoryLayout<UInt32>.size: return UInt64(UInt32(truncatingIfNeeded: value))
        case MemoryLayout<UInt64>.size: return value
        default: return nil
        }
    }

    private static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(decoding: bytes.prefix(size).prefix { $0 != 0 }, as: UTF8.self)
    }
}
