import Foundation
import CryptoKit

/// AMEEM v3.0 — load-time preset reconciler.
///
/// The request-time gate adapts per *request*. But the server-side settings —
/// context size, samplers, jinja, projector attachment — live in the preset INI
/// and are read **once at process start**. A model loaded with a stale or
/// hand-edited preset is miscalibrated before the first request arrives, and no
/// amount of request-time logic can fix that.
///
/// So the automation has two halves: request time (`AMEEMRequestGate`) and load
/// time (this file). This is the Swift port of `ameem_preset_reconcile.py`, and
/// it obeys the same safety rule (I4): it never silently rewrites a file another
/// process owns. Proposals go to `<presets>.ameem-new`; overwriting the live
/// file requires an explicit flag and takes a timestamped backup first. Comment
/// lines belonging to the launcher are preserved verbatim.
enum AMEEMPresetReconciler {

    // MARK: - Constants

    static let projectorArch = AMEEMCompanions.projectorArch
    static let projectorType = AMEEMCompanions.projectorType

    static let tempDefault = AMEEMSamplerPolicy.tempDefault
    static let topPDefault = AMEEMSamplerPolicy.topP
    static let topKDefault = AMEEMSamplerPolicy.topK
    static let minPDefault = AMEEMSamplerPolicy.minP
    static let ctxCeilingDefault = 65536
    static let batchDefault = 2048

    /// Marker substrings that indicate a template exposes reasoning controls.
    static let reasoningMarkers = [
        "preserve_thinking", "preserve_reasoning", "reasoning_effort",
        "thinking_effort", "enable_thinking",
    ]

