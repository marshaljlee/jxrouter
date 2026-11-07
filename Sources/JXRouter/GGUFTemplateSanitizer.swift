import Foundation

/// In-place byte-preserving sanitizer for GGUF chat templates.
/// Neutralizes fatal `raise_exception` statements in Jinja templates (such as
/// 'System message must be at the beginning', 'No user query found', etc.)
/// without altering file length or tensor offsets.
enum GGUFTemplateSanitizer {

    private static let rawReplacements: [(String, String)] = [
        ("{{- raise_exception('System message cannot contain images.') }}",
         "{# safe no-op: ignore image in system #}"),
        ("{{- raise_exception('System message cannot contain videos.') }}",
         "{# safe no-op: ignore video in system #}"),
        ("{{- raise_exception('Unexpected item type in content.') }}",
         "{{- item | string -}}"),
        ("{{- raise_exception('Unexpected content type.') }}",
         "{{- content | string -}}"),
        ("{{- raise_exception('No messages provided.') }}",
         "{# safe no-op: allow empty messages #}"),
        ("{{- raise_exception('No user query found in messages.') }}",
         "{# safe no-op: allow tool results without user query #}"),
        ("{{- raise_exception('System message must be at the beginning.') }}",
         "{{- '<|im_start|>system\\n' + content + '<|im_end|>\\n' -}}"),
        ("{{- raise_exception('Unexpected message role.') }}",
         "{{- '<|im_start|>' ~ message.role ~ '\\n' -}}"),
        ("{%- if tool_call.arguments is defined and tool_call.arguments != '' %}",
         "{%- if tool_call.arguments is mapping and tool_call.arguments != '' %}"),
    ]

    /// Pads replacement `s` to exact `targetLen` characters using a Jinja comment.
    private static func padTo(_ s: String, targetLen: Int) -> String? {
        let diff = targetLen - s.utf8.count
        if diff < 0 { return nil }
        if diff == 0 { return s }
        if diff < 6 { return s + String(repeating: " ", count: diff) }
        return s + "{#" + String(repeating: " ", count: diff - 4) + "#}"
    }

    /// Neutralize known and generic `raise_exception` calls in a Jinja template string,
    /// guaranteeing byte length is strictly preserved.
    static func sanitizeTemplateString(_ template: String) -> (changed: Bool, sanitized: String) {
        guard template.contains("raise_exception") else {
            return (false, template)
        }

        var modified = template
        var changed = false

        for (old, repl) in rawReplacements {
            if let range = modified.range(of: old) {
                let targetByteLen = old.utf8.count
                if let padded = padTo(repl, targetLen: targetByteLen) {
                    modified.replaceSubrange(range, with: padded)
                    changed = true
                }
            }
        }

        // Generic fallback regex for any remaining raise_exception calls
        let pattern = #"\{\{[-]?\s*raise_exception\([^)]+\)\s*[-]?\}\}"#
        if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
            let nsStr = modified as NSString
            let matches = regex.matches(in: modified, options: [], range: NSRange(location: 0, length: nsStr.length))
            // Replace backwards to preserve indices
            for match in matches.reversed() {
                guard let range = Range(match.range, in: modified) else { continue }
                let matchedStr = String(modified[range])
                let targetLen = matchedStr.utf8.count
                let neutralComment = "{# neutralized raise_exception #}"
                if let padded = padTo(neutralComment, targetLen: targetLen) {
                    modified.replaceSubrange(range, with: padded)
                    changed = true
                }
            }
        }

        return (changed, modified)
    }

    /// Inspect and sanitize the `tokenizer.chat_template` in a GGUF file in-place if fragile Jinja exceptions exist.
    @discardableResult
    static func sanitizeGGUFFile(atPath path: String) -> (success: Bool, message: String) {
        guard FileManager.default.isWritableFile(atPath: path) else {
            return (false, "File not writable: \(path)")
        }

        guard let handle = try? FileHandle(forUpdating: URL(fileURLWithPath: path)) else {
            return (false, "Failed to open file for update: \(path)")
        }
        defer { try? handle.close() }

        // Read up to first 96 MB for metadata search
        let scanLimit = 96 * 1024 * 1024
        guard let headerData = try? handle.read(upToCount: scanLimit) else {
            return (false, "Failed to read GGUF header")
        }

        let keyTarget = "tokenizer.chat_template".data(using: .utf8)!
        guard let keyRange = headerData.range(of: keyTarget) else {
            return (false, "No tokenizer.chat_template metadata key found")
        }

        let keyEnd = keyRange.upperBound
        guard keyEnd + 12 <= headerData.count else {
            return (false, "Header truncated after key")
        }

        // 4 bytes: value_type (must be string = 8)
        let vtype = headerData.subdata(in: keyEnd..<keyEnd + 4).withUnsafeBytes { $0.load(as: UInt32.self) }
        guard vtype == 8 else {
            return (false, "tokenizer.chat_template is not string type (vtype=\(vtype))")
        }

        // 8 bytes: string length uint64
        let vlen = headerData.subdata(in: keyEnd + 4..<keyEnd + 12).withUnsafeBytes { $0.load(as: UInt64.self) }
        let valStart = keyEnd + 12
        let valEnd = valStart + Int(vlen)

        guard valEnd <= headerData.count else {
            return (false, "Chat template value extends beyond scan buffer")
        }

        let templateBytes = headerData.subdata(in: valStart..<valEnd)
        guard let templateStr = String(data: templateBytes, encoding: .utf8) else {
            return (false, "Failed to decode template as utf-8")
        }

        let (changed, sanitized) = sanitizeTemplateString(templateStr)
        guard changed else {
            return (true, "Template already clean (no raise_exception calls)")
        }

        guard let sanitizedData = sanitized.data(using: .utf8), sanitizedData.count == Int(vlen) else {
            return (false, "Sanitized data length mismatch")
        }

        do {
            try handle.seek(toOffset: UInt64(valStart))
            try handle.write(contentsOf: sanitizedData)
            return (true, "Sanitized template (\(vlen) bytes) in-place successfully")
        } catch {
            return (false, "Failed to write sanitized template: \(error.localizedDescription)")
        }
    }
}

