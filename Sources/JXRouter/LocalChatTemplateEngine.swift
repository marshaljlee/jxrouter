import Foundation

/// Automatic Chat Template and Jinja Setup Engine for Local LLM Models
/// (llama-server, Ollama, LM Studio, llama.app, Jan, etc.).
///
/// Prevents user setup errors (missing chat template, disabled tool support,
/// or template mismatch in local inference apps) from breaking JXRouter.
enum LocalChatTemplateEngine {

    // MARK: - Supported Chat Template Families

    enum ChatTemplateFamily: String, CaseIterable {
        case chatml    = "chatml"
        case llama3    = "llama3"
        case llama2    = "llama2"
        case deepseek3 = "deepseek3"
        case deepseek  = "deepseek"
        case mistral   = "mistral-v3"
        case gemma     = "gemma"
        case phi4      = "phi4"
        case phi3      = "phi3"
        case commandR  = "command-r"
        case standard  = "standard"

        /// Recognized name for `llama-server --chat-template <name>`.
        var llamaServerName: String {
            switch self {
            case .chatml: return "chatml"
            case .llama3: return "llama3"
            case .llama2: return "llama2"
            case .deepseek3: return "deepseek3"
            case .deepseek: return "deepseek"
            case .mistral: return "mistral-v3"
            case .gemma: return "gemma"
            case .phi4: return "phi4"
            case .phi3: return "phi3"
            case .commandR: return "command-r"
            case .standard: return "chatml"
            }
        }

