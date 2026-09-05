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
    static func scan(maxResults: Int = 50, timeBudget: TimeInterval = 5.0) -> [GGUFModelFile] {
        var found: [GGUFModelFile] = []
        let fm = FileManager.default
        let deadline = Date().addingTimeInterval(timeBudget)

        var paths = defaultSearchPaths
        // Add each mounted volume's Models directory (and volume root) so
        // external GGUF collections are found without scanning entire drives.
        if let volumes = try? fm.contentsOfDirectory(atPath: "/Volumes") {
            for volume in volumes where !volume.hasPrefix(".") {
                let volRoot = "/Volumes/\(volume)"
                paths.append(volRoot)
                paths.append("\(volRoot)/Models")
            }
        }

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

                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let fileSize = attrs[.size] as? Int64,
                      fileSize > 1_000_000 else { continue } // Skip < 1MB

                let model = readGGUFMetadata(path: url.path, fileSize: fileSize)
                found.append(model)
                if found.count >= maxResults { break }
            }
            if found.count >= maxResults { break }
        }

        return found.sorted { $0.fileSizeBytes > $1.fileSizeBytes }
    }

    /// Read GGUF metadata from a single model file by parsing the GGUF header
    /// natively. Falls back to filename-based parsing if the header can't be read.
    static func readGGUFMetadata(path: String, fileSize: Int64) -> GGUFModelFile {
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

        return GGUFModelFile(
            id: path,
            name: name,
            path: path,
            fileSizeBytes: fileSize,
            architecture: architecture,
            contextLength: contextLength,
            quantization: quantization,
            chatTemplate: chatTemplate
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
    }

    /// GGUF value types (see GGUF spec).
    private enum ValueType: UInt32 {
        case uint8 = 0, int8 = 1, uint16 = 2, int16 = 3
        case uint32 = 4, int32 = 5, float32 = 6, bool = 7
        case string = 8, array = 9, uint64 = 10, int64 = 11, float64 = 12
    }

    static func metadata(from url: URL) -> Metadata {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Metadata() }
        defer { try? handle.close() }

        // magic "GGUF"
        guard let magic = readFixedString(handle, 4), magic == "GGUF" else { return Metadata() }
        // version (uint32), tensor_count (uint64)
        guard let _: UInt32 = read(handle) else { return Metadata() }
        guard let _: UInt64 = read(handle) else { return Metadata() }
        // metadata_kv_count (uint64)
        guard let kvCount: UInt64 = read(handle) else { return Metadata() }

        var meta = Metadata()
        for _ in 0..<kvCount {
            guard let key = readString(handle) else { break }
            guard let rawType: UInt32 = read(handle),
                  let type = ValueType(rawValue: rawType) else { break }

            switch type {
            case .string:
                if let value = readString(handle) {
                    store(key, value, &meta)
                }
            case .uint32:
                if let value: UInt32 = read(handle) { store(key, String(value), &meta) }
            case .uint64:
                if let value: UInt64 = read(handle) { store(key, String(value), &meta) }
            case .int32:
                if let value: Int32 = read(handle) { store(key, String(value), &meta) }
            case .int64:
                if let value: Int64 = read(handle) { store(key, String(value), &meta) }
            case .float32:
                guard let _: Float = read(handle) else { break }
            case .float64:
                guard let _: Double = read(handle) else { break }
            case .uint8:
                guard let _: UInt8 = read(handle) else { break }
            case .int8:
                guard let _: Int8 = read(handle) else { break }
            case .uint16:
                guard let _: UInt16 = read(handle) else { break }
            case .int16:
                guard let _: Int16 = read(handle) else { break }
            case .bool:
                guard let _: Bool = read(handle) else { break }
            case .array:
                // element type + count + count elements (skip). The count is
                // read ONCE here — skipArrayElements takes it explicitly so the
                // stream isn't desynced by a second count read.
                guard let elemType: UInt32 = read(handle),
                      let count: UInt64 = read(handle),
                      skipArrayElements(handle, elemType: ValueType(rawValue: elemType), count: count) else { break }
            }
        }
        return meta
    }

    /// Store a parsed metadata value by key.
    private static func store(_ key: String, _ value: String, _ meta: inout Metadata) {
        switch key {
        case "general.name":
            if meta.name.isEmpty { meta.name = value }
        case "general.architecture":
            if meta.architecture.isEmpty { meta.architecture = value }
        case "tokenizer.chat_template":
            if meta.chatTemplate.isEmpty { meta.chatTemplate = value }
        default:
            if meta.contextLength == 0, key.hasSuffix(".context_length") {
                meta.contextLength = Int(value) ?? 0
            }
        }
    }

    /// Skip `count` array elements of the given element type, returning whether
    /// the entire array was successfully skipped. The count is passed in (read
    /// by the caller) so the stream stays in sync.
    private static func skipArrayElements(_ handle: FileHandle, elemType: ValueType?, count: UInt64) -> Bool {
        guard let elemType else { return false }
        for _ in 0..<count {
            switch elemType {
            case .uint8, .int8:
                guard let _: UInt8 = read(handle) else { return false }
            case .uint16, .int16:
                guard let _: UInt16 = read(handle) else { return false }
            case .uint32, .int32, .float32:
                guard let _: UInt32 = read(handle) else { return false }
            case .uint64, .int64, .float64:
                guard let _: UInt64 = read(handle) else { return false }
            case .bool:
                guard let _: Bool = read(handle) else { return false }
            case .string:
                guard let _ = readString(handle) else { return false }
            case .array:
                // nested array: element type + count + elements. Same
                // single-count-read discipline as the outer array.
                guard let nestedType: UInt32 = read(handle),
                      let nestedCount: UInt64 = read(handle),
                      skipArrayElements(handle, elemType: ValueType(rawValue: nestedType), count: nestedCount) else { return false }
            }
        }
        return true
    }

    /// Read a GGUF string: uint64 byte length followed by UTF-8 bytes.
    private static func readString(_ handle: FileHandle) -> String? {
        guard let length: UInt64 = read(handle) else { return nil }
        guard length < 10_000_000 else { return nil } // sanity: templates can be long
        let data = handle.readData(ofLength: Int(length))
        guard data.count == Int(length) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Read a fixed-length ASCII header string (e.g. the 4-byte magic).
    private static func readFixedString(_ handle: FileHandle, _ length: Int) -> String? {
        let data = handle.readData(ofLength: length)
        guard data.count == length else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Read a fixed-size little-endian value from the file.
    private static func read<T>(_ handle: FileHandle) -> T? {
        let size = MemoryLayout<T>.size
        let data = handle.readData(ofLength: size)
        guard data.count == size else { return nil }
        return data.withUnsafeBytes { raw -> T? in
            guard let base = raw.baseAddress else { return nil }
            return base.loadUnaligned(as: T.self)
        }
    }
}
