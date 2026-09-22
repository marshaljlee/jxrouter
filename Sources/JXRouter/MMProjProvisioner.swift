import Foundation
import CryptoKit

/// One candidate multimodal projector on the Hugging Face Hub.
struct MMProjCandidate: Identifiable, Hashable, Sendable {
    let repo: String
    let file: String
    var sizeMB: Int64 = 0
    let url: String
    var sha256: String?
    var score: Double = 0

    var id: String { "\(repo)/\(file)" }

    var sizeText: String {
        guard sizeMB > 0 else { return "size unknown" }
        return sizeMB >= 1024
            ? String(format: "%.1f GB", Double(sizeMB) / 1024)
            : "\(sizeMB) MB"
    }
}

/// Streaming download state.
struct MMProjDownloadProgress: Sendable {
    var received: Int64
    var total: Int64          // 0 = unknown
    var percent: Double
    var speedBps: Int64
}

enum MMProjError: LocalizedError {
    case badStatus(Int)
    case shaMismatch(expected: String, got: String)
    case noCandidates

    var errorDescription: String? {
        switch self {
        case .badStatus(let c): return "Hugging Face returned HTTP \(c)"
        case .shaMismatch(let e, let g): return "sha256 mismatch: expected \(e), got \(g)"
        case .noCandidates: return "No mmproj file found for this model"
        }
    }
}