        /// Complete embedded Jinja2 chat template with full agentic function calling / tools support
        /// directly mirroring Section 7.1 of the llama.cpp / llama-server definitive reference.
        /// Can be written to a file for `llama-server --chat-template-file <path>`.
        var jinjaSource: String {
            switch self {
            case .chatml, .standard:
                // Production-Ready Agentic Jinja2 Template (Qwen / ChatML Standard)
                // From Section 7.1 of llama-server Definitive Reference
                return """
                {%- if tools %}
                    {{- '<|im_start|>system\\n' }}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- messages[0]['content'] }}
                    {%- else %}
                        {{- 'You are a helpful assistant with tool-calling capabilities.' }}
                    {%- endif %}
                    {{- '\\n\\n# Tools\\n\\nYou have access to the following functions:\\n\\n' }}
                    {%- for tool in tools %}
                        {{- 'Use the function `' ~ tool.function.name ~ '` to: ' ~ tool.function.description ~ '\\n' }}
                        {{- 'JSON Schema:\\n' }}
                        {{- tool.function | tojson }}
                        {{- '\\n\\n' }}
                    {%- endfor %}
                    {{- 'To call a function, respond with a JSON object inside <tool_call></tool_call> tags:\\n' }}
                    {{- '<tool_call>\\n{"name": "function_name", "arguments": {"arg_1": "val_1"}}\\n</tool_call>\\n' }}
                    {{- '<|im_end|>\\n' }}
                {%- else %}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- '<|im_start|>system\\n' ~ messages[0]['content'] ~ '<|im_end|>\\n' }}
                    {%- endif %}
                {%- endif %}

                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '<|im_start|>user\\n' ~ message.content ~ '<|im_end|>\\n' }}
                    {%- elif message.role == 'assistant' %}
                        {{- '<|im_start|>assistant\\n' }}
                        {%- if message.content %}
                            {{- message.content }}
                        {%- endif %}
                        {%- if message.tool_calls %}
                            {%- for tool_call in message.tool_calls %}
                                {{- '<tool_call>\\n{"name": "' ~ tool_call.function.name ~ '", "arguments": ' ~ tool_call.function.arguments | tojson ~ '}\\n</tool_call>\\n' }}
                            {%- endfor %}
                        {%- endif %}
                        {{- '<|im_end|>\\n' }}
                    {%- elif message.role == 'tool' %}
                        {{- '<|im_start|>user\\n<tool_response>\\n' ~ message.content ~ '\\n</tool_response><|im_end|>\\n' }}
                    {%- endif %}
                {%- endfor %}

                {%- if add_generation_prompt %}
                    {{- '<|im_start|>assistant\\n' }}
                {%- endif %}
                """
            case .llama3:
                // Production-Ready Agentic Jinja2 Template (Llama 3.1 / 3.2 / 3.3 Standard)
                // From Section 7.1 of llama-server Definitive Reference
                return """
                {{- '<|begin_of_text|>' }}
                {%- if tools %}
                    {{- '<|start_header_id|>system<|end_header_id|>\\n\\n' }}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- messages[0]['content'] }}
                    {%- else %}
                        {{- 'You are a helpful assistant with tool-calling capabilities.' }}
                    {%- endif %}
                    {{- '\\n\\nEnvironment: ipython\\n\\nTools:\\n' }}
                    {%- for tool in tools %}
                        {{- tool.function | tojson ~ '\\n' }}
                    {%- endfor %}
                    {{- '\\nTo call a tool, output the function call JSON.\\n' }}
                    {{- '<|eot_id|>' }}
                {%- else %}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- '<|start_header_id|>system<|end_header_id|>\\n\\n' ~ messages[0]['content'] ~ '<|eot_id|>' }}
                    {%- endif %}
                {%- endif %}

                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '<|start_header_id|>user<|end_header_id|>\\n\\n' ~ message.content ~ '<|eot_id|>' }}
                    {%- elif message.role == 'assistant' %}
                        {{- '<|start_header_id|>assistant<|end_header_id|>\\n\\n' }}
                        {%- if message.content %}
                            {{- message.content }}
                        {%- endif %}
                        {%- if message.tool_calls %}
                            {%- for tool_call in message.tool_calls %}
                                {{- '{"name": "' ~ tool_call.function.name ~ '", "parameters": ' ~ tool_call.function.arguments | tojson ~ '}' }}
                            {%- endfor %}
                        {%- endif %}
                        {{- '<|eot_id|>' }}
                    {%- elif message.role == 'tool' %}
                        {{- '<|start_header_id|>ipython<|end_header_id|>\\n\\n' ~ message.content ~ '<|eot_id|>' }}
                    {%- endif %}
                {%- endfor %}

                {%- if add_generation_prompt %}
                    {{- '<|start_header_id|>assistant<|end_header_id|>\\n\\n' }}
                {%- endif %}
                """
            case .deepseek3, .deepseek:
                return """
                {%- if tools %}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- messages[0]['content'] + '\\n\\n' }}
                    {%- endif %}
                    {{- '# Tools\\n\\nYou have access to the following tools:\\n\\n' }}
                    {%- for tool in tools %}
                        {{- '```json\\n' ~ tool.function | tojson ~ '\\n```\\n\\n' }}
                    {%- endfor %}
                    {{- 'To call a function, respond with: <tool_call>\\n{"name": "function_name", "arguments": {}}\\n</tool_call>\\n\\n' }}
                {%- else %}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- messages[0]['content'] + '\\n\\n' }}
                    {%- endif %}
                {%- endif %}
                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '<｜User｜>' + message.content }}
                    {%- elif message.role == 'assistant' %}
                        {{- '<｜Assistant｜>' }}
                        {%- if message.content %}
                            {{- message.content }}
                        {%- endif %}
                        {%- if message.tool_calls %}
                            {%- for tool_call in message.tool_calls %}
                                {{- '<tool_call>\\n{"name": "' ~ tool_call.function.name ~ '", "arguments": ' ~ tool_call.function.arguments | tojson ~ '}\\n</tool_call>' }}
                            {%- endfor %}
                        {%- endif %}
                    {%- elif message.role == 'tool' %}
                        {{- '<｜User｜><tool_response>\\n' + message.content + '\\n</tool_response>' }}
                    {%- endif %}
                {%- endfor %}
                {%- if add_generation_prompt %}
                    {{- '<｜Assistant｜>' }}
                {%- endif %}
                """
            case .phi4, .phi3:
                return """
                {%- if tools %}
                    {{- '<|system|>\\n' }}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- messages[0]['content'] + '\\n\\n' }}
                    {%- endif %}
                    {{- 'You have access to tools. Call tools using <tool_call>{"name": "...", "arguments": {...}}</tool_call>\\n' }}
                    {%- for tool in tools %}
                        {{- tool.function | tojson ~ '\\n' }}
                    {%- endfor %}
                    {{- '<|end|>\\n' }}
                {%- else %}
                    {%- if messages[0]['role'] == 'system' %}
                        {{- '<|system|>\\n' + messages[0]['content'] + '<|end|>\\n' }}
                    {%- endif %}
                {%- endif %}
                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '<|user|>\\n' + message.content + '<|end|>\\n' }}
                    {%- elif message.role == 'assistant' %}
                        {{- '<|assistant|>\\n' }}
                        {%- if message.content %}{{- message.content }}{%- endif %}
                        {%- if message.tool_calls %}
                            {%- for tool_call in message.tool_calls %}
                                {{- '<tool_call>{"name": "' ~ tool_call.function.name ~ '", "arguments": ' ~ tool_call.function.arguments | tojson ~ '}</tool_call>' }}
                            {%- endfor %}
                        {%- endif %}
                        {{- '<|end|>\\n' }}
                    {%- elif message.role == 'tool' %}
                        {{- '<|user|>\\n<tool_response>\\n' + message.content + '\\n</tool_response><|end|>\\n' }}
                    {%- endif %}
                {%- endfor %}
                {%- if add_generation_prompt %}
                    {{- '<|assistant|>\\n' }}
                {%- endif %}
                """
            case .mistral:
                return """
                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '[INST] ' + message.content + ' [/INST]' }}
                    {%- elif message.role == 'assistant' %}
                        {{- ' ' }}
                        {%- if message.content %}{{- message.content }}{%- endif %}
                        {%- if message.tool_calls %}
                            {%- for tool_call in message.tool_calls %}
                                {{- '[TOOL_CALLS] [{"name": "' ~ tool_call.function.name ~ '", "arguments": ' ~ tool_call.function.arguments | tojson ~ '}]' }}
                            {%- endfor %}
                        {%- endif %}
                        {{- ' ' }}
                    {%- elif message.role == 'system' %}
                        {{- '[INST] ' + message.content + ' [/INST]' }}
                    {%- elif message.role == 'tool' %}
                        {{- '[INST] [TOOL_RESULTS] ' + message.content + ' [/TOOL_RESULTS] [/INST]' }}
                    {%- endif %}
                {%- endfor %}
                """
            case .gemma:
                return """
                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '<start_of_turn>user\\n' + message.content + '<end_of_turn>\\n' }}
                    {%- elif message.role == 'assistant' %}
                        {{- '<start_of_turn>model\\n' }}
                        {%- if message.content %}{{- message.content }}{%- endif %}
                        {%- if message.tool_calls %}
                            {%- for tool_call in message.tool_calls %}
                                {{- '<tool_call>\\n{"name": "' ~ tool_call.function.name ~ '", "arguments": ' ~ tool_call.function.arguments | tojson ~ '}\\n</tool_call>' }}
                            {%- endfor %}
                        {%- endif %}
                        {{- '<end_of_turn>\\n' }}
                    {%- elif message.role == 'tool' %}
                        {{- '<start_of_turn>user\\n<tool_response>\\n' + message.content + '\\n</tool_response><end_of_turn>\\n' }}
                    {%- endif %}
                {%- endfor %}
                {%- if add_generation_prompt %}
                    {{- '<start_of_turn>model\\n' }}
                {%- endif %}
                """
            case .llama2:
                return """
                {%- for message in messages %}
                    {%- if message.role == 'user' %}
                        {{- '[INST] ' + message.content + ' [/INST]' }}
                    {%- elif message.role == 'assistant' %}
                        {{- ' ' + message.content + ' ' }}
                    {%- endif %}
                {%- endfor %}
                """
            case .commandR:
                return """
                {%- for message in messages %}
                    {%- let role_token = message.role == 'system' ? 'SYSTEM' : (message.role == 'user' ? 'USER' : 'CHATBOT') %}
                    {{- '<|START_OF_TURN_TOKEN|><|' + role_token + '_TOKEN|>' + message.content + '<|END_OF_TURN_TOKEN|>' }}
                {%- endfor %}
                {%- if add_generation_prompt %}
                    {{- '<|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|>' }}
                {%- endif %}
                """
            }
        }
    }