    /// Default preset path for the Hermes llama.cpp runtime.
    static var defaultPresetsPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.hermes/runtimes/llamacpp/presets.ini"
    }

    // MARK: - Facts

    struct Facts: Sendable {
        var path: String
        var size: Int64
        var architecture = ""
        var generalType = ""
        var name = ""
        var nCtxTrain = 0
        var eosID: Int?
        var template = ""
        var error = ""

        var isProjector: Bool {
            architecture == projectorArch || generalType.lowercased() == projectorType
        }
        var supportsReasoningControls: Bool {
            let low = template.lowercased()
            return reasoningMarkers.contains { low.contains($0) }
        }
    }

    // MARK: - GGUF header reader (in-memory, header only)

    /// Read the keys the reconciler needs. Never loads tensors; the KV section is
    /// read into memory up to a cap and tokenizer arrays are skipped by index.
    static func readGGUF(path: String, maxHeaderBytes: Int = 64 * 1024 * 1024) -> Facts {
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        var facts = Facts(path: path, size: size)
        guard let handle = FileHandle(forReadingAtPath: path) else {
            facts.error = "unreadable"
            return facts
        }
        defer { try? handle.close() }
        // Identify the file before demanding a full header: a five-byte file is
        // "not a GGUF", not a "truncated header", and the reason is reported (I5).
        guard let magic = try? handle.read(upToCount: 4), magic.count == 4 else {
            facts.error = "unreadable"
            return facts
        }
        guard Array(magic) == AMEEMCompanions.ggufMagic else {
            facts.error = "not a GGUF"
            return facts
        }
        guard let rest = try? handle.read(upToCount: 20), rest.count == 20 else {
            facts.error = "truncated header"
            return facts
        }
        let version = AMEEMByteOrder.u32(rest, 0) ?? 0
        guard (1...4).contains(version) else {
            facts.error = "unsupported GGUF version"
            return facts
        }
        let kvCount = AMEEMByteOrder.u64(rest, 12) ?? 0
        guard let tail = try? handle.read(upToCount: maxHeaderBytes - 24), !tail.isEmpty else {
            facts.error = "header unreadable"
            return facts
        }
        var data = Data(magic)
        data.append(rest)
        data.append(tail)

        var cursor = Cursor(data: data, offset: 24)
        var kv: [String: Any] = [:]
        for _ in 0..<kvCount {
            guard let key = cursor.string(), let vtype = cursor.u32() else {
                facts.error = "header truncated while reading key"
                return facts
            }
            // Tokenizer arrays are megabytes; skip them without materializing.
            if key == "tokenizer.ggml.tokens" || key == "tokenizer.ggml.scores"
                || key == "tokenizer.ggml.merges" || key == "tokenizer.ggml.token_type" {
                guard cursor.skipValue(vtype) else { facts.error = "cannot skip \(key)"; return facts }
                continue
            }
            guard let value = cursor.value(vtype) else {
                facts.error = "header truncated while reading \(key)"
                return facts
            }
            kv[key] = value
        }

        facts.architecture = (kv["general.architecture"] as? String) ?? ""
        facts.generalType = (kv["general.type"] as? String) ?? ""
        facts.name = (kv["general.name"] as? String) ?? ""
        facts.template = (kv["tokenizer.chat_template"] as? String) ?? ""
        facts.eosID = kv["tokenizer.ggml.eos_token_id"] as? Int
        if !facts.architecture.isEmpty {
            facts.nCtxTrain = (kv["\(facts.architecture).context_length"] as? Int) ?? 0
        }
        return facts
    }

    /// A tiny big-endian-free cursor over an in-memory GGUF header.
    private struct Cursor {
        let data: Data
        var offset: Int

        mutating func raw(_ n: Int) -> Data? {
            guard n >= 0, offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: offset..<(offset + n))
        }
        mutating func u32() -> UInt32? { raw(4).flatMap { AMEEMByteOrder.u32($0) } }
        mutating func u64() -> UInt64? { raw(8).flatMap { AMEEMByteOrder.u64($0) } }
        mutating func string() -> String? {
            guard let len = u64(), len <= UInt64(data.count) else { return nil }
            guard let bytes = raw(Int(len)) else { return nil }
            return String(data: bytes, encoding: .utf8)
        }

        private static let widths: [UInt32: Int] = [0: 1, 1: 1, 2: 2, 3: 2, 4: 4, 5: 4, 6: 4, 7: 1, 10: 8, 11: 8, 12: 8]

        mutating func value(_ vtype: UInt32) -> Any? {
            switch vtype {
            case 7: return raw(1).map { $0[$0.startIndex] != 0 }
            case 0: return raw(1).map { Int($0[$0.startIndex]) }
            case 1: return raw(1).map { Int(Int8(bitPattern: $0[$0.startIndex])) }
            case 2: return raw(2).flatMap { AMEEMByteOrder.u16($0) }.map { Int($0) }
            case 3: return raw(2).map { Int(Int16(bitPattern: AMEEMByteOrder.u16($0) ?? 0)) }
            case 4: return raw(4).flatMap { AMEEMByteOrder.u32($0) }.map { Int($0) }
            case 5: return raw(4).map { Int(Int32(bitPattern: AMEEMByteOrder.u32($0) ?? 0)) }
            case 6: return raw(4).map { Double(Float(bitPattern: AMEEMByteOrder.u32($0) ?? 0)) }
            case 10: return raw(8).flatMap { AMEEMByteOrder.u64($0) }.map { Int($0) }
            case 11: return raw(8).map { Int(Int64(bitPattern: AMEEMByteOrder.u64($0) ?? 0)) }
            case 12: return raw(8).map { Double(bitPattern: AMEEMByteOrder.u64($0) ?? 0) }
            case 8: return string()
            case 9: return skipArray() == nil ? nil : 0
            default: return nil
            }
        }

        /// Consume an array. Returns the element count, or nil on failure.
        @discardableResult
        mutating func skipArray() -> Int? {
            guard let elemType = u32(), let count = u64(), count <= UInt64(data.count) else { return nil }
            if elemType == 8 {
                for _ in 0..<count {
                    guard let len = u64(), len <= UInt64(data.count), raw(Int(len)) != nil else { return nil }
                }
            } else if elemType == 9 {
                for _ in 0..<count where skipArray() == nil { return nil }
            } else {
                guard let width = Cursor.widths[elemType],
                      count * UInt64(width) <= UInt64(data.count),
                      raw(Int(count) * width) != nil else { return nil }
            }
            return Int(count)
        }

        mutating func skipValue(_ vtype: UInt32) -> Bool {
            if vtype == 9 { return skipArray() != nil }
            if vtype == 8 { return string() != nil }
            guard let width = Cursor.widths[vtype] else { return false }
            return raw(width) != nil
        }
    }

    /// The extension is a naming convention, not a property of the format.
    static func isGGUFFile(_ path: String) -> Bool {
        if path.lowercased().hasSuffix(".gguf") { return true }
        guard let handle = FileHandle(forReadingAtPath: path),
              let magic = try? handle.read(upToCount: 4) else { return false }
        defer { try? handle.close() }
        return Array(magic) == AMEEMCompanions.ggufMagic
    }

    // MARK: - Scanning

    /// Collect GGUF paths, following symlinks and ignoring hidden trees.
    static func scanModels(dirs: [String], maxDepth: Int = 2) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        let fm = FileManager.default
        for dir in dirs {
            let root = (dir as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root, isDirectory: &isDir), isDir.boolValue else {
                print("  ! skipping missing directory: \(root)")
                continue
            }
            let baseDepth = root.split(separator: "/").count
            guard let enumerator = fm.enumerator(atPath: root) else { continue }
            for case let relative as String in enumerator {
                let full = (root as NSString).appendingPathComponent(relative)
                let depth = full.split(separator: "/").count - baseDepth
                var isDirectory: ObjCBool = false
                guard fm.fileExists(atPath: full, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    let name = (full as NSString).lastPathComponent
                    if name.hasPrefix(".") || name == "__pycache__" || depth >= maxDepth {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                let real = (full as NSString).resolvingSymlinksInPath
                if seen.contains(real) { continue }
                if isGGUFFile(full) {
                    seen.insert(real)
                    found.append(full)
                }
            }
        }
        return found.sorted()
    }

    // MARK: - Identity and deduplication

    private static let reDigestName = try? NSRegularExpression(
        pattern: #"^(?:sha256-)?[0-9a-f]{40,}$"#, options: [.caseInsensitive])

    /// Content-addressed stores name a good model after its hash. A *picker*
    /// listing models for a human must skip it: the basename is not a usable
    /// label, and a generated preset section named after a digest is unusable too.
    static func isDigestName(_ path: String) -> Bool {
        var stem = (path as NSString).lastPathComponent
        if let dot = stem.lastIndex(of: ".") { stem = String(stem[stem.startIndex..<dot]) }
        guard let regex = reDigestName else { return false }
        let range = NSRange(stem.startIndex..<stem.endIndex, in: stem)
        return regex.firstMatch(in: stem, options: [], range: range) != nil
    }

    /// Three-chunk content digest. Identical byte size proves nothing — several
    /// fine-tunes can share an exact size and be entirely different models.
    static func sampleHash(_ path: String, chunk: Int = 2 << 20) -> String? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) else {
            return nil
        }
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        for offset in [0, max(0, size / 2 - Int64(chunk / 2)), max(0, size - Int64(chunk))] {
            try? handle.seek(toOffset: UInt64(offset))
            hasher.update(data: Data(withUnsafeBytes(of: UInt64(offset).littleEndian) { Data($0) }))
            if let data = try? handle.read(upToCount: chunk) { hasher.update(data: data) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Pairing

    /// Map model path -> projector path.
    static func pairCompanions(models: [Facts], projectors: [Facts]) -> [String: String] {
        var byKey: [String: [String]] = [:]
        for projector in projectors {
            byKey[AMEEMCompanions.companionKey(projector.path), default: []].append(projector.path)
        }
        var pairs: [String: String] = [:]
        for model in models {
            let key = AMEEMCompanions.companionKey(model.path)
            guard let candidates = byKey[key], !candidates.isEmpty else { continue }
            // Deterministic: prefer the smallest candidate, then alphabetical.
            pairs[model.path] = candidates.min { lhs, rhs in
                let ls = (try? FileManager.default.attributesOfItem(atPath: lhs)[.size] as? Int64) ?? 0
                let rs = (try? FileManager.default.attributesOfItem(atPath: rhs)[.size] as? Int64) ?? 0
                return ls == rs ? lhs < rhs : ls < rs
            }
        }
        return pairs
    }

    // MARK: - Preset generation

    static func sectionName(_ facts: Facts) -> String {
        let name = (facts.path as NSString).lastPathComponent
        return name.lowercased().hasSuffix(".gguf") ? String(name.dropLast(5)) : name
    }

    /// Build one preset section from measured facts alone. No name matching.
    static func derivePreset(_ facts: Facts, projector: String?, ctxCeiling: Int) -> [String: String] {
        let trained = facts.nCtxTrain > 0 ? facts.nCtxTrain : ctxCeiling
        let ctx = min(trained, ctxCeiling)
        var preset: [String: String] = [
            "model": facts.path,
            "ctx-size": String(ctx),
            "batch-size": String(batchDefault),
            "ubatch-size": String(batchDefault),
            "cache-type-k": "q8_0",
            "cache-type-v": "q8_0",
            "flash-attn": "on",
            "load-mode": "dio",
            "jinja": "1",
            "temp": String(format: "%g", tempDefault),
            "top-p": String(format: "%g", topPDefault),
            "top-k": String(topKDefault),
            "min-p": String(format: "%g", minPDefault),
        ]
        if let projector { preset["mmproj"] = projector }
        if facts.supportsReasoningControls { preset["reasoning"] = "on" }
        return preset
    }

    static func renderPresetFile(sections: [(name: String, fields: [String: String])],
                                 ownerComments: [String: [String]]) -> String {
        var out: [String] = []
        for (name, fields) in sections {
            out.append(contentsOf: ownerComments[name] ?? [])
            out.append("[\(name)]")
            for key in fields.keys.sorted() {
                out.append("\(key) = \(fields[key]!)")
            }
            out.append("")
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Existing preset parsing

    /// Return `(sections, ownerComments)`. A comment block immediately above a
    /// section header belongs to the process that wrote it; those lines are
    /// carried through untouched because we do not own that metadata.
    static func parsePresets(_ path: String) -> (sections: [String: [String: String]], comments: [String: [String]]) {
        var sections: [String: [String: String]] = [:]
        var comments: [String: [String]] = [:]
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            return (sections, comments)
        }
        var pending: [String] = []
        var current: String?
        for raw in content.components(separatedBy: "\n") {
            let stripped = raw.trimmingCharacters(in: .whitespaces)
            if stripped.hasPrefix("#") { pending.append(raw); continue }
            if stripped.hasPrefix("[") && stripped.hasSuffix("]") {
                current = String(stripped.dropFirst().dropLast())
                sections[current!] = [:]
                if !pending.isEmpty { comments[current!] = pending }
                pending = []
                continue
            }
            guard !stripped.isEmpty, let section = current, raw.contains("=") else { continue }
            let parts = raw.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 {
                sections[section]?[parts[0].trimmingCharacters(in: .whitespaces)] =
                    parts[1].trimmingCharacters(in: .whitespaces)
            }
        }
        return (sections, comments)
    }

    static func diffSections(proposed: [(name: String, fields: [String: String])],
                             existing: [String: [String: String]]) -> [String] {
        var findings: [String] = []
        let proposedNames = Set(proposed.map(\.name))
        for (name, fields) in proposed {
            guard let current = existing[name] else {
                findings.append("ADD    [\(name)]")
                continue
            }
            for (key, want) in fields {
                guard let have = current[key] else {
                    findings.append("ADD    [\(name)] \(key) = \(want)")
                    continue
                }
                if have != want { findings.append("CHANGE [\(name)] \(key): '\(have)' -> '\(want)'") }
            }
            for (key, value) in current where fields[key] == nil {
                findings.append("DROP   [\(name)] \(key) = '\(value)' (not derivable; confirm this is intentional)")
            }
        }
        for name in existing.keys where !proposedNames.contains(name) {
            findings.append("REMOVE [\(name)] (no matching file on disk — served but unresolvable)")
        }
        return findings
    }

    // MARK: - Report

    struct Report {
        var models: [Facts] = []
        var projectors: [Facts] = []
        var duplicates: [(path: String, why: String)] = []
        var skipped: [(path: String, why: String)] = []
        var unreadable: [Facts] = []
        var pairs: [String: String] = [:]
        var orphans: [Facts] = []
        var proposed: [(name: String, fields: [String: String])] = []
        var findings: [String] = []
        var scanned: Int = 0
    }

    /// Scan, classify, dedupe, pair and diff — the whole report, no writes.
    static func reconcile(modelsDirs: [String], presetsPath: String,
                          ctxCeiling: Int = ctxCeilingDefault) -> Report {
        var report = Report()
        let existing = parsePresets(presetsPath).sections
        let referenced = Set(existing.values.compactMap { $0["model"] }
            .map { ($0 as NSString).resolvingSymlinksInPath })

        let paths = scanModels(dirs: modelsDirs)
        report.scanned = paths.count

        var models: [Facts] = []
        var projectors: [Facts] = []
        for path in paths {
            if isDigestName(path) {
                report.skipped.append((path, "content-addressed basename; not a usable label"))
                continue
            }
            let facts = readGGUF(path: path)
            if !facts.error.isEmpty {
                report.unreadable.append(facts)
            } else if facts.isProjector {
                projectors.append(facts)
            } else if facts.template.isEmpty {
                // A chat preset is meaningless without a chat template. This is
                // also the general filter that keeps image and video diffusion
                // GGUFs out of the language-model set, without an architecture list.
                report.skipped.append((path, "no chat template (architecture=\(facts.architecture))"))
            } else {
                models.append(facts)
            }
        }

        // Deduplicate by content, not by path or by size.
        func dedupe(_ group: [Facts]) -> ([Facts], [(String, String)]) {
            var best: [String: Facts] = [:]
            var dropped: [(String, String)] = []
            for facts in group {
                guard let digest = sampleHash(facts.path) else {
                    dropped.append((facts.path, "unreadable while hashing")); continue
                }
                guard let winner = best[digest] else { best[digest] = facts; continue }
                // Prefer the copy the live preset already points at, so a
                // reconcile never silently relocates a working model.
                let factsReferenced = referenced.contains((facts.path as NSString).resolvingSymlinksInPath)
                let winnerReferenced = referenced.contains((winner.path as NSString).resolvingSymlinksInPath)
                if factsReferenced && !winnerReferenced {
                    best[digest] = facts
                    dropped.append((winner.path, "duplicate of \((facts.path as NSString).lastPathComponent)"))
                } else {
                    dropped.append((facts.path, "duplicate of \((winner.path as NSString).lastPathComponent)"))
                }
            }
            return (best.values.sorted { sectionName($0).lowercased() < sectionName($1).lowercased() }, dropped)
        }
        let (dedupedModels, dupModels) = dedupe(models)
        let (dedupedProjectors, dupProjectors) = dedupe(projectors)
        report.models = dedupedModels
        report.projectors = dedupedProjectors
        report.duplicates = dupModels + dupProjectors

        report.pairs = pairCompanions(models: dedupedModels, projectors: dedupedProjectors)

        // Section names must be unique.
        var used: [String: String] = [:]
        for facts in dedupedModels {
            var name = sectionName(facts)
            let digest = String((sampleHash(facts.path) ?? "").prefix(8))
            if let prior = used[name], prior != digest { name = "\(name)-\(digest)" }
            used[name] = digest
            report.proposed.append((name, derivePreset(facts, projector: report.pairs[facts.path], ctxCeiling: ctxCeiling)))
        }

        let paired = Set(report.pairs.values)
        report.orphans = dedupedProjectors.filter { !paired.contains($0.path) }
        report.findings = diffSections(proposed: report.proposed, existing: existing)
        return report
    }

    // MARK: - Session preflight (load-time trigger A)

    struct CheckResult {
        var fatal: [String] = []
        var warnings: [String] = []
        var isClean: Bool { fatal.isEmpty }
    }

    /// `--check`: refuse to proceed on fatal drift. A projector served as a model
    /// or a preset that points at a missing file is fatal; an unattached
    /// companion is a warning.
    static func check(modelsDirs: [String], presetsPath: String) -> CheckResult {
        var result = CheckResult()
        let (sections, _) = parsePresets(presetsPath)
        for (name, fields) in sections {
            guard let model = fields["model"], !model.isEmpty else { continue }
            if !FileManager.default.fileExists(atPath: model) {
                result.fatal.append("G-19: preset [\(name)] points at '\(model)', which is missing")
                continue
            }
            if AMEEMCompanions.isProjector(path: model) {
                result.fatal.append("G-17: preset [\(name)] serves a vision projector as a model "
                    + "('\((model as NSString).lastPathComponent)'); attach it with `mmproj = <path>`")
            } else if let mmproj = fields["mmproj"], !mmproj.isEmpty,
                      !FileManager.default.fileExists(atPath: mmproj) {
                result.fatal.append("G-19: preset [\(name)] attaches a missing projector '\(mmproj)'")
            }
        }
        let report = reconcile(modelsDirs: modelsDirs, presetsPath: presetsPath)
        for orphan in report.orphans {
            result.warnings.append("G-19: projector '\((orphan.path as NSString).lastPathComponent)' "
                + "has no model to pair with. Orphaned companion.")
        }
        return result
    }

    // MARK: - CLI

    /// Run the reconciler as a command. Mirrors `ameem_preset_reconcile.py`'s
    /// output so the two halves stay comparable.
    /// - Returns: 0 when in sync, 1 when drift exists or an error occurred.
    @discardableResult
    static func run(modelsDirs: [String], presetsPath: String,
                    ctxCeiling: Int = ctxCeilingDefault,
                    apply: Bool = false, inPlace: Bool = false,
                    quiet: Bool = false) -> Int32 {
        func say(_ message: String = "") { if !quiet { print(message) } }

        say("AMEEM preset reconciler")
        say("  model dirs : \(modelsDirs.joined(separator: ", "))")
        say("  presets    : \(presetsPath)")
        say("  ctx ceiling: \(ctxCeiling)")
        say()

        let report = reconcile(modelsDirs: modelsDirs, presetsPath: presetsPath, ctxCeiling: ctxCeiling)
        say("Scanning \(report.scanned) candidate file(s)...")
        say("  models      : \(report.models.count)")
        say("  companions  : \(report.projectors.count)")
        say("  duplicates  : \(report.duplicates.count)")
        say("  skipped     : \(report.skipped.count)")
        say("  unreadable  : \(report.unreadable.count)")
        say()

        if !report.projectors.isEmpty {
            say("Companions found (these must never have a section of their own):")
            for projector in report.projectors {
                say("  - \((projector.path as NSString).lastPathComponent)  [\(projector.architecture)]")
            }
            say()
        }

        say("Proposed sections:")
        for (name, fields) in report.proposed {
            let attached = fields["mmproj"].map { "  + mmproj: \((($0) as NSString).lastPathComponent)" } ?? ""
            say("  [\(name)]  ctx=\(fields["ctx-size"] ?? "?") temp=\(fields["temp"] ?? "?")\(attached)")
        }
        say()

        if !report.orphans.isEmpty {
            say("Orphaned companions (no model pairs with them):")
            for orphan in report.orphans { say("  ! \((orphan.path as NSString).lastPathComponent)") }
            say()
        }
        if !report.duplicates.isEmpty {
            say("Duplicates collapsed (same weights at more than one path):")
            for (path, why) in report.duplicates {
                say("  ~ \((path as NSString).lastPathComponent): \(why)")
            }
            say()
        }
        if !report.skipped.isEmpty {
            say("Skipped (reported, never silently dropped):")
            for (path, why) in report.skipped {
                say("  - \((path as NSString).lastPathComponent): \(why)")
            }
            say()
        }
        if !report.unreadable.isEmpty {
            say("Unreadable files (reported, never silently dropped):")
            for bad in report.unreadable {
                say("  ! \((bad.path as NSString).lastPathComponent): \(bad.error)")
            }
            say()
        }

        say("Drift against \((presetsPath as NSString).lastPathComponent): \(report.findings.count) finding(s)")
        for finding in report.findings { say("  \(finding)") }
        if report.findings.isEmpty { say("  (in sync)") }
        say()

        guard apply else {
            say("Report only. Re-run with apply to write a proposal.")
            return report.findings.isEmpty ? 0 : 1
        }

        let (_, comments) = parsePresets(presetsPath)
        let rendered = renderPresetFile(sections: report.proposed, ownerComments: comments)
        var target = "\(presetsPath).ameem-new"
        if inPlace {
            if FileManager.default.fileExists(atPath: presetsPath) {
                let stamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "")
                    .replacingOccurrences(of: "-", with: "")
                let backup = "\(presetsPath).bak-\(stamp)"
                try? FileManager.default.copyItem(atPath: presetsPath, toPath: backup)
                say("Backed up existing preset -> \((backup as NSString).lastPathComponent)")
            }
            target = presetsPath
        }
        do {
            try rendered.write(toFile: target, atomically: true, encoding: .utf8)
            say("Wrote proposal -> \(target)")
        } catch {
            say("ERROR: could not write \(target): \(error)")
            return 1
        }
        if inPlace {
            say()
            say("NOTE: the preset is read once at process start. Restart the server for this")
            say("      to take effect; unloading and reloading a model will NOT re-read it.")
        }
        return report.findings.isEmpty ? 0 : 1
    }
}