/// Resolves and downloads missing multimodal projectors (mmproj) from the
/// Hugging Face Hub.
///
/// Ported from the Go implementation's `internal/provisioner`. The Swift app
/// previously expected the user to locate an mmproj by hand in Settings; when
/// none was set, vision models silently ran text-only.
actor MMProjProvisioner {

    static let shared = MMProjProvisioner()

    private static let hfAPI = "https://huggingface.co/api"
    private static let preferredOrgs = ["unsloth", "ggml-org", "bartowski", "Mfnit"]

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        return URLSession(configuration: cfg)
    }()

    // MARK: - Discovery

    /// Ranked list of mmproj candidates for a model.
    ///
    /// - `modelFile`: local GGUF filename, e.g. `Qwen3.5-4B_Q8_0.gguf`
    /// - `arch`: `general.architecture` from the GGUF header, e.g. `qwen35`
    /// - `quant`: quantization tag, e.g. `Q8_0`
    func findMMProj(modelFile: String, arch: String, quant: String) async -> [MMProjCandidate] {
        let base = Self.modelBaseName(modelFile)

        var seen = Set<String>()
        var all: [MMProjCandidate] = []

        // Well-known GGUF publishers first — highest signal, fewest requests.
        for org in Self.preferredOrgs {
            guard let cands = try? await listRepoMMProj(repo: "\(org)/\(base)-GGUF") else { continue }
            for c in cands where seen.insert(c.id).inserted {
                all.append(c)
            }
        }

        if all.isEmpty {
            guard let cands = try? await searchMMProj(base: base) else { return [] }
            for c in cands where seen.insert(c.id).inserted {
                all.append(c)
            }
        }

        for i in all.indices {
            all[i].score = Self.scoreCandidate(file: all[i].file, arch: arch, quant: quant)
        }
        return all.sorted { $0.score > $1.score }
    }

    /// Lists mmproj files in one repo.
    private func listRepoMMProj(repo: String) async throws -> [MMProjCandidate] {
        guard let url = URL(string: "\(Self.hfAPI)/models/\(repo)") else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MMProjError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let siblings = json["siblings"] as? [[String: Any]] else { return [] }

        var out: [MMProjCandidate] = []
        for s in siblings {
            guard let f = s["rfilename"] as? String,
                  f.lowercased().contains("mmproj"),
                  f.lowercased().hasSuffix(".gguf") else { continue }

            var cand = MMProjCandidate(
                repo: id,
                file: (f as NSString).lastPathComponent,
                url: "https://huggingface.co/\(id)/resolve/main/\(Self.pathEscape(f))"
            )
            if let meta = try? await fileMeta(repo: id, file: f) {
                cand.sizeMB = meta.size / (1024 * 1024)
                cand.sha256 = meta.sha256
            }
            out.append(cand)
        }
        return out
    }

    private struct FileMeta { let size: Int64; let sha256: String? }

    private func fileMeta(repo: String, file: String) async throws -> FileMeta {
        guard let url = URL(string: "\(Self.hfAPI)/models/\(repo)/tree/main/\(Self.pathEscape(file))") else {
            throw MMProjError.badStatus(0)
        }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MMProjError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = arr.first else { throw MMProjError.badStatus(0) }

        let size = (first["size"] as? NSNumber)?.int64Value ?? 0
        var sha: String?
        if let lfs = first["lfs"] as? [String: Any], let oid = lfs["oid"] as? String {
            sha = oid.replacingOccurrences(of: "sha256:", with: "")
        }
        return FileMeta(size: size, sha256: sha)
    }

    /// Fallback: search the hub for vision GGUF repos.
    private func searchMMProj(base: String) async throws -> [MMProjCandidate] {
        guard let escaped = base.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "\(Self.hfAPI)/models?search=\(escaped)&filter=gguf&limit=20") else { return [] }
        let (data, response) = try await session.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw MMProjError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let hits = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }

        var out: [MMProjCandidate] = []
        for h in hits {
            guard let id = h["id"] as? String,
                  let cands = try? await listRepoMMProj(repo: id) else { continue }
            out.append(contentsOf: cands)
        }
        return out
    }

    // MARK: - Ranking

    /// Higher is better: exact quant match, then f16/f32 defaults, then
    /// family-name hint.
    nonisolated static func scoreCandidate(file: String, arch: String, quant: String) -> Double {
        let f = file.lowercased()
        var s = 0.0
        if !quant.isEmpty, f.contains(quant.lowercased()) { s += 50 }
        if f.contains("f16") { s += 30 }
        if f.contains("f32") { s += 20 }
        let fam = arch.lowercased()
        if fam.count >= 4, f.contains(fam) { s += 10 }
        if f.contains("mmproj") { s += 5 }
        return s
    }

    /// `Qwen3.5-4B_Q8_0.gguf` → `Qwen3.5-4B`.
    ///
    /// The Go original did an extra `TrimSuffix(name, filepath.Ext(name))`
    /// after stripping `.gguf`, which for a dotted name like `Qwen3.5-4B_Q8_0`
    /// removes `.5-4B_Q8_0` and yields `Qwen3` — a bug that breaks repo
    /// guessing for exactly the models this targets. Only quant suffixes are
    /// stripped here.
    nonisolated static func modelBaseName(_ modelFile: String) -> String {
        var name = modelFile
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        for sep in ["_", "-", "."] {
            if let range = name.range(of: "\(sep)Q", options: .backwards),
               range.lowerBound > name.startIndex,
               Self.quantStart(String(name[range.lowerBound...].dropFirst())) {
                name = String(name[..<range.lowerBound])
                break
            }
        }
        return name.trimmingCharacters(in: CharacterSet(charactersIn: "_-."))
    }

    private static func quantStart(_ s: String) -> Bool {
        guard s.count >= 3 else { return false }
        let c0 = s[s.startIndex]
        let c1 = s[s.index(after: s.startIndex)]
        return (c0 == "Q" || c0 == "q" || c0 == "I" || c0 == "i") && c1.isASCII && c1.isNumber
    }

    // MARK: - Local scan

    /// An existing `*mmproj*.gguf` next to the model, or nil.
    nonisolated static func localMMProj(dir: String) -> String? {
        let found = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.lowercased().contains("mmproj") && $0.lowercased().hasSuffix(".gguf") }
            .sorted() ?? []
        guard let first = found.first else { return nil }
        return (dir as NSString).appendingPathComponent(first)
    }

    nonisolated static func isMMProjFile(_ name: String) -> Bool {
        let n = name.lowercased()
        return n.contains("mmproj") && n.hasSuffix(".gguf")
    }

    /// Non-mmproj `*.gguf` files directly inside `dir`.
    nonisolated static func discoverLocalModels(dir: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.lowercased().hasSuffix(".gguf") && !isMMProjFile($0) } ?? []).sorted()
    }

    // MARK: - Download

    /// Downloads to `<name>.part`, verifies SHA256 when known, then renames
    /// atomically. Resumes an existing `.part` via HTTP Range.
    func download(from urlString: String,
                  destDir: String,
                  destName: String,
                  expectedSHA: String? = nil,
                  onProgress: (@Sendable (MMProjDownloadProgress) -> Void)? = nil) async throws -> String {
        guard let url = URL(string: urlString) else { throw MMProjError.badStatus(0) }
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)

        let final = (destDir as NSString).appendingPathComponent(destName)
        let part = final + ".part"

        let have = (try? FileManager.default.attributesOfItem(atPath: part)[.size] as? NSNumber)?.int64Value ?? 0

        var request = URLRequest(url: url)
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }

        let delegate = DownloadDelegate(partPath: part, resumeFrom: have, onProgress: onProgress)
        let delegateSession = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            delegate.completion = cont
            let task = delegateSession.dataTask(with: request)
            task.resume()
        }
        delegateSession.invalidateAndCancel()

        // Flush before the integrity check.
        try? delegate.close()

        if let expectedSHA, !expectedSHA.isEmpty {
            let got = try Self.sha256File(part)
            guard got == expectedSHA else {
                try? FileManager.default.removeItem(atPath: part)
                throw MMProjError.shaMismatch(expected: expectedSHA, got: got)
            }
        }

        try FileManager.default.moveItem(atPath: part, toPath: final)
        return final
    }

    nonisolated static func sha256File(_ path: String) throws -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { throw MMProjError.badStatus(0) }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = handle.readData(ofLength: 1 << 20)
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func pathEscape(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? s
    }
}