    // MARK: - Template Detection

    /// Detects the appropriate template family from a model name, alias, or file path.
    static func detectTemplate(forModelName nameOrPath: String) -> ChatTemplateFamily {
        let lower = nameOrPath.lowercased()

        if lower.contains("qwen") || lower.contains("chatml") || lower.contains("yi-") || lower.contains("minicpm") {
            return .chatml
        }
        if lower.contains("llama-3") || lower.contains("llama3") || lower.contains("l3") {
            return .llama3
        }
        if lower.contains("llama-2") || lower.contains("llama2") || lower.contains("codellama") {
            return .llama2
        }
        if lower.contains("deepseek-v3") || lower.contains("deepseek-r1") || lower.contains("r1") {
            return .deepseek3
        }
        if lower.contains("deepseek") {
            return .deepseek
        }
        if lower.contains("mistral") || lower.contains("mixtral") || lower.contains("codestral") || lower.contains("devstral") {
            return .mistral
        }
        if lower.contains("gemma") {
            return .gemma
        }
        if lower.contains("phi-4") || lower.contains("phi4") {
            return .phi4
        }
        if lower.contains("phi-3") || lower.contains("phi3") {
            return .phi3
        }
        if lower.contains("command-r") || lower.contains("c4ai") {
            return .commandR
        }

        // Default to ChatML (standard open-weights format)
        return .chatml
    }

