import Foundation

/// A discovered GGUF model on disk, with metadata extracted from the GGUF header.
struct GGUFModelFile: Identifiable, Hashable {
    let id: String           // stable identifier (file path)
    let name: String         // display name (metadata general.name or filename stem)
    let path: String         // full file path
    let fileSizeBytes: Int64
    let architecture: String // e.g. "qwen35", "llama", "mistral"
    let contextLength: Int   // model's native context size
    let quantization: String // e.g. "Q8_0", "Q4_K_M"
    let chatTemplate: String // Jinja2 chat template (from metadata)
    var mmprojPath: String?  // Path to matched multimodal projector if any

    /// Human-readable file size string.
    var fileSizeFormatted: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: fileSizeBytes)
    }

    /// A suggested model alias name for the llama-server `-a` flag.
    var suggestedAlias: String {
        name.replacingOccurrences(of: #"[^a-zA-Z0-9_-]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Whether this model is likely too large for this machine.
    var isLargeModel: Bool {
        fileSizeBytes > 16_000_000_000 // 16 GB+
    }

    /// Whether this model has vision / multimodal capabilities (or matched mmproj).
    var isMultimodal: Bool {
        if let mm = mmprojPath, !mm.isEmpty { return true }
        let lower = (name + " " + architecture + " " + path).lowercased()
        return lower.contains("vl") || lower.contains("vision") || lower.contains("llava") || lower.contains("minicpmv") || lower.contains("minicpm-v") || lower.contains("ornith")
    }
}

/// Scans and discovers GGUF model files on disk, reading metadata directly from
/// each GGUF header (no external tool needed). llama-server itself reads the
/// model's embedded chat template and context length at load time, so the
/// metadata surfaced here is what powers "auto-fetch the correct chat settings".
enum GGUFModelScanner {

    /// Known directories to scan for GGUF model files.
    static let defaultSearchPaths: [String] = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // /Volumes is expanded to each mounted volume's Models folder (and the
        // volume root) rather than scanning every byte of every mounted drive —
        // a full recursive scan of a large external drive stalls the UI.
        return [
            "\(home)/Models",
            "\(home)/.local/share/llama.cpp/models",
            "\(home)/Downloads",
        ]
    }()

    /// Scan the default search paths and return all discovered GGUF models.
    /// Returns up to `maxResults` models, sorted by file size (largest first).
    /// The scan is bounded by a wall-clock budget so a slow drive can't stall
    /// the settings panel.
    static func scan(maxResults: Int = 50, timeBudget: TimeInterval = 5.0,
                 extraPaths: [String] = []) -> [GGUFModelFile] {
        var found: [GGUFModelFile] = []
        // Symlinks are resolved below, so a link and its target (or two links
        // to the same model) collapse onto one path — dedupe or the picker
        // shows the same model several times.
        var seen = Set<String>()
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeBudget)

        // User-added folders go first so they are never starved by a slow
        // default root consuming the scan budget.
        var paths = extraPaths + defaultSearchPaths
        // Add each mounted volume's Models directory (and volume root) so
        // external GGUF collections are found without scanning entire drives.
        if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumes where !volume.hasPrefix(".") {
                let volRoot = "/Volumes/\(volume)"
                paths.append(volRoot)
                paths.append("\(volRoot)/Models")
            }
        }

        // Projectors are matched from each model's own folder during discovery.
        // Widening to a full disk search happens only when a model is actually
        // selected: doing it per file consumed the whole budget and truncated
        // the list to the first model found.

        for basePath in paths {
            guard Date() < deadline else { break }
            guard fm.fileExists(atPath: basePath) else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let url as URL in enumerator {
                guard Date() < deadline else { break }
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                // Skip multi-file splits (e.g., model-00001-of-00002.gguf)
                let filename = url.lastPathComponent
                if filename.range(of: #"-0000\d-of-"#, options: .regularExpression) != nil { continue }
                if filename.range(of: #"mmproj"#, options: .caseInsensitive) != nil { continue }

                // Follow symlinks. A symlink to a model stats as the link's
                // own size (tens of bytes), so without resolving it every
                // symlinked collection is silently dropped by the size filter.
                let resolved = url.resolvingSymlinksInPath()
                guard let attrs = try? fm.attributesOfItem(atPath: resolved.path),
                      let fileSize = attrs[.size] as? Int64,
                      fileSize > 1_000_000 else { continue } // Skip < 1MB

                guard seen.insert(resolved.path).inserted else { continue }
                let model = readGGUFMetadata(path: resolved.path, fileSize: fileSize,
                                             widen: false)
                found.append(model)
                if found.count >= maxResults { break }
            }
            if found.count >= maxResults { break }
        }

        return found.sorted { $0.fileSizeBytes > $1.fileSizeBytes }
    }

    /// Scan and discover multimodal projector (mmproj) files on disk.
    /// - Parameter skipDownloads: drop `~/Downloads` from the roots. Listing a
    ///   large Downloads folder costs seconds on its own, which is not worth
    ///   paying when the caller only needs projectors sitting near the models.
    static func scanMmprojFiles(timeBudget: TimeInterval = 3.0,
                                skipDownloads: Bool = false,
                                extraPaths: [String] = []) -> [String] {
        var found: [String] = []
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeBudget)
        var paths = extraPaths + defaultSearchPaths
        if skipDownloads {
            let downloads = fm.homeDirectoryForCurrentUser.path + "/Downloads"
            paths = paths.filter { $0 != downloads }
        }
        if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumes where !volume.hasPrefix(".") {
                paths.append("/Volumes/\(volume)/Models")
            }
        }
        for basePath in paths {
            guard Date() < deadline else { break }
            guard fm.fileExists(atPath: basePath) else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: basePath),
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard Date() < deadline else { break }
                guard url.pathExtension.lowercased() == "gguf" else { continue }
                if url.lastPathComponent.range(of: #"mmproj"#, options: .caseInsensitive) != nil {
                    found.append(url.resolvingSymlinksInPath().path)
                }
            }
        }
        return Array(Set(found)).sorted()
    }

    /// Automatically find a matching mmproj (multimodal projector) for a model.
    ///
    /// A projector is only paired with a text model when llama.cpp would accept
    /// the pair. `mtmd_init_from_file` aborts the entire server when the
    /// projector's `clip.vision.projection_dim` differs from the text model's
    /// `<arch>.embedding_length` ("mismatch between text model (n_embd = ...) and
    /// mmproj"). Filename guessing alone used to pair DeepSeek-R1 (n_embd 4096)
    /// with a Qwen3.5 projector (projection_dim 2560) purely because both sat in
    /// ~/Models, which killed llama-server on every launch. Dimensions are now
    /// authoritative; filenames only rank candidates that already fit.
    static func findMatchingMmproj(forModelPath modelPath: String,
                                   knownMmproj: [String]? = nil,
                                   widen: Bool = true) -> String? {
        guard !modelPath.isEmpty else { return nil }
        let modelURL = URL(fileURLWithPath: modelPath)
        let modelMeta = GGUFParser.metadata(from: modelURL)
        let dir = modelURL.deletingLastPathComponent()
        let stem = modelURL.deletingPathExtension().lastPathComponent.lowercased()
        let tokens = nameTokens(stem)
        let wanted = normalizedName(modelMeta.name)

        var seen = Set<String>()
        var pool: [String] = []
        func add(_ paths: [String]) {
            for p in paths where seen.insert(p).inserted { pool.append(p) }
        }

        // 1. The model's own folder, then its parent (snapshot layouts).
        add(projectorFiles(in: dir))
        let parent = dir.deletingLastPathComponent()
        // Listing the home directory is expensive and never holds projectors.
        if parent.path != FileManager.default.homeDirectoryForCurrentUser.path {
            add(projectorFiles(in: parent))
        }
        if let hit = bestProjector(in: pool, forModelPath: modelPath,
                                   wanted: wanted, tokens: tokens) {
            return hit
        }

        // 2. Only widen to a full disk scan when the neighbourhood had nothing
        //    that fits — an unrelated projector is worse than none at all.
        guard widen else { return nil }
        add((knownMmproj ?? scanMmprojFiles(timeBudget: 1.5)).filter { isProjectorName($0) })
        return bestProjector(in: pool, forModelPath: modelPath,
                             wanted: wanted, tokens: tokens)
    }

    /// Whether llama.cpp will accept this projector with this text model.
    /// Both dimensions must be present and equal; a projector of unknown width
    /// is rejected because guessing is what broke the loader in the first place.
    static func projectorFits(modelPath: String, projectorPath: String) -> Bool {
        let text = GGUFParser.metadata(from: URL(fileURLWithPath: modelPath))
        let proj = GGUFParser.metadata(from: URL(fileURLWithPath: projectorPath))
        guard proj.isProjector || proj.projectionDim > 0 else { return false }
        guard text.embeddingLength > 0, proj.projectionDim > 0 else { return false }
        return text.embeddingLength == proj.projectionDim
    }

    private static func isProjectorName(_ path: String) -> Bool {
        isProjectorName(lastComponent: (path as NSString).lastPathComponent)
    }

    private static func isProjectorName(lastComponent name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".gguf") && lower.contains("mmproj")
    }

    /// All projector files directly inside `directory` (no recursion).
    private static func projectorFiles(in directory: URL) -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return [] }
        return contents
            .filter { isProjectorName(lastComponent: $0.lastPathComponent) }
            .map(\.path)
            .sorted()
    }

    private static func nameTokens(_ s: String) -> [String] {
        s.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
            .filter { $0.count >= 3 }
    }

    private static func normalizedName(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Rank already-validated projector candidates: an exact `general.name`
    /// match wins outright, otherwise shared filename tokens decide.
    ///
    /// Matching dimensions alone is not enough — a 4096-wide projector pair
    /// with a 4096-wide model loads but feeds the wrong vision tower — so a
    /// candidate with no name affinity at all is rejected outright.
    private static func bestProjector(in candidates: [String],
                                      forModelPath modelPath: String,
                                      wanted: String,
                                      tokens: [String]) -> String? {
        var best: (path: String, score: Int)?
        for candidate in candidates {
            guard projectorFits(modelPath: modelPath, projectorPath: candidate) else {
                print("[GGUFScan] Skipping incompatible projector \((candidate as NSString).lastPathComponent)")
                continue
            }
            let projMeta = GGUFParser.metadata(from: URL(fileURLWithPath: candidate))
            var score = 1
            if !wanted.isEmpty && wanted == normalizedName(projMeta.name) { score += 1000 }
            let candName = (candidate as NSString).lastPathComponent.lowercased()
            for token in tokens where candName.contains(token) { score += token.count }
            guard score > 1 else {
                print("[GGUFScan] Skipping unrelated projector \((candidate as NSString).lastPathComponent)")
                continue
            }
            if score > (best?.score ?? 0) { best = (candidate, score) }
        }
        return best?.path
    }

    /// Read GGUF metadata from a single model file by parsing the GGUF header
    /// natively. Falls back to filename-based parsing if the header can't be read.
    static func readGGUFMetadata(path: String, fileSize: Int64,
                                 knownMmproj: [String]? = nil,
                                 widen: Bool = true) -> GGUFModelFile {
        let filename = (path as NSString).lastPathComponent
        let filenameStem = (filename as NSString).deletingPathExtension

        // Defaults from the filename, refined by header metadata below.
        var name = filenameStem
        var architecture = extractArchitecture(from: filenameStem)
        var contextLength = 0
        let quantization = extractQuantization(from: filenameStem)
        var chatTemplate = ""

        let meta = GGUFParser.metadata(from: URL(fileURLWithPath: path))
        if !meta.name.isEmpty { name = meta.name }
        if !meta.architecture.isEmpty { architecture = meta.architecture }
        if meta.contextLength > 0 { contextLength = meta.contextLength }
        if !meta.chatTemplate.isEmpty { chatTemplate = meta.chatTemplate }

        // If the header didn't give us a context length, use a sane default
        // that matches common local models.
        if contextLength == 0 {
            contextLength = architectureContainsQwen(architecture) ? 32768 : 8192
        }

        let mmproj = findMatchingMmproj(forModelPath: path,
                                        knownMmproj: knownMmproj,
                                        widen: widen)

        return GGUFModelFile(
            id: path,
            name: name,
            path: path,
            fileSizeBytes: fileSize,
            architecture: architecture,
            contextLength: contextLength,
            quantization: quantization,
            chatTemplate: chatTemplate,
            mmprojPath: mmproj
        )
    }

    private static func architectureContainsQwen(_ arch: String) -> Bool {
        arch.lowercased().contains("qwen")
    }

    /// Extract architecture from a known model filename pattern.
    private static func extractArchitecture(from filename: String) -> String {
        let lower = filename.lowercased()
        if lower.contains("qwen") { return "qwen" }
        if lower.contains("llama") || lower.contains("ornith") || lower.contains("qwythos") { return "llama" }
        if lower.contains("mistral") { return "mistral" }
        if lower.contains("deepseek") { return "deepseek" }
        if lower.contains("phi") { return "phi" }
        if lower.contains("gemma") { return "gemma" }
        if lower.contains("minicpm") || lower.contains("minimax") { return "minicpm" }
        if lower.contains("ternary") { return "llama" }
        return "llama"
    }

    /// Extract quantization from a GGUF filename (e.g. Q8_0, Q4_K_M, BF16).
    private static func extractQuantization(from filename: String) -> String {
        let patterns = [
            // Prism-fork and upstream ternary formats come FIRST, because their
            // names contain the upstream substrings they would otherwise be
            // misread as: "PQ2_0" contains "Q2_0", "PTQ1_0" contains "Q1_0",
            // "TQ2_0" contains "Q2_0". Those are different formats (group 128
            // vs 64), and the label is not cosmetic -- it feeds
            // LocalModelManager's preset matching, so a ternary file would be
            // matched against a plain Q2_0 preset.
            "PQ2_0", "PTQ1_0", "TQ1_0", "TQ2_0",
            "Q8_0", "Q6_K", "Q5_K_M", "Q5_K_S", "Q5_0", "Q5_1",
            "Q4_K_M", "Q4_K_S", "Q4_0", "Q4_1",
            "Q3_K_L", "Q3_K_M", "Q3_K_S", "Q3_0",
            "Q2_K", "Q2_0", "Q1_0",
            "BF16", "F16", "F32",
            "IQ4_NL", "IQ4_XS", "IQ3_S", "IQ3_XXS",
            "IQ2_S", "IQ2_XXS", "IQ2_XS", "IQ1_S",
            "IQ1_M",
        ]
        for pattern in patterns {
            if filename.uppercased().contains(pattern) {
                return pattern
            }
        }
        // Try to find any Q#_# pattern
        if let range = filename.range(of: #"[Qq][0-9]_[A-Za-z0-9]+"#, options: .regularExpression) {
            return String(filename[range]).uppercased()
        }
        return ""
    }
}

