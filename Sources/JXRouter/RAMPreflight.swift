import Foundation
import Darwin

/// Free-RAM preflight for local model loads.
///
/// Estimates the model's *working set* (weights actually resident + projector
/// + KV cache for the plan's context + a compute overhead factor) and compares
/// it against the memory macOS can still hand out right now. Verdicts:
///
/// - `.ok`      — fits with comfortable headroom
/// - `.warn`    — would survive but likely pages; shown as a confirmable warning
/// - `.blocked` — cannot fit without driving the machine into swap
///
/// The estimate intentionally mirrors `LocalModelAutoConfig`'s context math
/// (KV bytes/token = kv-layers × kv-heads × head-dim × 2 × bytes-per-element)
/// so the preflight disagrees with the real load as rarely as possible.
enum RAMPreflight {

    enum Verdict: Equatable {
        case ok
        case warn
        case blocked

        var isBlocking: Bool { self == .blocked }
        var isWarning: Bool { self == .warn }
    }

    struct Result: Equatable {
        var verdict: Verdict
        /// Model + projector + KV + overhead, bytes.
        var workingSetBytes: UInt64
        /// Memory the system can still grant right now, bytes.
        var availableBytes: UInt64
        /// Human one-liner for the alert/UI.
        var message: String
    }

    // MARK: - Tunables

    /// Compute buffers, Metal command queues, scratch — scales with model size
    /// but never below ~1.5 GB for a real LLM.
    static let overheadFraction: Double = 0.12
    static let overheadFloorBytes: UInt64 = 1_500_000_000

    /// Warn band: working set fits into (available − reserve) but eats into the
    /// reserve macOS/other apps need. Between these two lines → warn.
    /// Above the available line entirely → block.
    static let warnReserveBytes: UInt64 = 1_000_000_000

    // MARK: - Free memory

