import Darwin
import Foundation

struct SkillProcessResourceSnapshot: Sendable {
    let cpuNanoseconds: UInt64
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let physicalFootprintBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let isAvailable: Bool

    static func capture() -> SkillProcessResourceSnapshot {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            codexProcPIDRUsage(
                getpid(),
                RUSAGE_INFO_V4,
                UnsafeMutableRawPointer(pointer)
            )
        }
        guard status == 0 else {
            return SkillProcessResourceSnapshot(
                cpuNanoseconds: processCPUNanoseconds(),
                diskReadBytes: 0,
                diskWriteBytes: 0,
                physicalFootprintBytes: 0,
                peakPhysicalFootprintBytes: 0,
                isAvailable: false
            )
        }

        return SkillProcessResourceSnapshot(
            cpuNanoseconds: processCPUNanoseconds(),
            diskReadBytes: info.ri_diskio_bytesread,
            diskWriteBytes: info.ri_diskio_byteswritten,
            physicalFootprintBytes: info.ri_phys_footprint,
            peakPhysicalFootprintBytes: info.ri_lifetime_max_phys_footprint,
            isAvailable: true
        )
    }

    static func processCPUNanoseconds() -> UInt64 {
        var value = timespec()
        guard clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &value) == 0 else {
            return 0
        }
        return UInt64(max(0, value.tv_sec)) * 1_000_000_000
            + UInt64(max(0, value.tv_nsec))
    }

    func delta(to end: SkillProcessResourceSnapshot) -> SkillProcessResourceDelta {
        SkillProcessResourceDelta(
            cpuMilliseconds: Int(end.cpuNanoseconds.saturatingSubtract(cpuNanoseconds) / 1_000_000),
            diskReadBytes: end.diskReadBytes.saturatingSubtract(diskReadBytes),
            diskWriteBytes: end.diskWriteBytes.saturatingSubtract(diskWriteBytes),
            peakPhysicalFootprintBytes: max(
                physicalFootprintBytes,
                end.physicalFootprintBytes
            ),
            isAvailable: isAvailable && end.isAvailable
        )
    }
}

struct SkillProcessResourceDelta: Sendable {
    let cpuMilliseconds: Int
    let diskReadBytes: UInt64
    let diskWriteBytes: UInt64
    let peakPhysicalFootprintBytes: UInt64
    let isAvailable: Bool
}

private extension UInt64 {
    func saturatingSubtract(_ other: UInt64) -> UInt64 {
        self >= other ? self - other : 0
    }
}

@_silgen_name("proc_pid_rusage")
private func codexProcPIDRUsage(
    _ pid: Int32,
    _ flavor: Int32,
    _ buffer: UnsafeMutableRawPointer
) -> Int32