// MARK: - Native GGUF Header Parser

/// Parses the key-value metadata store at the top of a GGUF file directly from
/// disk. This is what lets JXRouter read a model's architecture, native context
/// length, and chat template without requiring any external tool — and it is
/// the same metadata llama-server consumes to apply the correct chat template.
enum GGUFParser {

    struct Metadata {
        var name = ""
        var architecture = ""
        var contextLength = 0
        var chatTemplate = ""

        // -- Fields the loader's safety checks depend on -------------------
        /// `<arch>.embedding_length` — the text model's hidden width (n_embd).
        var embeddingLength = 0
        /// `clip.vision.projection_dim` — a projector's output width. llama.cpp
        /// requires this to equal the text model's `embeddingLength`.
        var projectionDim = 0
        /// True when the file carries a vision encoder (i.e. it is an mmproj).
        var hasVisionEncoder = false
        /// True when `general.architecture == "clip"` — a projector, not a LM.
        var isProjector = false
        /// `<arch>.block_count` — transformer depth.
        var blockCount = 0
        /// `<arch>.expert_count` — non-zero for mixture-of-experts models.
        var expertCount = 0
        /// `<arch>.attention.head_count` — used to derive the head dimension.
        var attentionHeadCount = 0
        /// `<arch>.attention.head_count_kv` — grouped-query attention width.
        var attentionHeadCountKV = 0
        /// `<arch>.full_attention_interval` — hybrid models (GatedDeltaNet/Mamba
        /// plus attention) run full attention only every Nth layer; the rest are
        /// recurrent and hold no KV cache. 0 means "not reported" (dense model).
        var fullAttentionInterval = 0
        /// `<arch>.nextn_predict_layers` — non-zero when the file carries its own
        /// MTP (multi-token prediction) draft head, which llama-server can use
        /// for self-speculative decoding with no second model in memory.
        var nextnPredictLayers = 0