    /// Returns the `--chat-template` argument value for llama-server.
    static func detectLlamaServerTemplate(forPath path: String, alias: String) -> String {
        let detected = detectTemplate(forModelName: "\(path) \(alias)")
        return detected.llamaServerName
    }

    /// Exports a Jinja template file for a given template family and returns the file path.
    @discardableResult
    static func exportJinjaTemplateFile(for family: ChatTemplateFamily) -> String {
        exportAgenticTemplate(for: family)
    }

    /// Exports the production-ready agentic Jinja template file for a given template family.
    /// Saves to ~/.config/llama/templates/ (persistent) and /tmp/jxrouter_templates/ (ephemeral).
    @discardableResult
    static func exportAgenticTemplate(for family: ChatTemplateFamily) -> String {
        let userTemplatesDir = NSString(string: "~/.config/llama/templates").expandingTildeInPath
        let tmpTemplatesDir = "/tmp/jxrouter_templates"
        try? FileManager.default.createDirectory(atPath: userTemplatesDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(atPath: tmpTemplatesDir, withIntermediateDirectories: true)

        let filename = "\(family.rawValue)_tool_template.jinja"
        let userPath = "\(userTemplatesDir)/\(filename)"
        let tmpPath = "\(tmpTemplatesDir)/\(family.rawValue).jinja"

        let content = family.jinjaSource
        try? content.write(toFile: userPath, atomically: true, encoding: .utf8)
        try? content.write(toFile: tmpPath, atomically: true, encoding: .utf8)

        return userPath
    }

    /// Exports the agentic template for a template family name or model string.
    @discardableResult
    static func exportAgenticTemplate(for name: String) -> String {
        let family = ChatTemplateFamily(rawValue: name.lowercased()) ?? detectTemplate(forModelName: name)
        return exportAgenticTemplate(for: family)
    }

    /// Resolves an agentic template file for a model path and alias.
    static func agenticTemplatePath(forModelPath path: String, alias: String) -> String {
        let family = detectTemplate(forModelName: "\(path) \(alias)")
        return exportAgenticTemplate(for: family)
    }

    // MARK: - Tool Prompt Injection for Local Inference

    /// Injects tool definitions and calling instructions into the system prompt.
    /// This enables ANY local model to execute tool calling even if the local
    /// inference app (Ollama, LM Studio, llama-server) does not support native
    /// OpenAI function calling or has a template without tool support.
    static func injectToolsIntoSystemPrompt(system: String?, tools: [Any]) -> String {
        guard !tools.isEmpty else { return system ?? "" }

        var toolsDoc: [String] = []
        for item in tools {
            if let dict = item as? [String: Any] {
                let name = (dict["name"] as? String) ?? ((dict["function"] as? [String: Any])?["name"] as? String) ?? "tool"
                let desc = (dict["description"] as? String) ?? ((dict["function"] as? [String: Any])?["description"] as? String) ?? ""
                let params = (dict["input_schema"] as? [String: Any]) ?? ((dict["parameters"] as? [String: Any]) ?? ((dict["function"] as? [String: Any])?["parameters"] as? [String: Any])) ?? [:]

                let paramsJson = (try? JSONSerialization.data(withJSONObject: params, options: []))
                    .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

                toolsDoc.append("- **\(name)**: \(desc)\n  Parameters: \(paramsJson)")
            }
        }

        let toolsSection = """
        # Available Tools
        You have access to the following tools:
        \(toolsDoc.joined(separator: "\n\n"))

        # Tool Execution Protocol
        When you need to execute a tool, you MUST output the tool call using this exact XML block:
        <tool_call>
        {"name": "<tool_name>", "arguments": {<arguments_json_object>}}
        </tool_call>
        Do not describe what you are about to do; emit the <tool_call> block directly. If no tool is needed, respond with standard text.
        """

        if let existing = system, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "\(existing)\n\n\(toolsSection)"
        } else {
            return toolsSection
        }
    }

