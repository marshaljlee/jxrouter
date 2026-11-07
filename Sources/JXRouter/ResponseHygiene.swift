import Foundation

/// Port of JXServer's response_hygiene: cleans prompt control tokens and special markers
/// from text, preventing leaked Jinja and model formatting tokens from entering transcripts.
enum ResponseHygiene {

    /// Tokens that belong to prompt templates or stop sequences, not model response prose.
    static let hiddenTokens: [String] = [
        "<|im_start|>",
        "<|im_end|>",
        "<|eot_id|>",
        "<|start_header_id|>",
        "<|end_header_id|>",
        "<|endoftext|>",
        "<|begin_of_text|>",
        "<|end_of_text|>",
        "<|file_separator|>",
        "<|assistant|>",
        "<|user|>",
        "<|system|>",
        "<|observation|>",
        "<|eom_id|>",
        "<|python_tag|>",
        "<|start|>",
        "<|end|>",
        "<|message|>",
        "<|constrain|>",
        "<|channel|>",
        "<channel|>",
        "<|tool_response|>",
        "<|/tool_response|>",
        "<|fim_prefix|>",
        "<|fim_middle|>",
        "<|fim_suffix|>",
        "<|end▁of▁sentence|>",
        "<<SYS>>",
        "<</SYS>>",
        "[INST]",
        "[/INST]",
        "<start_of_turn>",
        "<end_of_turn>",
        "<|reserved_special_token_0|>",
    ]

    /// Regex matching leading role tags surviving stripped tokens (e.g. "system\n", "assistant\n")
    private static let startRoleRegex = try? NSRegularExpression(pattern: #"^\s*(?:assistant|system|user)[ \t]*\n"#, options: [.caseInsensitive])

    /// Strip known control tokens from text.
    static func stripControlTokens(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var result = text
        for token in hiddenTokens {
            if result.contains(token) {
                result = result.replacingOccurrences(of: token, with: "")
            }
        }
        if let regex = startRoleRegex {
            let nsStr = result as NSString
            let match = regex.firstMatch(in: result, options: [], range: NSRange(location: 0, length: nsStr.length))
            if let m = match {
                result = nsStr.replacingCharacters(in: m.range, with: "")
            }
        }
        return result
    }
}