        /// Layers that actually hold a KV cache.
        ///
        /// Equal to `blockCount` for a dense model. For a hybrid it is every
        /// `fullAttentionInterval`-th layer, so a 65-block model with interval 4
        /// caches just 17 layers — sizing KV off `blockCount` instead would
        /// understate the usable context by roughly 4x.
        var attentionLayerCount: Int {
            guard blockCount > 0 else { return 0 }
            if fullAttentionInterval > 1 {
                return (blockCount + fullAttentionInterval - 1) / fullAttentionInterval
            }
            return blockCount
        }

        /// True for a hybrid recurrent/attention stack.
        var isHybrid: Bool { fullAttentionInterval > 1 }
    }

    /// GGUF value types (see GGUF spec).
    private enum ValueType: UInt32 {
        case uint8 = 0, int8 = 1, uint16 = 2, int16 = 3
        case uint32 = 4, int32 = 5, float32 = 6, bool = 7
        case string = 8, array = 9, uint64 = 10, int64 = 11, float64 = 12

        /// Byte width of one element, for arrays that can be skipped in a
        /// single stride rather than element by element.
        var fixedSize: Int {
            switch self {
            case .uint8, .int8, .bool: return 1
            case .uint16, .int16: return 2
            case .uint32, .int32, .float32: return 4
            case .uint64, .int64, .float64: return 8
            case .string, .array: return 0
            }
        }
    }

