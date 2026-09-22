import Foundation
import CoreServices

// MARK: - Models

/// Why a file was or was not inlined into the context block.
enum GatewayFileKind: String, Sendable, Codable {
    case text
    case binarySkip = "binary-skip"
    case oversized
}

/// One indexed file, relative to the watched root.
struct GatewayFileEntry: Sendable, Codable, Hashable, Identifiable {
    var path: String
    var size: Int64
    var tokens: Int
    var kind: GatewayFileKind

    var id: String { path }
}

/// The compiled view of the watched directory.
struct GatewaySnapshot: Sendable {
    var root: String
    var files: [GatewayFileEntry]
    var totalTokens: Int
    var totalBytes: Int64
    var asOf: Date
    var xml: String

    var inlinedCount: Int { files.filter { $0.kind == .text }.count }
}

/// The >70% context guard.
struct GatewayBudgetReport: Sendable {
    var contextSize: Int
    var gatewayTokens: Int
    var percent: Double
    var exceeded: Bool
    var advice: String
}

// MARK: - Settings

/// Persisted gateway configuration. Stored as one JSON blob so adding a field
/// never requires a new UserDefaults key.
struct GatewaySettings: Sendable, Codable, Equatable {
    var enabled: Bool = false
    var rootPath: String = ""
    var extraExcludes: String = ""
    var maxInlineBytes: Int = SourceOfTruthGateway.defaultMaxInlineBytes
    /// 0 means "unknown", which disables the budget guard.
    var contextTokens: Int = 0
    var injectIntoSystemPrompt: Bool = true