// MARK: - Streaming download delegate

/// Writes straight to disk so a multi-GB projector never lands in memory.
private final class DownloadDelegate: NSObject, URLSessionDataDelegate {
    private let partPath: String
    private var handle: FileHandle?
    private let resumeFrom: Int64
    private var received: Int64
    /// Bytes already on disk before this attempt started — the speed baseline.
    private var base: Int64
    private var total: Int64 = 0
    private let started = Date()
    private let onProgress: (@Sendable (MMProjDownloadProgress) -> Void)?
    var completion: CheckedContinuation<Void, Error>?

    init(partPath: String, resumeFrom: Int64, onProgress: (@Sendable (MMProjDownloadProgress) -> Void)?) {
        self.partPath = partPath
        self.resumeFrom = resumeFrom
        self.received = resumeFrom
        self.base = resumeFrom
        self.onProgress = onProgress
        super.init()
    }

    func close() throws {
        try handle?.synchronize()
        try handle?.close()
        handle = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        switch http.statusCode {
        case 206:  // partial content: resume accepted, keep the bytes we have
            total = resumeFrom + response.expectedContentLength
            if !FileManager.default.fileExists(atPath: partPath) {
                FileManager.default.createFile(atPath: partPath, contents: nil)
            }
        case 200:
            total = response.expectedContentLength
            // Server ignored Range — restart from zero, discarding the partial.
            received = 0
            base = 0
            try? FileManager.default.removeItem(atPath: partPath)
            FileManager.default.createFile(atPath: partPath, contents: nil)
        default:
            completionHandler(.cancel)
            completion?.resume(throwing: MMProjError.badStatus(http.statusCode))
            completion = nil
            return
        }
        handle = FileHandle(forWritingAtPath: partPath)
        if received > 0 { _ = try? handle?.seekToEnd() }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        try? handle?.write(contentsOf: data)
        received += Int64(data.count)
        guard total > 0 else { return }
        let elapsed = Date().timeIntervalSince(started)
        let bps = elapsed > 0 ? Int64(Double(received - base) / elapsed) : 0
        onProgress?(MMProjDownloadProgress(received: received, total: total,
                                           percent: 100 * Double(received) / Double(total),
                                           speedBps: bps))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // Keep the .part so a later attempt can resume.
            completion?.resume(throwing: error)
        } else {
            completion?.resume()
        }
        completion = nil
    }
}