    // MARK: - Qwen XML Tool Call Parser

    /// Parses Qwen XML tool format: <function=NAME><parameter=KEY>VALUE</parameter></function>
    static func parseQwenXmlToolCall(from text: String) -> (name: String, input: [String: Any])? {
        let fnRegex = try? NSRegularExpression(pattern: #"<function=([^>\s]+)>\s*([\s\S]*?)\s*</function>"#, options: [])
        guard let match = fnRegex?.firstMatch(in: text, options: [], range: NSRange(location: 0, length: text.utf16.count)),
              let nameRange = Range(match.range(at: 1), in: text),
              let bodyRange = Range(match.range(at: 2), in: text) else {
            return nil
        }

        let name = String(text[nameRange])
        let body = String(text[bodyRange])
        var input: [String: Any] = [:]

        let paramRegex = try? NSRegularExpression(pattern: #"<parameter=([^>\s]+)>\s*([\s\S]*?)\s*</parameter>"#, options: [])
        if let paramMatches = paramRegex?.matches(in: body, options: [], range: NSRange(location: 0, length: body.utf16.count)) {
            for pm in paramMatches {
                if let keyRange = Range(pm.range(at: 1), in: body),
                   let valRange = Range(pm.range(at: 2), in: body) {
                    let key = String(body[keyRange])
                    let valStr = String(body[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                    if let parsed = try? JSONSerialization.jsonObject(with: Data(valStr.utf8)), !(parsed is NSNull) {
                        input[key] = parsed
                    } else if valStr.lowercased() == "true" {
                        input[key] = true
                    } else if valStr.lowercased() == "false" {
                        input[key] = false
                    } else if let num = Double(valStr) {
                        input[key] = num
                    } else {
                        input[key] = valStr
                    }
                }
            }
        }

        return (name, input)
    }

    // MARK: - Text-Based Tool Call Extractor

    /// Extracts structured tool calls from free-form text output emitted by local models.
    /// Supports `<tool_call>...</tool_call>`, `<function=...></function>`, `[TOOL_CALLS] [...]`, and markdown json blocks.
    static func extractToolCalls(from text: String) -> (cleanText: String, toolCalls: [[String: Any]]) {
        var cleanText = text
        var toolCalls: [[String: Any]] = []

        // Pattern 1: <tool_call> ... </tool_call> (JSON or Qwen XML)
        let toolCallRegex = try? NSRegularExpression(pattern: #"<tool_call>\s*([\s\S]*?)\s*</tool_call>"#, options: [])
        if let matches = toolCallRegex?.matches(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)), !matches.isEmpty {
            for match in matches.reversed() {
                if let jsonRange = Range(match.range(at: 1), in: cleanText) {
                    let blockContent = String(cleanText[jsonRange]).trimmingCharacters(in: .whitespacesAndNewlines)

                    // Sub-case 1A: JSON format: {"name": "...", "arguments": {...}}
                    if let dict = (try? JSONSerialization.jsonObject(with: Data(blockContent.utf8))) as? [String: Any],
                       let name = dict["name"] as? String {
                        let id = "call_\(UUID().uuidString.prefix(8))"
                        let args = (dict["arguments"] as? [String: Any]) ?? [:]
                        let argsStr = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.insert([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": argsStr
                            ],
                            "name": name,
                            "input": args
                        ], at: 0)
                    }
                    // Sub-case 1B: Qwen XML format: <function=name><parameter=key>val</parameter></function>
                    else if let qwen = parseQwenXmlToolCall(from: blockContent) {
                        let id = "call_\(UUID().uuidString.prefix(8))"
                        let argsStr = (try? JSONSerialization.data(withJSONObject: qwen.input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.insert([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": qwen.name,
                                "arguments": argsStr
                            ],
                            "name": qwen.name,
                            "input": qwen.input
                        ], at: 0)
                    }
                }
                if let fullRange = Range(match.range(at: 0), in: cleanText) {
                    cleanText.removeSubrange(fullRange)
                }
            }
        }

        // Pattern 2: [TOOL_CALLS] [ {...} ]
        let bracketRegex = try? NSRegularExpression(pattern: #"\[TOOL_CALLS\]\s*(\[[\s\S]*?\]|\{[\s\S]*?\})"#, options: [])
        if let matches = bracketRegex?.matches(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)), !matches.isEmpty {
            for match in matches.reversed() {
                if let jsonRange = Range(match.range(at: 1), in: cleanText) {
                    let jsonString = String(cleanText[jsonRange])
                    if let arr = (try? JSONSerialization.jsonObject(with: Data(jsonString.utf8))) as? [[String: Any]] {
                        for dict in arr {
                            if let name = dict["name"] as? String {
                                let id = "call_\(UUID().uuidString.prefix(8))"
                                let args = (dict["arguments"] as? [String: Any]) ?? [:]
                                let argsStr = (try? JSONSerialization.data(withJSONObject: args)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                                // insert(at: 0): reversed() iteration + append would
                                // emit multi-block calls in REVERSE document order.
                                toolCalls.insert([
                                    "id": id,
                                    "type": "function",
                                    "function": [
                                        "name": name,
                                        "arguments": argsStr
                                    ],
                                    "name": name,
                                    "input": args
                                ], at: 0)
                            }
                        }
                    } else if let dict = (try? JSONSerialization.jsonObject(with: Data(jsonString.utf8))) as? [String: Any],
                              let name = dict["name"] as? String {
                        let id = "call_\(UUID().uuidString.prefix(8))"
                        let args = (dict["arguments"] as? [String: Any]) ?? [:]
                        toolCalls.insert([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": name,
                                "arguments": jsonString
                            ],
                            "name": name,
                            "input": args
                        ], at: 0)
                    }
                }
                if let fullRange = Range(match.range(at: 0), in: cleanText) {
                    cleanText.removeSubrange(fullRange)
                }
            }
        }

        // Pattern 3: Bare Qwen <function=...> ... </function> (without outer <tool_call>)
        let bareFnRegex = try? NSRegularExpression(pattern: #"<function=([^>\s]+)>\s*([\s\S]*?)\s*</function>"#, options: [])
        if let matches = bareFnRegex?.matches(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)), !matches.isEmpty {
            for match in matches.reversed() {
                if let fullRange = Range(match.range(at: 0), in: cleanText) {
                    let fnBlock = String(cleanText[fullRange])
                    if let qwen = parseQwenXmlToolCall(from: fnBlock) {
                        let id = "call_\(UUID().uuidString.prefix(8))"
                        let argsStr = (try? JSONSerialization.data(withJSONObject: qwen.input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                        toolCalls.insert([
                            "id": id,
                            "type": "function",
                            "function": [
                                "name": qwen.name,
                                "arguments": argsStr
                            ],
                            "name": qwen.name,
                            "input": qwen.input
                        ], at: 0)
                    }
                    cleanText.removeSubrange(fullRange)
                }
            }
        }

        // Pattern 4: Anthropic-style <invoke name="X"> … </invoke> blocks,
        // optionally wrapped in <function_calls>. Local models that were
        // trained on the Claude tool dialect emit this shape — with either
        // <parameter name="K">V</parameter> or Qwen's <parameter=K>V</parameter>
        // — instead of the <tool_call> JSON the injected protocol asks for.
        // Without this the call stays in the transcript as prose and nothing
        // ever executes: the "announces a tool, never calls it" failure.
        let invokeRegex = try? NSRegularExpression(pattern: #"<invoke\s+name\s*=\s*["']([^"']+)["']\s*>([\s\S]*?)</invoke>"#, options: [])
        if let matches = invokeRegex?.matches(in: cleanText, options: [], range: NSRange(location: 0, length: cleanText.utf16.count)), !matches.isEmpty {
            for match in matches.reversed() {
                defer {
                    if let fullRange = Range(match.range(at: 0), in: cleanText) {
                        cleanText.removeSubrange(fullRange)
                    }
                }
                guard let nameRange = Range(match.range(at: 1), in: cleanText),
                      let bodyRange = Range(match.range(at: 2), in: cleanText) else { continue }

                let name = String(cleanText[nameRange])
                let body = String(cleanText[bodyRange])
                var input: [String: Any] = [:]

                // Both parameter dialects, in one pass:
                //   <parameter name="K">V</parameter>   (Claude dialect)
                //   <parameter=K>V</parameter>          (Qwen dialect)
                let paramRegex = try? NSRegularExpression(pattern: #"<parameter(?:\s+name\s*=\s*["']([^"']+)["']|\s*=\s*([^>\s]+))\s*>([\s\S]*?)</parameter>"#, options: [])
                if let paramMatches = paramRegex?.matches(in: body, options: [], range: NSRange(location: 0, length: body.utf16.count)) {
                    for pm in paramMatches {
                        let quotedKey = Range(pm.range(at: 1), in: body)
                        let bareKey = Range(pm.range(at: 2), in: body)
                        guard let keyRange = quotedKey ?? bareKey,
                              let valRange = Range(pm.range(at: 3), in: body) else { continue }
                        let key = String(body[keyRange])
                        let valStr = String(body[valRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                        if let parsed = try? JSONSerialization.jsonObject(with: Data(valStr.utf8)), !(parsed is NSNull) {
                            input[key] = parsed
                        } else if valStr.lowercased() == "true" {
                            input[key] = true
                        } else if valStr.lowercased() == "false" {
                            input[key] = false
                        } else if let num = Double(valStr) {
                            input[key] = num
                        } else {
                            input[key] = valStr
                        }
                    }
                }

                let id = "call_\(UUID().uuidString.prefix(8))"
                let argsStr = (try? JSONSerialization.data(withJSONObject: input)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
                toolCalls.insert([
                    "id": id,
                    "type": "function",
                    "function": [
                        "name": name,
                        "arguments": argsStr
                    ],
                    "name": name,
                    "input": input
                ], at: 0)
            }
        }
        // The <function_calls> wrapper is scaffolding, never content — drop the
        // surviving tags so they cannot leak into the visible transcript.
        if !toolCalls.isEmpty {
            cleanText = cleanText.replacingOccurrences(of: #"</?function_calls>"#, with: "", options: .regularExpression)
        }

        cleanText = cleanText.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleanText, toolCalls)
    }

    // MARK: - Prompt Rendering for Raw Completions Fallback

    /// Renders an array of chat messages into a single prompt string using the model's chat template.
    /// Used when a local server's `/v1/chat/completions` endpoint is non-functional or fails,
    /// allowing seamless fallback to `/v1/completions`.
    static func renderPrompt(messages: [[String: Any]], template: ChatTemplateFamily) -> String {
        var buffer = ""

        switch template {
        case .chatml, .standard:
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                buffer += "<|im_start|>\(role)\n\(content)<|im_end|>\n"
            }
            buffer += "<|im_start|>assistant\n"

        case .llama3:
            buffer += "<|begin_of_text|>"
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                buffer += "<|start_header_id|>\(role)<|end_header_id|>\n\n\(content)<|eot_id|>"
            }
            buffer += "<|start_header_id|>assistant<|end_header_id|>\n\n"

        case .llama2:
            var systemPrompt = ""
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                if role == "system" {
                    systemPrompt = "<<SYS>>\n\(content)\n<</SYS>>\n\n"
                } else if role == "user" {
                    buffer += "[INST] \(systemPrompt)\(content) [/INST] "
                    systemPrompt = ""
                } else if role == "assistant" {
                    buffer += "\(content) "
                }
            }

        case .deepseek, .deepseek3:
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                if role == "system" {
                    buffer += "\(content)\n\n"
                } else if role == "user" {
                    buffer += "<｜User｜>\(content)"
                } else if role == "assistant" {
                    buffer += "<｜Assistant｜>\(content)"
                }
            }
            buffer += "<｜Assistant｜>"

        case .mistral:
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                if role == "user" {
                    buffer += "[INST] \(content) [/INST] "
                } else if role == "assistant" {
                    buffer += "\(content) "
                } else if role == "system" {
                    buffer += "[INST] \(content) [/INST] "
                }
            }

        case .gemma:
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                buffer += "<start_of_turn>\(role)\n\(content)<end_of_turn>\n"
            }
            buffer += "<start_of_turn>model\n"

        case .phi3, .phi4:
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                buffer += "<|\(role)|>\n\(content)<|end|>\n"
            }
            buffer += "<|assistant|>\n"

        case .commandR:
            for msg in messages {
                let role = msg["role"] as? String ?? "user"
                let content = msg["content"] as? String ?? ""
                let token = role == "system" ? "SYSTEM" : (role == "user" ? "USER" : "CHATBOT")
                buffer += "<|START_OF_TURN_TOKEN|><|\(token)_TOKEN|>\(content)<|END_OF_TURN_TOKEN|>"
            }
            buffer += "<|START_OF_TURN_TOKEN|><|CHATBOT_TOKEN|>"
        }

        return buffer
    }
}
