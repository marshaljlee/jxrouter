import Foundation
import Observation

// MARK: - llama.cpp release metadata

/// A downloadable llama.cpp build published as a GitHub release.
/// llama.cpp ships binaries on nightly releases tagged `b<build>` (e.g. `b11056`);
/// the semantic `v0.x` release carries no binaries, so build numbers — not
/// version tags — are the update unit.
struct LlamaRelease: Sendable, Equatable {
    let tag: String
    let build: Int
    let assetName: String
    let downloadURL: URL
    let publishedAt: String
}

/// Owns the llama.cpp runtime behind JXRouter's built-in GGUF loader.
///
/// llama-server is resolved from three places; the newest build wins and ties
/// prefer the app's own copy so an app update always takes effect:
///
///   1. **Bundled** — `JXRouter.app/Contents/Resources/llama-cpp/llama-server`
///   2. **Managed** — `~/Library/Application Support/JXRouter/llama-cpp/current/llama-server`
///                    (installed and updated from inside the app)
///   3. **System**  — Homebrew / `/usr/local` `llama-server`
///
/// When nothing is available the app downloads an official llama.cpp macOS
/// build from GitHub, so the GGUF loader works on a Mac that never had
/// Homebrew or llama.cpp installed.
@MainActor
@Observable
final class LlamaRuntime {
    static let shared = LlamaRuntime()

    // MARK: - Types

