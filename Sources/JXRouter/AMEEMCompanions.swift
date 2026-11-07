import Foundation

/// Little-endian scalar reads over a byte buffer.
///
/// Explicit byte assembly rather than `load(as:)`: a `Data`'s storage is not
/// guaranteed to be aligned for the scalar being read, and an unaligned `load`
/// traps at runtime (`load from misaligned raw pointer`).
enum AMEEMByteOrder {
    static func u16(_ data: Data, _ offset: Int = 0) -> UInt16? {
        guard let b = bytes(data, offset, 2) else { return nil }
        return UInt16(b[0]) | (UInt16(b[1]) << 8)
    }
    static func u32(_ data: Data, _ offset: Int = 0) -> UInt32? {
        guard let b = bytes(data, offset, 4) else { return nil }
        return UInt32(b[0]) | (UInt32(b[1]) << 8) | (UInt32(b[2]) << 16) | (UInt32(b[3]) << 24)
    }
    static func u64(_ data: Data, _ offset: Int = 0) -> UInt64? {
        guard let b = bytes(data, offset, 8) else { return nil }
        var value: UInt64 = 0
        for index in (0..<8).reversed() { value = (value << 8) | UInt64(b[index]) }
        return value
    }
    private static func bytes(_ data: Data, _ offset: Int, _ count: Int) -> [UInt8]? {
        guard offset >= 0, offset + count <= data.count else { return nil }
        let base = data.startIndex + offset
        return Array(data[base..<(base + count)])
    }
}

/// AMEEM v3.0 — companions (vision projectors) are not models (G-17, G-19).
///
/// A projector is a vision tower that loads alongside a text model and can never
/// be served alone: it has no output head, so it cannot generate a token. Two
/// independent header markers identify one — `general.architecture == "clip"`
/// **or** `general.type == "mmproj"` — and both must be checked, because a tower
/// published under some other architecture is caught only by the second.
///
/// The deployment hazard is concrete: a GGUF server lists a projector in
/// `/v1/models` and reports it as text-in / text-out, because the router reads
/// the *preset* rather than the GGUF header. Routing a chat request there hangs
/// or returns garbage, and the projector silently wins any "smallest model that
/// fits" selection because it is the smallest thing in the list (C-22).
enum AMEEMCompanions {

    static let ggufMagic: [UInt8] = Array("GGUF".utf8)
    static let projectorArch = "clip"
    static let projectorType = "mmproj"

    // MARK: - Filename normalisation