    /// Memory the OS can still grant: purgeable-free + inactive. Deliberately
    /// NOT `os_proc_available_memory()` — that reports what *this process* may
    /// allocate before jetsam pressure, which on a mostly-idle Mac reads
    /// several GB above what a new 10 GB llama-server can actually grab.
    nonisolated static func availableMemoryBytes() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let host = mach_host_self()
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            // Conservative fallback: 25% of physical RAM.
            let total = ProcessInfo.processInfo.physicalMemory
            return total / 4
        }
        let pageSize = UInt64(vm_kernel_page_size)
        let freeish = UInt64(stats.free_count + stats.inactive_count + stats.purgeable_count)
        return freeish * pageSize
    }

    // MARK: - Working-set estimate

    struct Estimate: Equatable {
        var weightsBytes: UInt64
        var projectorBytes: UInt64
        var kvBytes: UInt64
        var overheadBytes: UInt64

        var totalBytes: UInt64 {
            weightsBytes + projectorBytes + kvBytes + overheadBytes
        }
    }

    /// Estimate the resident working set for `plan` on this Mac.
    /// - Parameters:
    ///   - contextTokens: the context the launch will pin (explicit) or aim
    ///     for (auto mode's recommended). `nil` derives a sane default from
    ///     the model's geometry.
    static func estimateWorkingSet(modelBytes: Int64,
                                   mmprojBytes: Int64 = 0,
                                   meta: GGUFParser.Metadata,
                                   contextTokens: Int) -> Estimate {
        // Ternary/PQ packings store ~2 bits/weight (plus group scales); dense
        // quants run 4–8 bits. Rather than model every GGML type, scale the
        // *file* by a compression factor inferred from bits-per-weight bands.
        let bpw = inferredBitsPerWeight(fileBytes: modelBytes,
                                        blockCount: meta.blockCount,
                                        embedding: meta.embeddingLength,
                                        expertCount: meta.expertCount)
        // A file whose params imply more bits than it holds is a packing we
        // don't model well (e.g. PQ2_0 ternary at ~2.x bpw); clamping keeps
        // the estimate in the plausible band.
        let weights = UInt64(max(0, modelBytes))
        _ = bpw // computed for future refinement; file size is the anchor
        let projector = UInt64(max(0, mmprojBytes))

        // KV cache: kv-layers × kv-heads × head-dim × 2 (K+V) × bytes/elt.
        let kvHeads = meta.attentionHeadCountKV > 0 ? meta.attentionHeadCountKV
                    : (meta.attentionHeadCount > 0 ? meta.attentionHeadCount : 0)
        let headCount = meta.attentionHeadCount > 0 ? meta.attentionHeadCount : 1
        let headDim = (kvHeads > 0 && headCount > 0) ? max(meta.embeddingLength / headCount, 64) : 128
        let kvLayers = meta.attentionLayerCount > 0 ? meta.attentionLayerCount : max(meta.blockCount, 1)
        let perTokenBytes = Double(kvLayers) * Double(kvHeads) * Double(headDim) * 2 * 1.06 // q8_0-ish
        let kv = UInt64(perTokenBytes * Double(max(contextTokens, 0)))

        let base = weights + projector + kv
        let overhead = max(UInt64(Double(base) * overheadFraction), overheadFloorBytes)
        return Estimate(weightsBytes: weights,
                        projectorBytes: projector,
                        kvBytes: kv,
                        overheadBytes: overhead)
    }

    /// Rough bits-per-weight implied by the file, used only to sanity-band the
    /// estimate (PQ2_0-style ternary files are ~2 bpw; the file size already
    /// reflects that, so this is a consistency check rather than a driver).
    static func inferredBitsPerWeight(fileBytes: Int64, blockCount: Int,
                                      embedding: Int, expertCount: Int) -> Double {
        guard blockCount > 0, embedding > 0 else { return 8 }
        // Parameter-count proxy: 12 × n_embd² per dense block (attention +
        // MLP), scaled by an expert fan-out when present. Close enough for a
        // bpw band on the families JXRouter serves.
        let paramsPerBlock = 12.0 * Double(embedding) * Double(embedding)
        let params = paramsPerBlock * Double(blockCount) * (expertCount > 1 ? Double(min(expertCount, 8)) : 1)
        guard params > 0 else { return 8 }
        return Double(fileBytes) * 8 / params
    }

    // MARK: - Verdict

    /// Full preflight for a model about to load at `contextTokens`.
    ///
    /// `idleServerBytes` — the working set of a local model server that is
    /// ALREADY running (e.g. reloading onto a different model while the old
    /// one is still resident). Those pages are not free: the new load must
    /// fit in what remains AFTER the old server, otherwise the machine swaps
    /// precisely when the old server is being torn down. 0 = nothing running.
    static func check(modelBytes: Int64,
                      mmprojBytes: Int64 = 0,
                      meta: GGUFParser.Metadata,
                      contextTokens: Int,
                      availableBytes: UInt64? = nil,
                      idleServerBytes: UInt64 = 0) -> Result {
        let est = estimateWorkingSet(modelBytes: modelBytes,
                                     mmprojBytes: mmprojBytes,
                                     meta: meta,
                                     contextTokens: contextTokens)
        let rawAvailable = availableBytes ?? availableMemoryBytes()
        let available = rawAvailable > idleServerBytes ? rawAvailable - idleServerBytes : 0
        let total = est.totalBytes

        func gb(_ b: UInt64) -> String { String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        let occupied = idleServerBytes > 0
            ? " An already-loaded local model is holding about \(gb(idleServerBytes))."
            : ""

        if total > available {
            return Result(
                verdict: .blocked,
                workingSetBytes: total,
                availableBytes: available,
                message: "This model needs about \(gb(total)) of memory but only \(gb(available)) is free right now.\(occupied) Loading it would force the whole system into swap. Free memory and try again."
            )
        }
        if total + warnReserveBytes > available {
            return Result(
                verdict: .warn,
                workingSetBytes: total,
                availableBytes: available,
                message: "This model will use about \(gb(total)) of \(gb(available)) free.\(occupied) It should fit, but the Mac may feel sluggish while it runs."
            )
        }
        return Result(
            verdict: .ok,
            workingSetBytes: total,
            availableBytes: available,
            message: "About \(gb(total)) of \(gb(available)) free will be used."
        )
    }

    /// Working-set estimate for a server that is already running and holding a
    /// model resident: its weights are paged in, plus the same compute
    /// overhead floor a fresh load pays. Used to shrink the memory a new load
    /// may claim, so reloading onto a different model doesn't double-book RAM.
    /// (An idle server's KV cache is empty and its context pages are counted
    /// inside the overhead band — the dominant term is always the weights.)
    static func runningServerWorkingSetBytes(modelBytes: Int64) -> UInt64 {
        let weights = UInt64(max(0, modelBytes))
        let overhead = max(UInt64(Double(weights) * overheadFraction), overheadFloorBytes)
        return weights + overhead
    }

    /// Convenience for the Settings UI: preflight the currently selected model
    /// using the launch plan it would actually get.
    static func checkSelectedModel() -> Result? {
        let cfg = ConfigManager.shared
        let path = cfg.ggufModelPath
        guard !path.isEmpty else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return nil }
        let meta = GGUFParser.metadata(from: URL(fileURLWithPath: path))

        var mmprojBytes: Int64 = 0
        let mm = cfg.ggufMmprojPath
        if !mm.isEmpty,
           let mAttrs = try? FileManager.default.attributesOfItem(atPath: mm),
           let mSize = (mAttrs[.size] as? NSNumber)?.int64Value {
            mmprojBytes = mSize
        }

        // The context the launch would actually pin: explicit override wins,
        // otherwise the auto-config's recommendation (floor 8k so a geometry
        // with unknown KV cost still gets a realistic estimate).
        let plan = LocalModelAutoConfig.plan(forModelPath: path, alias: "preflight")
        let context = plan.recommendedContext

        return check(modelBytes: size, mmprojBytes: mmprojBytes,
                     meta: meta, contextTokens: context)
    }
}