    enum Source: String, CaseIterable, Identifiable {
        case bundled
        case managed
        case system

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .bundled: return "Built into JXRouter"
            case .managed: return "Installed by JXRouter"
            case .system: return "Already on this Mac"
            }
        }

        /// Lower rank = preferred when two candidates report the same build.
        var rank: Int {
            switch self {
            case .bundled: return 0
            case .managed: return 1
            case .system: return 2
            }
        }
    }

    struct Runtime: Sendable, Equatable {
        let path: String
        let build: Int
        let versionLine: String
        let source: Source
    }

    enum Phase: Equatable {
        case idle
        case resolving
        case checking
        case downloading(Double)
        case installing
        case ready(String)
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .resolving, .checking, .downloading, .installing: return true
            case .idle, .ready, .failed: return false
            }
        }

        var message: String {
            switch self {
            case .idle: return ""
            case .resolving: return "Locating llama-server…"
            case .checking: return "Checking for a newer llama.cpp build…"
            case .downloading(let f) where f < 0: return "Downloading llama.cpp…"
            case .downloading(let f): return "Downloading llama.cpp… \(Int(f * 100))%"
            case .installing: return "Installing llama.cpp…"
            case .ready(let m): return m
            case .failed(let m): return m
            }
        }
    }

    // MARK: - Published state

    private(set) var phase: Phase = .idle
    private(set) var runtime: Runtime?
    private(set) var latestRelease: LlamaRelease?
    private(set) var lastChecked: Date?

    /// Whether an install/update is available for the currently resolved runtime.
    var updateAvailable: Bool {
        guard let latest = latestRelease else { return false }
        guard let current = runtime else { return true }
        return latest.build > current.build
    }

    var isInstalled: Bool { runtime != nil }

    /// Short human summary for the settings UI, e.g. "build 11056 · Built into JXRouter".
    var statusSummary: String {
        guard let r = runtime else { return "Not installed" }
        if r.build > 0 {
            return "build \(r.build) · \(r.source.displayName)"
        }
        return "\(r.versionLine) · \(r.source.displayName)"
    }

    // MARK: - Locations

    /// Root of the runtime JXRouter installs and updates itself.
    nonisolated static func managedRoot() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/Library/Application Support/JXRouter/llama-cpp"
    }

    /// `current` always points at the active installed build directory.
    nonisolated static func managedBinaryPath() -> String {
        "\(managedRoot())/current/llama-server"
    }

    /// The copy shipped inside the app bundle (may be absent).
    nonisolated static func bundledBinaryPath() -> String? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent("llama-cpp/llama-server").path
        return FileManager.default.isExecutableFile(atPath: candidate) ? candidate : nil
    }

    /// Homebrew / system installs, in preference order.
    nonisolated static func systemCandidatePaths() -> [String] {
        let prefixes = ["/opt/homebrew/bin", "/usr/local/bin"]
        let names = ["llama-server", "llama"]
        var out: [String] = []
        for p in prefixes {
            for n in names {
                let c = "\(p)/\(n)"
                if FileManager.default.isExecutableFile(atPath: c) { out.append(c) }
            }
        }
        return out
    }

    // MARK: - Resolution

    /// Resolve the best available llama-server, reading each candidate's build number.
    func resolve() async {
        guard !phase.isBusy else { return }
        phase = .resolving
        let found = await Task.detached(priority: .utility) { () -> Runtime? in
            Self.bestAvailableRuntime()
        }.value

        runtime = found
        if let found {
            phase = .ready("llama.cpp build \(found.build) ready (\(found.source.displayName))")
            print("[LlamaRuntime] Resolved \(found.path) build \(found.build) [\(found.source.rawValue)]")
        } else {
            phase = .idle
            print("[LlamaRuntime] No llama-server found — an install is required")
        }
    }

    /// Off-main-actor resolution used by both the async path and launch code.
    nonisolated static func bestAvailableRuntime() -> Runtime? {
        var pool: [(path: String, source: Source)] = []
        if let bundled = bundledBinaryPath() { pool.append((bundled, .bundled)) }
        let managed = managedBinaryPath()
        if FileManager.default.isExecutableFile(atPath: managed) { pool.append((managed, .managed)) }
        for p in systemCandidatePaths() { pool.append((p, .system)) }

        var best: Runtime?
        for candidate in pool {
            guard let info = version(ofBinaryAt: candidate.path) else { continue }
            let resolved = Runtime(path: candidate.path, build: info.build,
                                   versionLine: info.text, source: candidate.source)
            if best == nil
                || resolved.build > best!.build
                || (resolved.build == best!.build && resolved.source.rank < best!.source.rank) {
                best = resolved
            }
        }
        return best
    }

    /// Best-effort synchronous resolution for launch paths with no actor context.
    ///
    /// Probing every candidate costs one `--version` run each, so the answer is
    /// cached briefly — `readiness()` and provider detection call this often.
    nonisolated static func bestAvailablePath() -> String? {
        let ttl: TimeInterval = 30
        bestLock.lock()
        if let cached = bestCache, Date().timeIntervalSince(cached.date) < ttl {
            let path = cached.path
            bestLock.unlock()
            // Trust the cache only while the binary still exists on disk — an
            // install/rollback can remove it inside the TTL window.
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        } else {
            bestLock.unlock()
        }

        guard let path = bestAvailableRuntime()?.path else { return nil }

        bestLock.lock()
        bestCache = (path, Date())
        bestLock.unlock()
        return path
    }

    private static let bestLock = NSLock()
    /// Guarded by `bestLock`; `nonisolated(unsafe)` because the cache is read
    /// from the nonisolated `bestAvailablePath()` fast path.
    nonisolated(unsafe) private static var bestCache: (path: String, date: Date)?

    // MARK: - Update check

    /// Ask GitHub for the newest llama.cpp macOS build.
    @discardableResult
    func checkForUpdate() async -> LlamaRelease? {
        phase = .checking
        let release = await Task.detached(priority: .utility) { () -> LlamaRelease? in
            Self.fetchLatestRelease()
        }.value
        latestRelease = release
        lastChecked = Date()

        guard let release else {
            phase = .failed("Could not reach GitHub to check for llama.cpp updates.")
            return nil
        }
        if let current = runtime, release.build <= current.build {
            phase = .ready("llama.cpp build \(current.build) is up to date.")
        } else {
            let from = runtime.map { " (installed: \($0.build))" } ?? ""
            phase = .ready("llama.cpp build \(release.build) is available\(from).")
        }
        return release
    }

    // MARK: - Install / update

    /// Download and install the newest llama.cpp build (or reinstall the current one).
    func install() async {
        var release = latestRelease
        if release == nil {
            guard !phase.isBusy else { return }
            release = await checkForUpdate()
        }
        guard let target = release else {
            phase = .failed("No llama.cpp build available to install.")
            return
        }
        await install(release: target)
    }

    func install(release: LlamaRelease) async {
        // A running server holds the old binary open; stop it before swapping.
        let mgr = LocalModelManager.shared
        if mgr.provider == .gguf, mgr.isRunning {
            mgr.stop()
            try? await Task.sleep(nanoseconds: 400_000_000)
        }

        phase = .downloading(-1)

        do {
            let archive = try await Self.download(release: release) { [weak self] fraction in
                Task { @MainActor in
                    guard let self else { return }
                    if case .downloading = self.phase { self.phase = .downloading(fraction) }
                }
            }
            self.phase = .installing
            let installed = try await Task.detached(priority: .utility) { () -> Runtime in
                try Self.stage(archive: archive, build: release.build)
                let binary = Self.managedBinaryPath()
                guard let info = Self.version(ofBinaryAt: binary) else {
                    throw RuntimeError.installFailed("Installed binary did not run: \(binary)")
                }
                return Runtime(path: binary, build: info.build,
                               versionLine: info.text, source: .managed)
            }.value

            runtime = installed
            latestRelease = release
            phase = .ready("llama.cpp build \(installed.build) installed.")
            print("[LlamaRuntime] Installed llama.cpp build \(installed.build) at \(installed.path)")
        } catch {
            phase = .failed(Self.describe(error))
            print("[LlamaRuntime] Install failed: \(error)")
        }
    }

    /// Remove the managed copy so the app falls back to bundled/system.
    func uninstallManaged() {
        try? FileManager.default.removeItem(atPath: "\(Self.managedRoot())/current")
        if runtime?.source == .managed { runtime = nil }
        phase = .ready("Removed the llama.cpp copy installed by JXRouter.")
    }

    // MARK: - Errors

    enum RuntimeError: LocalizedError {
        case downloadFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .downloadFailed(let m): return "Download failed: \(m)"
            case .installFailed(let m): return "Install failed: \(m)"
            }
        }
    }

    private static func describe(_ error: Error) -> String {
        if let e = error as? RuntimeError { return e.errorDescription ?? String(describing: e) }
        return error.localizedDescription
    }

    // MARK: - Process helpers (nonisolated: safe to call off the main actor)

    /// Run a binary and capture its combined output.
    nonisolated static func run(_ path: String, args: [String], timeout: TimeInterval = 20) -> (status: Int32, output: String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = args
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
        } catch {
            return (-1, error.localizedDescription)
        }
        // Read before waiting: a chatty binary can fill the pipe buffer and deadlock.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (proc.terminationStatus, text)
    }

    /// Read `<binary> --version` and pull out the build number.
    ///
    /// llama.cpp prints either `version: 10150 (dee2a846b)` (older builds) or
    /// `version: 0.4.1-dev (build 11056, commit e613ef2c8)` (current releases),
    /// so the build number is searched for first and the bare version second.
    nonisolated static func version(ofBinaryAt path: String) -> (build: Int, text: String)? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let (status, output) = run(path, args: ["--version"], timeout: 20)
        guard status == 0 || !output.isEmpty else { return nil }
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let text = lines.first { $0.hasPrefix("version:") } ?? ""

        var build = 0
        if let r = output.range(of: #"build\s+(\d+)"#, options: .regularExpression) {
            let matched = String(output[r])
            if let n = Int(matched.filter(\.isNumber)) { build = n }
        } else if !text.isEmpty {
            build = Int(text.filter(\.isNumber)) ?? 0
        }
        return (build, text.isEmpty ? (lines.first ?? "") : text)
    }
}

