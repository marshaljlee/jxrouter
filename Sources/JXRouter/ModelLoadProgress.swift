import Foundation
import Darwin

/// How far along a GGUF model load is, and what the server is doing right now.
///
/// llama.cpp never prints a percentage. With `mmap` — the default and what
/// JXRouter uses — the weights are faulted in by the kernel, so the only log
/// output is coarse milestones (`loading model`, `model loaded`). Those were
/// measured on this machine: on a 10.5 GB Qwen3.5 the whole load sits between
/// two lines, and the per-tensor lines llama.cpp does emit at `-lv 5`
/// (`create_tensor: loading tensor …`) all fire inside the first 0.4 s, because
/// they track buffer creation, not the bytes actually coming off disk.
///
/// So the real signal is the child process's resident set, which grows page by
/// page until the file is mapped. Measured on the same model: 1 MB at spawn to
/// 9.89 GB resident against a 10.54 GB file — close enough to drive a bar, and
/// monotonic. Sampled here with `proc_pid_rusage`, which reports the same
/// numbers from Swift as from C (verified: 3,145,728 bytes both ways).
struct ModelLoadProgress: Sendable, Equatable {
    enum Phase: Sendable, Equatable {
        case idle
        case launching
        case readingWeights
        case offloading
        case allocatingContext
        case ready

        var label: String {
            switch self {
            case .idle: return ""
            case .launching: return "Starting llama-server"
            case .readingWeights: return "Loading weights"
            case .offloading: return "Offloading layers to GPU"
            case .allocatingContext: return "Allocating context"
            case .ready: return "Ready"
            }
        }

        /// Slice of the overall 0…1 bar this phase owns. Set by measurement:
        /// reading the weights is essentially the whole wait; everything after
        /// it is sub-second except context allocation on a huge window.
        var range: ClosedRange<Double> {
            switch self {
            case .idle: return 0...0
            case .launching: return 0.00...0.02
            case .readingWeights: return 0.02...0.80
            case .offloading: return 0.80...0.88
            case .allocatingContext: return 0.88...0.97
            case .ready: return 1.0...1.0
            }
        }

        /// Phases only ever move forward; a late or repeated log line must not
        /// drag the bar backwards.
        var rank: Int {
            switch self {
            case .idle: return 0
            case .launching: return 1
            case .readingWeights: return 2
            case .offloading: return 3
            case .allocatingContext: return 4
            case .ready: return 5
            }
        }
    }

    var phase: Phase = .idle
    var fraction: Double = 0
    var bytesLoaded: Int64 = 0
    var bytesTotal: Int64 = 0
    /// False when the percentage is a time-based estimate because no resident
    /// size could be sampled — the UI must not present it as measured.
    var isMeasured: Bool = false
}

/// Tails a `llama-server` child process and turns its resident size plus its
/// log milestones into one 0…1 fraction.
///
/// Deliberately not main-actor: the sampler runs on its own queue and the log
/// callback fires from Foundation's pipe thread. All output is funnelled
/// through `onUpdate`, which the owner hops onto the main actor.
final class ModelLoadMonitor: @unchecked Sendable {
    private let totalBytes: Int64
    private let onUpdate: @Sendable (ModelLoadProgress) -> Void
    private let lock = NSLock()

    private var pid: Int32 = 0
    private var timer: DispatchSourceTimer?
    private var startedAt = Date()
    private var baseline: UInt64?
    private var peak: UInt64 = 0
    private var haveSamples = false
    private var phase: ModelLoadProgress.Phase = .launching
    private var lastFraction: Double = 0
    private var stopped = false

    /// - Parameters:
    ///   - modelBytes: size of the GGUF file, the denominator for the bar.
    ///   - onUpdate: called from a background queue; hop to the main actor.
    init(modelBytes: Int64, onUpdate: @escaping @Sendable (ModelLoadProgress) -> Void) {
        self.totalBytes = modelBytes
        self.onUpdate = onUpdate
    }

    deinit { cancel() }

    /// Begin sampling the given child process.
    func attach(pid: Int32) {
        lock.lock()
        self.pid = pid
        self.startedAt = Date()
        self.stopped = false
        lock.unlock()

        let queue = DispatchQueue(label: "com.jxrouter.model-load-progress", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        // 4 Hz: fast enough to look continuous, cheap enough to ignore.
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()

        lock.lock()
        self.timer = timer
        lock.unlock()
    }

    /// Feed one line of the server's log. Unrecognised lines are ignored.
    func note(line: String) {
        let next: ModelLoadProgress.Phase?
        if line.contains("load_model: loading model") || line.contains("loading model tensors") {
            next = .readingWeights
        } else if line.contains("offloaded"), line.contains("layers to GPU") {
            next = .offloading
        } else if line.contains("initializing, n_slots") {
            next = .allocatingContext
        } else if line.contains("model loaded") || line.contains("listening on") {
            next = .ready
        } else {
            next = nil
        }
        guard let next else { return }

        lock.lock()
        guard !stopped, next.rank > phase.rank else { lock.unlock(); return }
        phase = next
        lock.unlock()

        if next == .ready { finish() } else { emit() }
    }

    /// Mark the load complete — pins the bar at 100% and stops sampling.
    func finish() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        phase = .ready
        timer?.cancel()
        timer = nil
        lock.unlock()
        emit(override: 1.0)
    }

    /// Abandon the load (server failed or was stopped).
    func cancel() {
        lock.lock()
        stopped = true
        timer?.cancel()
        timer = nil
        lock.unlock()
    }

    // MARK: - Sampling

    private func sample() {
        lock.lock()
        let pid = self.pid
        let stopped = self.stopped
        lock.unlock()
        guard pid > 0, !stopped else { return }
        guard let resident = Self.residentBytes(pid: pid) else { return }

        lock.lock()
        // First sample is the process before it has mapped anything; that
        // overhead is not model weight, so it is subtracted out.
        if baseline == nil { baseline = resident }
        let base = baseline ?? 0
        let model = resident > base ? resident - base : 0
        if model > peak { peak = model }
        haveSamples = true
        lock.unlock()

        emit()
    }

    private func emit(override: Double? = nil) {
        lock.lock()
        let phase = self.phase
        let peak = self.peak
        let have = haveSamples
        let started = startedAt
        lock.unlock()

        let range = phase.range
        let local: Double
        if let override {
            local = override
        } else if have && totalBytes > 0 {
            local = min(1, Double(peak) / Double(totalBytes))
        } else {
            // No resident samples (call failed, or file size unknown): creep
            // towards the top of the current phase so the bar still moves.
            // isMeasured stays false so the UI can label it as an estimate.
            let elapsed = Date().timeIntervalSince(started)
            local = 1 - exp(-elapsed / 15.0)
        }

        let raw = range.lowerBound + (range.upperBound - range.lowerBound) * local
        let fraction = max(lastFraction, min(1, raw))

        lock.lock()
        lastFraction = fraction
        lock.unlock()

        onUpdate(ModelLoadProgress(
            phase: phase,
            fraction: fraction,
            bytesLoaded: Int64(min(UInt64(Int64.max), peak)),
            bytesTotal: totalBytes,
            isMeasured: have && totalBytes > 0
        ))
    }

    /// Resident set size of a process, in bytes.
    nonisolated static func residentBytes(pid: Int32) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { p -> Int32 in
            p.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { pp in
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), pp)
            }
        }
        guard rc == 0 else { return nil }
        return info.ri_resident_size
    }
}