    /// Read and parse a GGUF header.
    ///
    /// The header is parsed from one buffered read. The previous implementation
    /// issued a separate `read()` syscall for every scalar value, which cost
    /// ~1.5s per model — enough to blow the 5s scan budget on the very first
    /// file and truncate the model list to a single entry.
    static func metadata(from url: URL) -> Metadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Metadata() }
        defer { try? handle.close() }

        var buffer = [UInt8]()
        buffer.append(contentsOf: handle.readData(ofLength: 1 << 20)) // 1 MB
        while !buffer.isEmpty {
            var cursor = Cursor(bytes: buffer)
            if let meta = parseHeader(&cursor) { return meta }
            // Only grow when the parse stopped because the buffer ran out; a
            // malformed (but fully buffered) header will never parse better.
            guard cursor.ranOutOfBytes else { return Metadata() }
            // Grow geometrically: a vocabulary array alone can run to several MB.
            let more = handle.readData(ofLength: max(buffer.count, 1 << 20))
            if more.isEmpty { break }
            buffer.append(contentsOf: more)
            if buffer.count >= (32 << 20) { break } // 32 MB sanity cap
        }
        return Metadata()
    }

    /// A cursor over an in-memory slice of the file.
    ///
    /// GGUF values are little-endian and frequently unaligned, so values are
    /// loaded with `loadUnaligned` rather than by rebinding memory.
    private struct Cursor {
        let bytes: [UInt8]
        var offset = 0
        /// True when a read failed because the buffer ended (rather than the
        /// file being malformed), so the caller knows to buffer more.
        var ranOutOfBytes = false

        var remaining: Int { bytes.count - offset }

        mutating func read<T>(_: T.Type = T.self) -> T? {
            let size = MemoryLayout<T>.size
            guard size > 0, remaining >= size else {
                ranOutOfBytes = true
                return nil
            }
            let chunk = [UInt8](bytes[offset ..< (offset + size)])
            let value = chunk.withUnsafeBytes { raw in
                raw.loadUnaligned(fromByteOffset: 0, as: T.self)
            }
            offset += size
            return value
        }

        /// Read a GGUF string: uint64 byte length followed by UTF-8 bytes.
        mutating func readString() -> String? {
            guard let length: UInt64 = read() else { return nil }
            guard length < 10_000_000 else { return nil } // sanity: templates can be long
            let n = Int(length)
            guard n <= remaining else {
                ranOutOfBytes = true
                return nil
            }
            let value = String(decoding: bytes[offset ..< (offset + n)], as: UTF8.self)
            offset += n
            return value
        }

        /// Read a fixed-length ASCII header string (e.g. the 4-byte magic).
        mutating func readFixedString(_ length: Int) -> String? {
            guard length <= remaining else {
                ranOutOfBytes = true
                return nil
            }
            let value = String(decoding: bytes[offset ..< (offset + length)], as: UTF8.self)
            offset += length
            return value
        }

        /// Skip `count` array elements of the given element type. The count is
        /// passed in (read by the caller) so the stream stays in sync.
        mutating func skipArrayElements(elemType: ValueType?, count: UInt64) -> Bool {
            guard let elemType else { return false }
            switch elemType {
            case .string:
                // Vocabularies run to hundreds of thousands of entries; only
                // advance the cursor, never build the strings.
                for _ in 0..<count {
                    guard let length: UInt64 = read() else { return false }
                    guard length < 10_000_000 else { return false }
                    guard Int(length) <= remaining else {
                        ranOutOfBytes = true
                        return false
                    }
                    offset += Int(length)
                }
            case .array:
                // nested array: element type + count + elements. Same
                // single-count-read discipline as the outer array.
                for _ in 0..<count {
                    guard let nestedType: UInt32 = read(),
                          let nestedCount: UInt64 = read(),
                          skipArrayElements(elemType: ValueType(rawValue: nestedType),
                                            count: nestedCount) else { return false }
                }
            default:
                let width = elemType.fixedSize
                guard count <= UInt64(remaining) else {
                    ranOutOfBytes = true
                    return false
                }
                let total = Int(count) * width
                guard total >= 0, total <= remaining else {
                    ranOutOfBytes = true
                    return false
                }
                offset += total
            }
            return true
        }
    }

    private static func parseHeader(_ c: inout Cursor) -> Metadata? {
        guard let magic = c.readFixedString(4) else { return nil }
        guard magic == "GGUF" else { return Metadata() }  // not a GGUF file
        guard let _: UInt32 = c.read() else { return nil }      // version
        guard let _: UInt64 = c.read() else { return nil }      // tensor_count
        guard let kvCount: UInt64 = c.read() else { return nil } // metadata_kv_count

        var meta = Metadata()
        // `parse:` lets a failed read stop the walk while still falling through
        // to the out-of-bytes check below, which asks for a bigger buffer
        // instead of silently returning half-parsed metadata.
        parse: for _ in 0..<kvCount {
            guard let key = c.readString() else { break parse }
            guard let rawType: UInt32 = c.read(),
                  let type = ValueType(rawValue: rawType) else { break parse }

            switch type {
            case .string:
                if let value = c.readString() { store(key, value, &meta) }
            case .uint32:
                if let value: UInt32 = c.read() { store(key, String(value), &meta) }
            case .uint64:
                if let value: UInt64 = c.read() { store(key, String(value), &meta) }
            case .int32:
                if let value: Int32 = c.read() { store(key, String(value), &meta) }
            case .int64:
                if let value: Int64 = c.read() { store(key, String(value), &meta) }
            case .float32:
                guard let _: Float = c.read() else { break parse }
            case .float64:
                guard let _: Double = c.read() else { break parse }
            case .uint8:
                guard let _: UInt8 = c.read() else { break parse }
            case .int8:
                guard let _: Int8 = c.read() else { break parse }
            case .uint16:
                guard let _: UInt16 = c.read() else { break parse }
            case .int16:
                guard let _: Int16 = c.read() else { break parse }
            case .bool:
                // Bool metadata (e.g. clip.has_vision_encoder) is meaningful —
                // older code discarded it, so projectors were indistinguishable
                // from ordinary models.
                guard let value: Bool = c.read() else { break parse }
                store(key, value ? "true" : "false", &meta)
            case .array:
                // element type + count + count elements (skip). The count is
                // read ONCE here — skipArrayElements takes it explicitly so the
                // stream isn't desynced by a second count read.
                guard let elemType: UInt32 = c.read(),
                      let count: UInt64 = c.read() else { break parse }
                guard c.skipArrayElements(elemType: ValueType(rawValue: elemType),
                                          count: count) else { break parse }
            }
        }
        // Ran out of buffer mid-header: tell the caller to grow and retry.
        // Returning the partial metadata here is what silently dropped the chat
        // template — a multi-MB `tokenizer.ggml.tokens` array precedes it.
        if c.ranOutOfBytes { return nil }
        return meta
    }

    /// Store a parsed metadata value by key.
    private static func store(_ key: String, _ value: String, _ meta: inout Metadata) {
        switch key {
        case "general.name":
            if meta.name.isEmpty { meta.name = value }
        case "general.architecture":
            if meta.architecture.isEmpty {
                meta.architecture = value
                meta.isProjector = (value.lowercased() == "clip")
            }
        case "tokenizer.chat_template":
            if meta.chatTemplate.isEmpty { meta.chatTemplate = value }
        case "clip.has_vision_encoder":
            meta.hasVisionEncoder = (value == "true" || value == "1")
        case "clip.vision.projection_dim":
            meta.projectionDim = Int(value) ?? meta.projectionDim
        default:
            // Vision-side keys carry a `.vision.` segment; the text model's own
            // width must not be read from them.
            let isVisionKey = key.contains(".vision.")
            if key.hasSuffix(".embedding_length"), !isVisionKey {
                if meta.embeddingLength == 0 { meta.embeddingLength = Int(value) ?? 0 }
            } else if key.hasSuffix(".block_count"), !isVisionKey {
                if meta.blockCount == 0 { meta.blockCount = Int(value) ?? 0 }
            } else if key.hasSuffix(".expert_count"), !isVisionKey {
                if meta.expertCount == 0 { meta.expertCount = Int(value) ?? 0 }
            } else if key.hasSuffix(".attention.head_count_kv"), !isVisionKey {
                if meta.attentionHeadCountKV == 0 { meta.attentionHeadCountKV = Int(value) ?? 0 }
            } else if key.hasSuffix(".attention.head_count"), !isVisionKey {
                if meta.attentionHeadCount == 0 { meta.attentionHeadCount = Int(value) ?? 0 }
            } else if key.hasSuffix(".full_attention_interval"), !isVisionKey {
                if meta.fullAttentionInterval == 0 { meta.fullAttentionInterval = Int(value) ?? 0 }
            } else if key.hasSuffix(".nextn_predict_layers"), !isVisionKey {
                if meta.nextnPredictLayers == 0 { meta.nextnPredictLayers = Int(value) ?? 0 }
            } else if meta.contextLength == 0, key.hasSuffix(".context_length"), !isVisionKey {
                meta.contextLength = Int(value) ?? 0
            }
        }
    }
}
