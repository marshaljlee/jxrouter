import Foundation
import Darwin

/// Inference-relevant hardware profile of this Mac.
///
/// Ported from the Go implementation's `internal/engine/hardware.go`. The
/// Swift app previously sized contexts purely from GGUF metadata plus
/// llama.cpp's own `-fit`, which measures *device* memory and therefore
/// ignores the rest of the machine — that is what produced the 262K window
/// that drove this Mac into swap. Knowing the real RAM and core layout lets
/// auto-config reason about the machine instead of just the model.
struct HardwareProfile: Sendable, Equatable {
    var platform: String = "macOS"
    var arch: String = ""
    var chip: String = ""
    var coresPhysical: Int = 0
    var coresLogical: Int = 0
    var performanceCores: Int = 0
    var efficiencyCores: Int = 0
    var totalRAMBytes: UInt64 = 0
    var gpuName: String = ""
    var gpuBackend: GPUBackend = .cpu

    enum GPUBackend: String, Sendable, Equatable {
        case metal
        case cuda
        case cpu

        var label: String {
            switch self {
            case .metal: return "Metal"
            case .cuda: return "CUDA"
            case .cpu: return "CPU"
            }
        }
    }

    var totalRAMGB: Double { Double(totalRAMBytes) / 1_073_741_824 }

    /// One-line summary for Settings.
    var summary: String {
        let chipPart = chip.isEmpty ? arch : chip
        let cores = performanceCores > 0 && efficiencyCores > 0
            ? "\(performanceCores)P + \(efficiencyCores)E cores"
            : "\(coresLogical) cores"
        return "\(chipPart) · \(cores) · \(String(format: "%.0f", totalRAMGB)) GB · \(gpuName.isEmpty ? gpuBackend.label : gpuName)"
    }

    /// Memory the OS and other apps need left alone, in bytes.
    ///
    /// A unified-memory Mac shares RAM with the GPU, so filling it to the
    /// brim swaps. Reserved headroom scales with machine size but never drops
    /// below 6 GB — on a 32 GB machine that leaves ~26 GB, which is what
    /// actually fits a 10.5 GB model plus a sane KV cache without swapping.
    var reservedBytes: UInt64 {
        let reserve = max(6_442_450_944, UInt64(Double(totalRAMBytes) * 0.20))
        return min(reserve, totalRAMBytes / 2)
    }

    /// Bytes available to weights plus KV cache after headroom.
    var inferenceBudgetBytes: UInt64 {
        totalRAMBytes > reservedBytes ? totalRAMBytes - reservedBytes : 0
    }

    // MARK: - Detection

    /// Profile this machine once. Cheap: a handful of sysctl calls.
    static func current() -> HardwareProfile {
        var p = HardwareProfile()
        p.arch = Self.sysctlString("hw.machine") ?? ""
        p.chip = Self.sysctlString("machdep.cpu.brand_string") ?? p.arch
        p.coresLogical = Int(Self.sysctlInt64("hw.logicalcpu") ?? 0)
        p.coresPhysical = Int(Self.sysctlInt64("hw.physicalcpu") ?? 0)
        p.performanceCores = Int(Self.sysctlInt64("hw.perflevel0.logicalcpu") ?? 0)
        p.efficiencyCores = Int(Self.sysctlInt64("hw.perflevel1.logicalcpu") ?? 0)
        p.totalRAMBytes = UInt64(Self.sysctlInt64("hw.memsize") ?? 0)

        // Apple silicon always exposes Metal; there is no CUDA path here.
        // Under Rosetta `hw.machine` reports x86_64, so fall back to the
        // translation flag rather than losing the Metal backend.
        if p.arch == "arm64" || Self.sysctlInt64("sysctl.proc_translated") == 1 {
            p.gpuBackend = .metal
            p.gpuName = "Apple GPU (Metal)"
        } else {
            p.gpuBackend = .cpu
            p.gpuName = Self.sysctlString("machdep.cpu.brand_string") ?? "CPU"
        }
        return p
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func sysctlInt64(_ name: String) -> Int64? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