// MARK: - Networking & staging

extension LlamaRuntime {

    /// macOS asset suffix for this machine (`arm64` or `x64`).
    nonisolated static func platformSuffix() -> String {
        let (_, output) = run("/usr/bin/uname", args: ["-m"])
        return output.trimmingCharacters(in: .whitespacesAndNewlines) == "arm64" ? "arm64" : "x64"
    }

    nonisolated static let releasesURL = "https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=20"

    /// Find the newest llama.cpp release that publishes a macOS build for this Mac.
    nonisolated static func fetchLatestRelease() -> LlamaRelease? {
        guard let url = URL(string: releasesURL),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        let suffix = "bin-macos-\(platformSuffix()).tar.gz"
        var best: LlamaRelease?
        for release in json {
            let tag = release["tag_name"] as? String ?? ""
            guard tag.hasPrefix("b"), let build = Int(tag.dropFirst()) else { continue }
            guard build > (best?.build ?? 0) else { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            for asset in assets {
                let name = asset["name"] as? String ?? ""
                guard name.hasSuffix(suffix) else { continue }
                guard let urlString = asset["browser_download_url"] as? String,
                      let downloadURL = URL(string: urlString) else { continue }
                best = LlamaRelease(tag: tag,
                                    build: build,
                                    assetName: name,
                                    downloadURL: downloadURL,
                                    publishedAt: release["published_at"] as? String ?? "")
                break
            }
        }
        return best
    }

    /// Stream the release archive to disk, reporting 0…1 progress.
    nonisolated static func download(release: LlamaRelease,
                                     progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let observer = DownloadObserver(progress: progress)
        let session = URLSession(configuration: .default, delegate: observer, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let tmpFile = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("jxrouter-\(release.assetName)")
        try? FileManager.default.removeItem(at: tmpFile)

        let (localURL, response) = try await session.download(from: release.downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw RuntimeError.downloadFailed("HTTP \(http.statusCode)")
        }
        try FileManager.default.moveItem(at: localURL, to: tmpFile)
        return tmpFile
    }

    /// Unpack an official llama.cpp tarball into the managed runtime and make it current.
    ///
    /// The archive is a single top-level directory (`llama-b11056/`) whose binaries
    /// resolve their dylibs through `@loader_path`, so the whole directory is kept
    /// intact and `current` is pointed at it atomically.
    nonisolated static func stage(archive: URL, build: Int) throws {
        let fm = FileManager.default
        let root = managedRoot()
        let dest = "\(root)/b\(build)"
        let staging = "\(root)/.staging-\(build)"

        try? fm.removeItem(atPath: staging)
        try? fm.removeItem(atPath: dest)
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", archive.path, "-C", staging, "--strip-components=1"]
        let errPipe = Pipe()
        tar.standardError = errPipe
        tar.standardOutput = errPipe
        try tar.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        tar.waitUntilExit()
        guard tar.terminationStatus == 0 else {
            let msg = String(data: errData, encoding: .utf8) ?? "tar exited \(tar.terminationStatus)"
            throw RuntimeError.installFailed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let binary = "\(staging)/llama-server"
        guard fm.fileExists(atPath: binary) else {
            throw RuntimeError.installFailed("Archive did not contain llama-server")
        }

        try harden(directory: staging)
        try fm.moveItem(atPath: staging, toPath: dest)

        // Point `current` at the new build atomically.
        let current = "\(root)/current"
        let link = "\(root)/.current-link"
        try? fm.removeItem(atPath: link)
        try fm.createSymbolicLink(atPath: link, withDestinationPath: "b\(build)")
        if fm.fileExists(atPath: current) {
            _ = try fm.replaceItemAt(URL(fileURLWithPath: current),
                                     withItemAt: URL(fileURLWithPath: link))
        } else {
            try fm.moveItem(atPath: link, toPath: current)
        }

        // Write a marker so the build is known even if the binary can't run.
        try? "\(build)".write(toFile: "\(dest)/.jxrouter-build", atomically: true, encoding: .utf8)
        try? fm.removeItem(at: archive)
    }

    /// Make a freshly extracted runtime executable on this Mac:
    /// clear the download quarantine flag and mark every Mach-O file runnable.
    nonisolated static func harden(directory: String) throws {
        let fm = FileManager.default
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", directory]
        try? xattr.run()
        xattr.waitUntilExit()

        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return }
        for entry in entries {
            let path = "\(directory)/\(entry)"
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue else { continue }
            // Executables and dylibs both need the exec bit — dyld refuses to
            // mmap a non-executable image on some macOS versions.
            if entry.hasSuffix(".dylib") || entry.hasPrefix("llama-") || !entry.contains(".") {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: 0o755)], ofItemAtPath: path)
            }
        }
    }
}

// MARK: - Download progress observer

private final class DownloadObserver: NSObject, URLSessionDownloadDelegate {
    let onProgress: @Sendable (Double) -> Void

    init(progress: @escaping @Sendable (Double) -> Void) {
        self.onProgress = progress
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        onProgress(1.0)
    }
}