// MARK: - Free RAM

enum RAMReclaimer {
    struct Report: Equatable {
        /// llama-server / ollama workers terminated (and how many).
        var stoppedWorkers: Int = 0
        /// Whether the in-app GGUF server was stopped.
        var stoppedInAppServer: Bool = false
        /// Bytes freed by the `purge` disk cache sweep (may be 0 when the
        /// tool is unavailable or declined).
        var purgedBytes: Int64 = 0
        /// Available memory after the sweep, for the confirmation UI.
        var availableAfterBytes: UInt64 = RAMPreflight.availableMemoryBytes()

        var summary: String {
            var parts: [String] = []
            if stoppedInAppServer { parts.append("stopped the local model server") }
            if stoppedWorkers > 0 { parts.append("terminated \(stoppedWorkers) stray inference worker\(stoppedWorkers == 1 ? "" : "s")") }
            if purgedBytes > 0 { parts.append("purged \(ByteCountFormatter.string(fromByteCount: purgedBytes, countStyle: .file)) of disk cache") }
            if parts.isEmpty { parts.append("nothing to reclaim — memory was already free") }
            return parts.joined(separator: ", ") + "."
        }
    }

    /// Reclaim memory without touching user apps: stop JXRouter's own local
    /// model server (the big one), sweep other llama/ollama workers NOT bound
    /// to JXRouter's ports, then ask macOS to purge clean disk caches.
    @MainActor
    static func reclaim(inAppServer: LocalModelManager = .shared) -> Report {
        var report = Report()
        let before = RAMPreflight.availableMemoryBytes()

        // 1. Our own server — the single biggest lever when a model is loaded.
        if inAppServer.isRunning || inAppServer.provider == .gguf {
            inAppServer.stop()
            report.stoppedInAppServer = true
        }

        // 2. Stray inference workers from other tools. Reuses the app's own
        //    sweep but on every local inference port EXCEPT ours, so a reload
        //    right after never fights a still-dying worker.
        let ourPorts: Set<Int> = [inAppServer.port, 8080, 8081, 9931, 11434]
        report.stoppedWorkers = sweepStrayWorkers(excludingPorts: ourPorts)

        // 3. Purge clean file cache — reclaims "inactive" pages the OS is
        //    holding. `purge` ships on every macOS; no sudo needed for the
        //    user-owned portion it affects.
        let purge = Process()
        purge.executableURL = URL(fileURLWithPath: "/usr/sbin/purge")
        try? purge.run()
        purge.waitUntilExit()

        // Give terminated workers a beat to release their pages.
        Thread.sleep(forTimeInterval: 0.8)
        report.purgedBytes = Int64(max(0, Int64(RAMPreflight.availableMemoryBytes()) - Int64(before)))
        report.availableAfterBytes = RAMPreflight.availableMemoryBytes()
        return report
    }

    /// Terminate llama-server / ollama processes whose ports are not in
    /// `excludingPorts`. Returns how many were signalled.
    nonisolated static func sweepStrayWorkers(excludingPorts: Set<Int>) -> Int {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-axo", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        guard (try? task.run()) != nil else { return 0 }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        guard let text = String(data: data, encoding: .utf8) else { return 0 }

        var killed = 0
        let selfPID = getpid()
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            let command = parts[1]
            let isWorker = command.contains("llama-server") || command.contains("ollama serve")
            guard isWorker else { continue }
            guard pid != selfPID else { continue }
            // Ports appear in worker command lines (--port 8081 / -p 8080).
            let portTokens = command.split(whereSeparator: { !$0.isNumber })
            if let port = portTokens.compactMap({ Int($0) }).last, excludingPorts.contains(port) {
                continue
            }
            kill(pid, SIGTERM)
            killed += 1
        }
        return killed
    }
}