    var excludePatterns: [String] {
        extraExcludes
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Gateway

/// Watches a "source of truth" directory and compiles it into an
/// authoritative `<source_of_truth>` XML block that is prepended to the
/// system prompt, so the local model answers from the project's real contents
/// instead of guessing at them.
///
/// Ported from the Go implementation's `internal/gateway/watcher.go`. The
/// Swift app had no equivalent: it forwarded whatever system prompt the
/// client already sent and nothing else.
@Observable
final class SourceOfTruthGateway {

    static let shared = SourceOfTruthGateway()

    /// 512 KiB — matches the Go cap and keeps one pathological file from
    /// eating the context.
    static let defaultMaxInlineBytes = 512 * 1024

    /// Alert threshold from the Go implementation.
    static let budgetPercentThreshold: Double = 70

    private static let settingsKey = "jxrouter.gatewaySettingsJSON"
    private static let debounceSeconds: Double = 0.75

    // Directory names always ignored. Matches the Go `DefaultExcludeDirs`.
    static let defaultExcludeDirs: Set<String> = [
        ".git", "node_modules", "dist", "build", ".next", "target",
        "__pycache__", ".venv", "venv", ".cache", ".DS_Store",
    ]

    // Extensions never inlined. Matches the Go `BinaryExts`.
    static let binaryExts: Set<String> = [
        ".exe", ".bin", ".so", ".dylib", ".dll", ".png", ".jpg", ".jpeg",
        ".gif", ".webp", ".ico", ".pdf", ".zip", ".tar", ".gz", ".gguf",
        ".mp4", ".mov", ".mp3", ".wav", ".woff", ".woff2", ".ttf", ".o",
        ".a", ".pyc", ".class", ".wasm",
    ]

    // MARK: State

    var settings: GatewaySettings
    private(set) var snapshot: GatewaySnapshot?
    private(set) var isWatching = false
    private(set) var isScanning = false
    private(set) var lastError: String?

    /// Precomputed context block. The proxy builds prompts on background
    /// threads, so the hot path must not touch `@Observable` storage (or the
    /// main actor) — it reads this cache under a lock instead, and the cache
    /// is refreshed only when the snapshot or settings change.
    private let cacheLock = NSLock()
    private var cachedBlock: String?

    private let scanQueue = DispatchQueue(label: "com.jxrouter.gateway.scan", qos: .utility)
    private let fsQueue = DispatchQueue(label: "com.jxrouter.gateway.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?
    private var debounceWork: DispatchWorkItem?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.settingsKey),
           let decoded = try? JSONDecoder().decode(GatewaySettings.self, from: data) {
            settings = decoded
        } else {
            settings = GatewaySettings()
        }
    }

    deinit { stopWatching() }

    // MARK: - Configuration

    /// Mutate and persist settings, re-arming the watcher when the root or
    /// enabled flag changed.
    func update(_ mutate: (inout GatewaySettings) -> Void) {
        let before = settings
        var next = settings
        mutate(&next)
        settings = next
        persist()

        // Dropping the cache immediately means a disabled gateway stops
        // injecting on the very next request, without waiting for a rescan.
        recomputeCache()

        let rootChanged = next.rootPath != before.rootPath
        let enabledChanged = next.enabled != before.enabled
        if rootChanged || enabledChanged {
            if next.enabled, !next.rootPath.isEmpty {
                startWatching()
                scheduleRescan()
            } else {
                stopWatching()
            }
        } else if next.enabled, !next.rootPath.isEmpty {
            // Debounced: typing in the exclude list would otherwise rescan
            // the whole tree on every keystroke.
            scheduleRescan()
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.settingsKey)
    }

    // MARK: - Budget

    func budgetReport() -> GatewayBudgetReport {
        Self.evaluateBudget(contextSize: settings.contextTokens,
                            gatewayTokens: snapshot?.totalTokens ?? 0)
    }

    static func evaluateBudget(contextSize: Int, gatewayTokens: Int) -> GatewayBudgetReport {
        guard contextSize > 0 else {
            return GatewayBudgetReport(contextSize: contextSize, gatewayTokens: gatewayTokens,
                                       percent: 0, exceeded: false,
                                       advice: "context size unknown")
        }
        let percent = 100 * Double(gatewayTokens) / Double(contextSize)
        let exceeded = percent > budgetPercentThreshold
        let advice: String
        if exceeded {
            advice = String(format: "gateway consumes %.1f%% of context (>%.0f%%); switching to on-demand indexed tree mode",
                            percent, budgetPercentThreshold)
        } else {
            advice = String(format: "gateway uses %.1f%% of context; full ingestion active", percent)
        }
        return GatewayBudgetReport(contextSize: contextSize, gatewayTokens: gatewayTokens,
                                   percent: percent, exceeded: exceeded, advice: advice)
    }

    /// chars/4 heuristic, matching the Go estimator. Measured on UTF-8 bytes
    /// so CJK-heavy trees are not undercounted.
    static func estimateTokens(_ s: String) -> Int {
        let n = s.utf8.count / 4
        return (n == 0 && !s.isEmpty) ? 1 : n
    }

    // MARK: - Scanning

    func rescan() {
        guard settings.enabled, !settings.rootPath.isEmpty else { return }
        let root = settings.rootPath
        let excludes = settings.excludePatterns
        let cap = settings.maxInlineBytes

        isScanning = true
        scanQueue.async { [weak self] in
            let snap = Self.buildSnapshot(root: root, excludes: excludes, maxInlineBytes: cap)
            DispatchQueue.main.async {
                guard let self else { return }
                self.snapshot = snap
                self.lastError = nil
                self.isScanning = false
                self.recomputeCache()
            }
        }
    }

    /// Synchronous, thread-safe tree walk. Marked `nonisolated` so it can run
    /// off the main actor.
    nonisolated static func buildSnapshot(root: String,
                                          excludes: [String],
                                          maxInlineBytes: Int) -> GatewaySnapshot {
        var files: [GatewayFileEntry] = []
        var totalTokens = 0
        var totalBytes: Int64 = 0
        var xml = "<source_of_truth path=\"\(Self.xmlEscape(root))\">\n"

        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
            options: [.skipsPackageDescendants]
        ) else {
            xml += "</source_of_truth>\n"
            return GatewaySnapshot(root: root, files: [], totalTokens: 0,
                                   totalBytes: 0, asOf: Date(), xml: xml)
        }

        let rootURL = URL(fileURLWithPath: root).standardizedFileURL

        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            let isDir = values?.isDirectory ?? false

            guard let rel = Self.relativePath(from: rootURL, to: url) else { continue }

            if isDir {
                if Self.defaultExcludeDirs.contains((url.lastPathComponent)) {
                    enumerator.skipDescendants()
                    continue
                }
                if Self.matchAny(rel, excludes) {
                    enumerator.skipDescendants()
                    continue
                }
                continue
            }

            if Self.matchAny(rel, excludes) { continue }

            let size = Int64(values?.fileSize ?? 0)
            let ext = (url.pathExtension.isEmpty ? "" : "." + url.pathExtension).lowercased()

            if Self.binaryExts.contains(ext) {
                files.append(GatewayFileEntry(path: rel, size: size, tokens: 0, kind: .binarySkip))
                continue
            }
            if size > maxInlineBytes {
                files.append(GatewayFileEntry(path: rel, size: size, tokens: 0, kind: .oversized))
                continue
            }
            guard let data = fm.contents(atPath: url.path) else { continue }
            if Self.isBinaryData(data) {
                files.append(GatewayFileEntry(path: rel, size: size, tokens: 0, kind: .binarySkip))
                continue
            }
            let raw = String(decoding: data, as: UTF8.self)
            xml += "  <file path=\"\(Self.xmlEscape(rel))\">\(Self.xmlEscape(raw))</file>\n"
            let tokens = Self.estimateTokens(raw)
            totalTokens += tokens
            totalBytes += size
            files.append(GatewayFileEntry(path: rel, size: size, tokens: tokens, kind: .text))
        }