    /// NOTE: word boundaries are wrong for the quant token. `_` IS a word
    /// character, so `\b` does not fire between the `K` and the `_` of `Q4_K_M`
    /// and the suffix survives. Explicit lookarounds against `[a-z0-9]` are used
    /// instead, and `_` is allowed inside the token so the full `q4_k_m` is
    /// consumed in one go.
    private static let reQuantToken = try? NSRegularExpression(
        pattern: #"(?<![a-z0-9])(?:q[2-8]_[0-9a-z_]+|iq[1-4]_[a-z0-9_]+|tq[12]_0|bf16|fp16|fp8|f16|f32|f64|q[2-8])(?![a-z0-9])"#,
        options: [.caseInsensitive])
    private static let reMmprojPrefix = try? NSRegularExpression(
        pattern: #"^(?:mm_?proj|vision|clip)[\s._-]+"#, options: [.caseInsensitive])
    private static let reMmprojInfix = try? NSRegularExpression(
        pattern: #"[\s._-]*mm_?proj[\s._-]*"#, options: [.caseInsensitive])

    /// Normalise a filename to a pairing key.
    ///
    /// Three layouts occur in practice, and a naive stem match misses two of
    /// them:
    ///     `mmproj X.gguf`   prefix + space
    ///     `mmproj-X.gguf`   prefix + hyphen
    ///     `X.mmproj.gguf`   infix
    /// The quantisation suffix is stripped too, because a projector is normally
    /// shipped at a different precision than the model it belongs to, so an
    /// exact stem comparison would fail on a correctly paired set.
    static func companionKey(_ path: String) -> String {
        var name = (path as NSString).lastPathComponent
        if name.lowercased().hasSuffix(".gguf") { name = String(name.dropLast(5)) }
        name = replace(reMmprojPrefix, in: name, with: "")
        name = replace(reMmprojInfix, in: name, with: " ")
        name = replace(reQuantToken, in: name, with: " ")
        name = name.lowercased().replacingOccurrences(
            of: #"[^a-z0-9.]+"#, with: " ", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// The projector that pairs with `modelPath`, if any.
    static func findCompanion(modelPath: String, candidates: [String]) -> String? {
        let key = companionKey(modelPath)
        guard !key.isEmpty else { return nil }
        for candidate in candidates where candidate != modelPath {
            if companionKey(candidate) == key { return candidate }
        }
        return nil
    }

    // MARK: - GGUF header markers

    /// Read only the header keys needed to identify a file. Never loads tensors.
    /// Returns an empty dictionary for a non-GGUF or unreadable file.
    static func readMarkers(path: String, maxBytes: Int = 262_144) -> [String: String] {
        let wanted: Set<String> = ["general.architecture", "general.type"]
        var markers: [String: String] = [:]
        guard let handle = FileHandle(forReadingAtPath: path) else { return markers }
        defer { try? handle.close() }

        func read(_ count: Int) -> Data? {
            guard count >= 0, let data = try? handle.read(upToCount: count), data.count == count
            else { return nil }
            return data
        }

        guard let magic = read(4), Array(magic) == ggufMagic else { return markers }
        guard let verData = read(4), let version = AMEEMByteOrder.u32(verData), (1...4).contains(version) else {
            return markers
        }
        guard read(8) != nil else { return markers }                       // tensor count
        guard let kvData = read(8), let kvCount = AMEEMByteOrder.u64(kvData) else { return markers }
        var consumed = 24

        for _ in 0..<kvCount {
            guard let klenData = read(8), let klen = AMEEMByteOrder.u64(klenData).map(Int.init) else { return markers }
            guard let keyData = read(klen), let key = String(data: keyData, encoding: .utf8) else { return markers }
            guard let vtypeData = read(4), let vtype = AMEEMByteOrder.u32(vtypeData) else { return markers }
            consumed += 8 + klen + 4
            if consumed > maxBytes { break }
            if wanted.contains(key), vtype == 8 {
                guard let slenData = read(8), let slen = AMEEMByteOrder.u64(slenData).map(Int.init) else { return markers }
                guard let strData = read(slen),
                      let value = String(data: strData, encoding: .utf8) else { return markers }
                markers[key] = value
                consumed += 8 + slen
            } else {
                guard let skipped = skipValue(vtype, read: read) else { return markers }
                consumed += skipped
            }
        }
        return markers
    }

    /// Advance past one GGUF value, returning the bytes consumed. Returns nil on
    /// a shape we cannot skip (an array of arrays), which simply ends the scan.
    private static func skipValue(_ vtype: UInt32, read: (Int) -> Data?) -> Int? {
        let widths: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]
        if vtype == 8 {
            guard let lenData = read(8), let n = AMEEMByteOrder.u64(lenData).map(Int.init) else { return nil }
            guard read(n) != nil else { return nil }
            return 8 + n
        }
        guard let width = widths[vtype] else { return nil }
        guard read(width) != nil else { return nil }
        return width
    }

    /// True when the file is a vision projector rather than a language model.
    static func isProjector(path: String) -> Bool {
        let markers = readMarkers(path: path)
        if markers["general.architecture"] == projectorArch { return true }
        return markers["general.type"]?.lowercased() == projectorType
    }

    // MARK: - Audit (G-19)

    /// Report served projectors and unpaired companions from a `/v1/models`
    /// payload. A projector served as a model is an ERROR; a companion on disk
    /// that is not attached to its model is a WARNING — the model still answers
    /// text prompts fine and simply never sees images.
    static func auditCompanions(entries: [[String: Any]]) -> [String] {
        var findings: [String] = []
        var modelPaths: [String] = []
        var projectorPaths: [String] = []
        var served: [(path: String, args: [String], id: String)] = []

        for entry in entries {
            let id = (entry["id"] as? String) ?? "?"
            let status = entry["status"] as? [String: Any]
            let args = (status?["args"] as? [String]) ?? []
            guard let idx = args.firstIndex(of: "--model"), args.count > idx + 1 else { continue }
            let path = args[idx + 1]

            // A preset can point at a file that was moved, renamed, or deleted.
            // The server still advertises the model, and the failure only
            // surfaces at load time as a request that never answers.
            if !FileManager.default.fileExists(atPath: path) || readMarkers(path: path).isEmpty {
                findings.append("ERROR G-19: '\(id)' points at '\((path as NSString).lastPathComponent)', "
                    + "which is missing or is not a readable GGUF.")
                continue
            }
            if isProjector(path: path) {
                projectorPaths.append(path)
                findings.append("ERROR G-19: '\(id)' is served as a model but the file is a vision "
                    + "projector (architecture=\(projectorArch)). It has no output head and cannot "
                    + "generate tokens. Remove its standalone preset and attach it to its text model "
                    + "with `mmproj = <path>`.")
            } else {
                modelPaths.append(path)
                served.append((path, args, id))
            }
        }

        for (path, args, id) in served {
            if let companion = findCompanion(modelPath: path, candidates: projectorPaths),
               !args.contains("--mmproj") {
                findings.append("WARN G-19: '\(id)' has a matching projector "
                    + "('\((companion as NSString).lastPathComponent)') that is not attached. "
                    + "Vision will silently not work for this model.")
            }
        }
        for path in projectorPaths where findCompanion(modelPath: path, candidates: modelPaths) == nil {
            findings.append("WARN G-19: projector '\((path as NSString).lastPathComponent)' has no "
                + "model to pair with. Orphaned companion.")
        }
        return findings
    }

    // MARK: - Helpers

    private static func replace(_ regex: NSRegularExpression?, in text: String, with template: String) -> String {
        guard let regex else { return text }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }
}