        xml += "</source_of_truth>\n"
        files.sort { $0.path < $1.path }
        return GatewaySnapshot(root: root, files: files, totalTokens: totalTokens,
                               totalBytes: totalBytes, asOf: Date(), xml: xml)
    }

    // MARK: - Context block

    /// The block to prepend to the system prompt, or `nil` when the gateway is
    /// off. Over budget it degrades to an index instead of inlining, which is
    /// exactly the fallback the Go implementation advises.
    ///
    /// Safe to call from any thread: it only reads the precomputed cache.
    nonisolated func contextBlock() -> String? {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        return cachedBlock
    }

    /// Rebuild the cache from the current settings plus snapshot. Called on
    /// the main thread whenever either changes.
    private func recomputeCache() {
        let block: String?
        if settings.enabled, settings.injectIntoSystemPrompt, let snap = snapshot {
            block = budgetReport().exceeded ? Self.indexTreeXML(snap) : snap.xml
        } else {
            block = nil
        }
        cacheLock.lock()
        cachedBlock = block
        cacheLock.unlock()
    }

    /// On-demand mode: paths and sizes only, no contents.
    nonisolated static func indexTreeXML(_ snap: GatewaySnapshot) -> String {
        var xml = "<source_of_truth path=\"\(xmlEscape(snap.root))\" mode=\"index\">\n"
        xml += "  <note>Contents omitted: the tree exceeds the context budget. "
        xml += "Ask for a specific file and it will be read on demand.</note>\n"
        for f in snap.files {
            let kind = f.kind.rawValue
            xml += "  <file path=\"\(xmlEscape(f.path))\" size=\"\(f.size)\" kind=\"\(kind)\" />\n"
        }
        xml += "</source_of_truth>\n"
        return xml
    }

    // MARK: - Watching

    func startWatching() {
        stopWatching()
        guard settings.enabled, !settings.rootPath.isEmpty else { return }

        var ctx = FSEventStreamContext(version: 0, info: nil, retain: nil, release: nil, copyDescription: nil)
        ctx.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(
            nil,
            { _, info, _, _, _, _ in
                guard let info else { return }
                let gateway = Unmanaged<SourceOfTruthGateway>.fromOpaque(info).takeUnretainedValue()
                gateway.scheduleRescan()
            },
            &ctx,
            [settings.rootPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            Self.debounceSeconds,
            flags
        ) else {
            lastError = "Could not create FSEvents stream"
            return
        }

        FSEventStreamSetDispatchQueue(s, fsQueue)
        guard FSEventStreamStart(s) else {
            FSEventStreamInvalidate(s)
            lastError = "Could not start FSEvents stream"
            return
        }
        stream = s
        isWatching = true
    }

    func stopWatching() {
        debounceWork?.cancel()
        debounceWork = nil
        if let s = stream {
            FSEventStreamStop(s)
            FSEventStreamInvalidate(s)
            stream = nil
        }
        isWatching = false
    }

    /// Coalesce bursts (a `git checkout` can fire thousands of events) into a
    /// single rescan.
    private func scheduleRescan() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        debounceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.debounceSeconds, execute: work)
    }

    // MARK: - Helpers

    nonisolated private static func relativePath(from root: URL, to url: URL) -> String? {
        let rootPath = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        guard full.hasPrefix(rootPath) else { return nil }
        var rel = String(full.dropFirst(rootPath.count))
        if rel.hasPrefix("/") { rel = String(rel.dropFirst()) }
        return rel.isEmpty ? nil : rel
    }

    /// gitignore-style matching: plain names, `*.ext`, `dir/` prefixes.
    nonisolated static func matchAny(_ rel: String, _ patterns: [String]) -> Bool {
        for rawPattern in patterns {
            var p = rawPattern.trimmingCharacters(in: .whitespaces)
            if p.isEmpty || p.hasPrefix("#") { continue }
            p = p.replacingOccurrences(of: "!", with: "", options: .anchored)

            if p.hasSuffix("/") {
                // A trailing slash marks a directory rule. The Go original
                // only anchored it at the root; gitignore actually matches a
                // directory of that name at any depth, which is what a user
                // typing "build/" expects, so match both.
                if rel.hasPrefix(p) { return true }
                let name = String(p.dropLast())
                if !name.contains("/") && rel.contains("/" + p) { return true }
                continue
            }
            if p.contains("*") {
                // Compile once, then try both the full relative path and the
                // basename, as the Go version does.
                guard let g = try? NSRegularExpression(pattern: Self.globToRegex(p)) else { continue }
                let base = (rel as NSString).lastPathComponent
                if g.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil { return true }
                if g.firstMatch(in: base, range: NSRange(base.startIndex..., in: base)) != nil { return true }
                continue
            }
            if p == rel || rel.hasSuffix("/" + p) { return true }
        }
        return false
    }

    /// Minimal glob → regex for `*`, `?` and `**`.
    nonisolated private static func globToRegex(_ pattern: String) -> String {
        let chars = Array(pattern)
        var out = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "*" {
                if i + 1 < chars.count && chars[i + 1] == "*" {
                    out += ".*"   // ** crosses directory boundaries
                    i += 2
                } else {
                    out += "[^/]*"
                    i += 1
                }
            } else {
                if c == "?" {
                    out += "[^/]"
                } else if ".$()[]{}|\\^+".contains(c) {
                    out += "\\" + String(c)
                } else {
                    out += String(c)
                }
                i += 1
            }
        }
        return "^" + out + "$"
    }

    /// NUL-byte sniff over the head of the buffer, as in the Go version.
    nonisolated static func isBinaryData(_ data: Data) -> Bool {
        let limit = min(data.count, 4096)
        guard limit > 0 else { return false }
        return data.prefix(limit).contains(0)
    }

    nonisolated static func xmlEscape(_ s: String) -> String {
        var out = s
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&#39;")
        return out
    }
}
