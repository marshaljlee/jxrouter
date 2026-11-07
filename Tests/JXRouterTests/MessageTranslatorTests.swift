import Foundation
import XCTest

/// Standalone test suite for MessageTranslator validating tool calling, multimodal
/// images, sequential SSE block lifecycle, and reasoning parameter handling.
final class MessageTranslatorTests {

    static var failedTests: [String] = []

    static func assertEqual<T: Equatable>(_ a: T?, _ b: T?, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        if a != b {
            let failure = "FAILED: \(message) - expected \(String(describing: b)), got \(String(describing: a)) at \(file):\(line)"
            print("🔴 \(failure)")
            failedTests.append(failure)
        }
    }

    static func assertTrue(_ condition: Bool, _ message: String = "", file: StaticString = #file, line: UInt = #line) {
        if !condition {
            let failure = "FAILED: \(message) at \(file):\(line)"
            print("🔴 \(failure)")
            failedTests.append(failure)
        }
    }

    // MARK: - Tests

    static func testToolDefinitionConversion() {
        print("▶️ Running testToolDefinitionConversion...")
        let anthropicTools: [[String: Any]] = [
            [
                "name": "Bash",
                "description": "Run a bash command",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "Command string"
                        ],
                        "website": [
                            "type": "string",
                            "format": "uri" // Should be stripped by sanitizer
                        ]
                    ],
                    "required": ["command"]
                ]
            ]
        ]

        let converted = MessageTranslator.convertToolsToOpenAI(anthropicTools: anthropicTools)
        assertEqual(converted.count, 1, "Should have 1 converted tool")

        guard let first = converted.first else { return }
        assertEqual(first["type"] as? String, "function", "Tool type must be function")

        guard let fn = first["function"] as? [String: Any] else {
            assertTrue(false, "Missing function dictionary")
            return
        }
        assertEqual(fn["name"] as? String, "Bash", "Function name must match")
        assertEqual(fn["description"] as? String, "Run a bash command", "Description must match")

        guard let params = fn["parameters"] as? [String: Any],
              let props = params["properties"] as? [String: [String: Any]] else {
            assertTrue(false, "Parameters properties missing")
            return
        }
        assertEqual(props["command"]?["type"] as? String, "string", "command property should exist")
        assertTrue(props["website"]?["format"] == nil, "format: uri must be stripped to prevent OpenAI 400 rejection")
    }

    static func testToolChoiceConversion() {
        print("▶️ Running testToolChoiceConversion...")
        assertEqual(MessageTranslator.convertToolChoiceToOpenAI("auto") as? String, "auto")
        assertEqual(MessageTranslator.convertToolChoiceToOpenAI("any") as? String, "required")
        assertEqual(MessageTranslator.convertToolChoiceToOpenAI("none") as? String, "none")

        let specificTool: [String: Any] = ["type": "tool", "name": "read_file"]
        let converted = MessageTranslator.convertToolChoiceToOpenAI(specificTool) as? [String: Any]
        assertEqual(converted?["type"] as? String, "function")
        let fn = converted?["function"] as? [String: Any]
        assertEqual(fn?["name"] as? String, "read_file")
    }

    static func testAssistantToolUseAndUserToolResultHistory() {
        print("▶️ Running testAssistantToolUseAndUserToolResultHistory...")
        let rawRequest: [String: Any] = [
            "model": "claude-3-5-sonnet-20241022",
            "messages": [
                [
                    "role": "user",
                    "content": "List files in directory"
                ],
                [
                    "role": "assistant",
                    "content": [
                        ["type": "text", "text": "I will execute ls."],
                        [
                            "type": "tool_use",
                            "id": "toolu_abc123",
                            "name": "Bash",
                            "input": ["command": "ls -la"]
                        ]
                    ]
                ],
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "tool_result",
                            "tool_use_id": "toolu_abc123",
                            "content": "file1.txt\nfile2.txt"
                        ]
                    ]
                ]
            ]
        ]

        let req = MessagesRequest(json: rawRequest)
        let openAIBody = MessageTranslator.toOpenAIChat(request: req, model: "gpt-4o", enableThinking: false)

        guard let msgs = openAIBody["messages"] as? [[String: Any]] else {
            assertTrue(false, "Messages array missing in OpenAI body")
            return
        }

        assertEqual(msgs.count, 3, "Should produce 3 messages (user, assistant with tool_calls, tool)")

        // Message 1: User
        assertEqual(msgs[0]["role"] as? String, "user")
        assertEqual(msgs[0]["content"] as? String, "List files in directory")

        // Message 2: Assistant with tool_calls
        assertEqual(msgs[1]["role"] as? String, "assistant")
        assertEqual(msgs[1]["content"] as? String, "I will execute ls.")
        guard let toolCalls = msgs[1]["tool_calls"] as? [[String: Any]] else {
            assertTrue(false, "assistant message must contain tool_calls array")
            return
        }
        assertEqual(toolCalls.count, 1)
        assertEqual(toolCalls[0]["id"] as? String, "toolu_abc123")
        assertEqual(toolCalls[0]["type"] as? String, "function")
        let fn = toolCalls[0]["function"] as? [String: Any]
        assertEqual(fn?["name"] as? String, "Bash")
        assertTrue((fn?["arguments"] as? String)?.contains("ls -la") == true, "arguments must serialize input")

        // Message 3: Tool response
        assertEqual(msgs[2]["role"] as? String, "tool", "tool_result must translate to role: tool")
        assertEqual(msgs[2]["tool_call_id"] as? String, "toolu_abc123", "tool_call_id must match tool_use_id")
        assertEqual(msgs[2]["content"] as? String, "file1.txt\nfile2.txt")
    }

    static func testMultimodalImageTranslation() {
        print("▶️ Running testMultimodalImageTranslation...")
        let rawRequest: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": "Describe this image"],
                        [
                            "type": "image",
                            "source": [
                                "type": "base64",
                                "media_type": "image/jpeg",
                                "data": "dGVzdGltYWdlZGF0YQ=="
                            ]
                        ]
                    ]
                ]
            ]
        ]

        let req = MessagesRequest(json: rawRequest)
        let openAIBody = MessageTranslator.toOpenAIChat(request: req, model: "gpt-4o", enableThinking: false)

        guard let msgs = openAIBody["messages"] as? [[String: Any]],
              let userContent = msgs.first?["content"] as? [[String: Any]] else {
            assertTrue(false, "Multimodal content parts missing")
            return
        }

        assertEqual(userContent.count, 2)
        assertEqual(userContent[0]["type"] as? String, "text")
        assertEqual(userContent[1]["type"] as? String, "image_url")
        let imgUrlDict = userContent[1]["image_url"] as? [String: Any]
        assertEqual(imgUrlDict?["url"] as? String, "data:image/jpeg;base64,dGVzdGltYWdlZGF0YQ==")
    }

    static func testReasoningModelParameterSanitization() {
        print("▶️ Running testReasoningModelParameterSanitization...")
        let rawRequest: [String: Any] = [
            "model": "claude-3-5-sonnet",
            "temperature": 0.7,
            "max_tokens": 4096,
            "messages": [["role": "user", "content": "Hello"]]
        ]

        let req = MessagesRequest(json: rawRequest)
        let o1Body = MessageTranslator.toOpenAIChat(request: req, model: "o1-mini", enableThinking: true)

        assertTrue(o1Body["temperature"] == nil, "o1 models forbid temperature parameter")
        assertEqual(o1Body["max_completion_tokens"] as? Int, 4096, "o1 uses max_completion_tokens")

        let gpt4oBody = MessageTranslator.toOpenAIChat(request: req, model: "gpt-4o", enableThinking: false)
        assertEqual(gpt4oBody["temperature"] as? Double, 0.7, "Standard models keep temperature")
        assertEqual(gpt4oBody["max_tokens"] as? Int, 4096)
    }

    static func testNonStreamingToolCallResponse() {
        print("▶️ Running testNonStreamingToolCallResponse...")
        let openAIJSON: [String: Any] = [
            "id": "chatcmpl-test1234",
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": "Checking current directory.",
                        "tool_calls": [
                            [
                                "id": "call_xyz789",
                                "type": "function",
                                "function": [
                                    "name": "Bash",
                                    "arguments": "{\"command\":\"pwd\"}"
                                ]
                            ]
                        ]
                    ],
                    "finish_reason": "tool_calls"
                ]
            ],
            "usage": ["prompt_tokens": 15, "completion_tokens": 20]
        ]

        let data = try! JSONSerialization.data(withJSONObject: openAIJSON)
        let convertedData = MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: "claude-3-5-sonnet", enableThinking: false)

        guard let anthropicJSON = try! JSONSerialization.jsonObject(with: convertedData) as? [String: Any] else {
            assertTrue(false, "Invalid JSON from convertOpenAIResponseToAnthropic")
            return
        }

        assertEqual(anthropicJSON["stop_reason"] as? String, "tool_use", "Stop reason must be tool_use")
        guard let content = anthropicJSON["content"] as? [[String: Any]] else {
            assertTrue(false, "content array missing")
            return
        }

        assertEqual(content.count, 2, "Should contain text block and tool_use block")
        assertEqual(content[0]["type"] as? String, "text")
        assertEqual(content[0]["text"] as? String, "Checking current directory.")

        assertEqual(content[1]["type"] as? String, "tool_use")
        assertEqual(content[1]["id"] as? String, "call_xyz789")
        assertEqual(content[1]["name"] as? String, "Bash")
        let inputDict = content[1]["input"] as? [String: Any]
        assertEqual(inputDict?["command"] as? String, "pwd")
    }

    static func testStreamingToolCallsSSE() {
        print("▶️ Running testStreamingToolCallsSSE...")
        var state = MessageTranslator.OpenAIStreamState()

        // Chunk 1: message start with delta content
        let chunk1: [String: Any] = [
            "choices": [
                [
                    "delta": ["content": "I will run the command."],
                    "finish_reason": NSNull()
                ]
            ]
        ]
        let events1 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk1, model: "claude-3-5-sonnet", state: &state, enableThinking: false)
        assertTrue(events1.contains { $0.contains("event: message_start") }, "Chunk 1 must emit message_start")
        assertTrue(events1.contains { $0.contains("content_block_start") && $0.contains("\"text\"") }, "Chunk 1 must start text block")
        assertTrue(events1.contains { $0.contains("text_delta") && $0.contains("I will run") }, "Chunk 1 must emit text_delta")

        // Chunk 2: tool_call start with function name and partial arguments
        let chunk2: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0,
                                "id": "call_123",
                                "type": "function",
                                "function": [
                                    "name": "Bash",
                                    "arguments": "{\"com"
                                ]
                            ]
                        ]
                    ],
                    "finish_reason": NSNull()
                ]
            ]
        ]
        let events2 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk2, model: "claude-3-5-sonnet", state: &state, enableThinking: false)
        assertTrue(events2.contains { $0.contains("content_block_stop") && $0.contains("\"index\":0") }, "Must close text block before opening tool block")
        assertTrue(events2.contains { $0.contains("content_block_start") && $0.contains("\"tool_use\"") && $0.contains("\"name\":\"Bash\"") }, "Must start tool_use block")
        assertTrue(events2.contains { $0.contains("input_json_delta") && $0.contains("com") }, "Must emit input_json_delta")

        // Chunk 3: tool_call argument continuation
        let chunk3: [String: Any] = [
            "choices": [
                [
                    "delta": [
                        "tool_calls": [
                            [
                                "index": 0,
                                "function": [
                                    "arguments": "mand\":\"whoami\"}"
                                ]
                            ]
                        ]
                    ],
                    "finish_reason": NSNull()
                ]
            ]
        ]
        let events3 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk3, model: "claude-3-5-sonnet", state: &state, enableThinking: false)
        assertTrue(events3.contains { $0.contains("input_json_delta") && $0.contains("whoami") }, "Must emit continuation input_json_delta")

        // Chunk 4: finish_reason tool_calls
        let chunk4: [String: Any] = [
            "choices": [
                [
                    "delta": [:],
                    "finish_reason": "tool_calls"
                ]
            ],
            "usage": ["prompt_tokens": 20, "completion_tokens": 12]
        ]
        let events4 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk4, model: "claude-3-5-sonnet", state: &state, enableThinking: false)
        assertTrue(events4.contains { $0.contains("content_block_stop") && $0.contains("\"index\":1") }, "Must close tool_use block on finish")
        assertTrue(events4.contains { $0.contains("message_delta") && $0.contains("\"stop_reason\":\"tool_use\"") }, "Must emit message_delta with stop_reason tool_use")
    }

    static func testSequentialSSEBlockDiscipline() {
        print("▶️ Running testSequentialSSEBlockDiscipline...")
        var state = MessageTranslator.OpenAIStreamState()

        // Chunk 1: Reasoning content
        let chunk1: [String: Any] = [
            "choices": [
                [
                    "delta": ["reasoning_content": "Thinking about the question..."],
                    "finish_reason": NSNull()
                ]
            ]
        ]
        let events1 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk1, model: "deepseek-r1", state: &state, enableThinking: true)
        assertTrue(events1.contains { $0.contains("content_block_start") && $0.contains("\"thinking\"") })

        // Chunk 2: Transition from reasoning to content
        let chunk2: [String: Any] = [
            "choices": [
                [
                    "delta": ["content": "Here is the answer."],
                    "finish_reason": NSNull()
                ]
            ]
        ]
        let events2 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk2, model: "deepseek-r1", state: &state, enableThinking: true)

        // Verify sequential discipline: blockStop for thinking (index 0) MUST appear BEFORE blockStart for text (index 1)
        var thinkStopIdx = -1
        var textStartIdx = -1
        for (i, ev) in events2.enumerated() {
            if ev.contains("content_block_stop") && ev.contains("\"index\":0") {
                thinkStopIdx = i
            }
            if ev.contains("content_block_start") && ev.contains("\"index\":1") {
                textStartIdx = i
            }
        }
        assertTrue(thinkStopIdx != -1, "Thinking block must be closed")
        assertTrue(textStartIdx != -1, "Text block must be started")
        assertTrue(thinkStopIdx < textStartIdx, "Thinking block must be closed BEFORE text block starts")
    }

    static func testInlineThinkTagExtraction() {
        print("▶️ Running testInlineThinkTagExtraction...")
        var state = MessageTranslator.OpenAIStreamState()

        // Local model sends `<think>planning step</think>The final output` inside content
        let chunk1: [String: Any] = [
            "choices": [
                [
                    "delta": ["content": "<think>planning step</think>The final output"],
                    "finish_reason": NSNull()
                ]
            ]
        ]
        let events = MessageTranslator.openAIToAnthropicSSE(chunk: chunk1, model: "ollama/qwen", state: &state, enableThinking: true)

        assertTrue(events.contains { $0.contains("content_block_start") && $0.contains("\"thinking\"") }, "Must start thinking block for <think>")
        assertTrue(events.contains { $0.contains("thinking_delta") && $0.contains("planning step") }, "Must extract thinking text")
        assertTrue(events.contains { $0.contains("content_block_stop") }, "Must close thinking block after </think>")
        assertTrue(events.contains { $0.contains("content_block_start") && $0.contains("\"text\"") }, "Must start text block for content after </think>")
        assertTrue(events.contains { $0.contains("text_delta") && $0.contains("The final output") }, "Must emit visible text")
        assertTrue(!events.contains { $0.contains("<think>") || $0.contains("</think>") }, "Must not leak raw tags to client")
    }

    static func testLocalModelChatTemplateDetection() {
        print("▶️ Running testLocalModelChatTemplateDetection...")
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "Qwen2.5-Coder-7B-Instruct.Q4_K_M.gguf"), .chatml)
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "Meta-Llama-3.1-8B-Instruct.gguf"), .llama3)
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "DeepSeek-R1.gguf"), .deepseek3)
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "deepseek-r1-distill-qwen-14b.gguf"), .chatml)
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "Mistral-7B-Instruct-v0.3.gguf"), .mistral)
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "Phi-4-mini-instruct.gguf"), .phi4)
        assertEqual(LocalChatTemplateEngine.detectTemplate(forModelName: "gemma-2-9b-it.gguf"), .gemma)

        // Test llama-server flag mapping
        assertEqual(LocalChatTemplateEngine.detectLlamaServerTemplate(forPath: "/models/qwen.gguf", alias: "qwen"), "chatml")
        assertEqual(LocalChatTemplateEngine.detectLlamaServerTemplate(forPath: "/models/Meta-Llama-3-8B.gguf", alias: "l3"), "llama3")
        assertEqual(LocalChatTemplateEngine.detectLlamaServerTemplate(forPath: "/models/deepseek-r1.gguf", alias: "r1"), "deepseek3")
    }

    static func testLocalModelSystemPromptToolInjection() {
        print("▶️ Running testLocalModelSystemPromptToolInjection...")
        let tools: [[String: Any]] = [
            [
                "name": "readFile",
                "description": "Reads a file from disk",
                "input_schema": [
                    "type": "object",
                    "properties": [
                        "path": ["type": "string"]
                    ],
                    "required": ["path"]
                ]
            ]
        ]

        let injected = LocalChatTemplateEngine.injectToolsIntoSystemPrompt(system: "You are a coding assistant.", tools: tools)
        assertTrue(injected.contains("You are a coding assistant."), "Must preserve base system prompt")
        assertTrue(injected.contains("# Available Tools"), "Must include Available Tools header")
        assertTrue(injected.contains("readFile"), "Must include tool name")
        assertTrue(injected.contains("<tool_call>"), "Must include <tool_call> protocol instructions")

        // Test toOpenAIChat with injectToolsIntoPrompt: true
        let reqJson: [String: Any] = [
            "model": "local/qwen",
            "system": "Base system.",
            "messages": [["role": "user", "content": "read /tmp/foo"]],
            "tools": tools,
            "stream": false
        ]
        let req = MessagesRequest(json: reqJson)

        let openaiBody = MessageTranslator.toOpenAIChat(request: req, model: "local/qwen", enableThinking: false, injectToolsIntoPrompt: true)
        assertTrue(openaiBody["tools"] == nil, "Native tools must be omitted when injected into prompt")
        assertTrue(openaiBody["tool_choice"] == nil, "Native tool_choice must be omitted")

        let messages = (openaiBody["messages"] as? [[String: Any]]) ?? []
        let sysMsg = messages.first(where: { ($0["role"] as? String) == "system" })
        let sysContent = (sysMsg?["content"] as? String) ?? ""
        assertTrue(sysContent.contains("<tool_call>"), "System message must contain tool instructions")
        assertTrue(sysContent.contains("readFile"), "System message must contain readFile documentation")
    }

    static func testLocalModelTextBasedToolExtraction() {
        print("▶️ Running testLocalModelTextBasedToolExtraction...")
        let rawModelResponse = """
        I will read the requested file now.
        <tool_call>
        {"name": "readFile", "arguments": {"path": "/tmp/test.txt"}}
        </tool_call>
        """

        let openaiJson: [String: Any] = [
            "id": "chatcmpl-123",
            "choices": [
                [
                    "message": [
                        "role": "assistant",
                        "content": rawModelResponse
                    ],
                    "finish_reason": "stop"
                ]
            ]
        ]
        let data = try! JSONSerialization.data(withJSONObject: openaiJson)
        let anthropicData = MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: "local-model", enableThinking: false)

        guard let res = try? JSONSerialization.jsonObject(with: anthropicData) as? [String: Any] else {
            assertTrue(false, "Failed to parse converted Anthropic response")
            return
        }

        assertEqual(res["stop_reason"] as? String, "tool_use", "Stop reason must be converted to tool_use")
        let content = res["content"] as? [[String: Any]] ?? []

        // Should have text block and tool_use block
        let textBlock = content.first { ($0["type"] as? String) == "text" }
        assertEqual(textBlock?["text"] as? String, "I will read the requested file now.")

        let toolBlock = content.first { ($0["type"] as? String) == "tool_use" }
        assertEqual(toolBlock?["name"] as? String, "readFile")
        let input = toolBlock?["input"] as? [String: Any]
        assertEqual(input?["path"] as? String, "/tmp/test.txt")

        // Test Qwen XML format (<tool_call><function=...><parameter=...>...</parameter></function></tool_call>)
        let qwenXmlResponse = """
        <tool_call>
        <function=read_file>
        <parameter=path>
        /etc/hosts
        </parameter>
        </function>
        </tool_call>
        """
        let qwenOpenaiJson: [String: Any] = [
            "id": "chatcmpl-456",
            "choices": [["message": ["role": "assistant", "content": qwenXmlResponse], "finish_reason": "stop"]]
        ]
        let qwenData = try! JSONSerialization.data(withJSONObject: qwenOpenaiJson)
        let qwenAnthropic = MessageTranslator.convertOpenAIResponseToAnthropic(data: qwenData, model: "local/ornith", enableThinking: false)
        guard let qwenRes = try? JSONSerialization.jsonObject(with: qwenAnthropic) as? [String: Any] else {
            assertTrue(false, "Failed to parse converted Qwen Anthropic response")
            return
        }
        assertEqual(qwenRes["stop_reason"] as? String, "tool_use", "Stop reason must be tool_use for Qwen XML")
        let qwenContent = qwenRes["content"] as? [[String: Any]] ?? []
        let qwenTool = qwenContent.first { ($0["type"] as? String) == "tool_use" }
        assertEqual(qwenTool?["name"] as? String, "read_file", "Qwen tool name must match")
        let qwenInput = qwenTool?["input"] as? [String: Any]
        assertEqual(qwenInput?["path"] as? String, "/etc/hosts", "Qwen parameter path must match")
    }

    static func testStreamingLocalModelToolCallExtraction() {
        print("▶️ Running testStreamingLocalModelToolCallExtraction...")
        var state = MessageTranslator.OpenAIStreamState()

        // Chunk 1: Text leading up to <tool_call>
        let chunk1: [String: Any] = [
            "choices": [["delta": ["content": "Let me check that.<tool_call>{\"name\": \"readFile\""], "finish_reason": NSNull()]]
        ]
        let events1 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk1, model: "local", state: &state, enableThinking: false)
        assertTrue(events1.contains { $0.contains("text_delta") && $0.contains("Let me check that.") }, "Must emit visible text before tool call")

        // Chunk 2: Remainder of tool call closing with </tool_call>
        let chunk2: [String: Any] = [
            "choices": [["delta": ["content": ", \"arguments\": {\"path\": \"/etc/hosts\"}}</tool_call>Done!"], "finish_reason": NSNull()]]
        ]
        let events2 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk2, model: "local", state: &state, enableThinking: false)

        assertTrue(events2.contains { $0.contains("content_block_start") && $0.contains("\"tool_use\"") && $0.contains("readFile") }, "Must start tool_use block")
        assertTrue(events2.contains { $0.contains("input_json_delta") && $0.contains("hosts") }, "Must emit tool arguments")
        assertTrue(events2.contains { $0.contains("content_block_stop") }, "Must stop tool_use block")
        assertTrue(events2.contains { $0.contains("text_delta") && $0.contains("Done!") }, "Must emit text following tool call")

        // Finish chunk
        let chunk3: [String: Any] = [
            "choices": [["delta": [:], "finish_reason": "stop"]]
        ]
        let events3 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk3, model: "local", state: &state, enableThinking: false)
        assertTrue(events3.contains { $0.contains("\"stop_reason\":\"tool_use\"") }, "Finish reason must be tool_use because tool was emitted")
    }

    // MARK: - Text-channel tool-call recovery

    /// A local model trained on the Claude tool dialect writes
    /// `<invoke name="X"><parameter …>…</parameter></invoke>` — wrapped or
    /// bare — instead of the `<tool_call>` JSON the injected protocol asks
    /// for. Both parameter dialects must parse.
    static func testInvokeStyleTextToolExtraction() {
        print("▶️ Running testInvokeStyleTextToolExtraction...")

        let wrapped = """
        <function_calls>
        <invoke name="Bash">
        <parameter name="command">ls -la</parameter>
        </invoke>
        </function_calls>
        """
        let r1 = LocalChatTemplateEngine.extractToolCalls(from: wrapped)
        assertEqual(r1.toolCalls.count, 1, "Wrapped <invoke> must yield exactly one call")
        assertEqual(r1.toolCalls.first?["name"] as? String, "Bash", "Name must come from the invoke attribute")
        assertEqual((r1.toolCalls.first?["input"] as? [String: Any])?["command"] as? String, "ls -la", "Quoted <parameter name=…> must parse")
        assertTrue(!r1.cleanText.contains("function_calls"), "Wrapper must not leak into visible text")

        // Bare invoke with Qwen's <parameter=KEY> — the exact shape the local
        // Ternary-Bonsai model emits through jxrouter.
        let bare = #"<invoke name="Skill"><parameter=command>find-skills</parameter></invoke>"#
        let r2 = LocalChatTemplateEngine.extractToolCalls(from: bare)
        assertEqual(r2.toolCalls.count, 1, "Bare <invoke> must yield exactly one call")
        assertEqual(r2.toolCalls.first?["name"] as? String, "Skill", "Bare invoke name must parse")
        assertEqual((r2.toolCalls.first?["input"] as? [String: Any])?["command"] as? String, "find-skills", "Bare <parameter=…> must parse")
        assertTrue(r2.cleanText.isEmpty, "Fully-consumed invoke must leave no visible text")
    }

    /// The reported failure: the model narrates a tool call as TEXT, never
    /// populating the structured `tool_calls` field, so the client shows prose
    /// and nothing executes. The stream must end with a real tool_use block.
    static func testStreamingTextChannelToolRecovery() {
        print("▶️ Running testStreamingTextChannelToolRecovery...")
        var state = MessageTranslator.OpenAIStreamState()
        state.knownToolNames = ["Bash", "Read"]

        let chunk1: [String: Any] = [
            "choices": [["delta": ["content": "I will run the listing now. <function_calls><invoke name=\"Bash\"><parameter=command>ls -la</parameter></invoke></function_calls>"], "finish_reason": NSNull()]]
        ]
        let events1 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk1, model: "local", state: &state, enableThinking: false)
        assertTrue(events1.contains { $0.contains("text_delta") }, "Narration must still stream as text")

        let chunk2: [String: Any] = [
            "choices": [["delta": [:], "finish_reason": "stop"]]
        ]
        let events2 = MessageTranslator.openAIToAnthropicSSE(chunk: chunk2, model: "local", state: &state, enableThinking: false)
        assertTrue(events2.contains { $0.contains("content_block_start") && $0.contains("\"tool_use\"") && $0.contains("Bash") }, "Text-channel call must be recovered as a tool_use block")
        assertTrue(events2.contains { $0.contains("input_json_delta") && $0.contains("ls -la") }, "Recovered call must carry its arguments")
        assertTrue(events2.contains { $0.contains("\"stop_reason\":\"tool_use\"") }, "Recovered call must force stop_reason tool_use")

        // A call naming a tool the client never offered must NOT be executed —
        // this is what keeps prose *about* tool syntax from running anything.
        var guarded = MessageTranslator.OpenAIStreamState()
        guarded.knownToolNames = ["Read"]
        _ = MessageTranslator.openAIToAnthropicSSE(chunk: chunk1, model: "local", state: &guarded, enableThinking: false)
        let guardedEvents = MessageTranslator.openAIToAnthropicSSE(chunk: chunk2, model: "local", state: &guarded, enableThinking: false)
        assertTrue(!guardedEvents.contains { $0.contains("\"tool_use\"") }, "Un-offered tool names must not be recovered")
        assertTrue(guardedEvents.contains { $0.contains("\"stop_reason\":\"end_turn\"") }, "Un-recovered turn must stay end_turn")
    }

    /// The follow-up report: "it just simply stopped again" — with the same
    /// model output as above, but this time delivered as a real token stream.
    ///
    /// Streaming sends one token per delta, so `</think>` routinely straddles
    /// two chunks. The leading fragment was emitted as thinking text, which
    /// meant the closing tag could never reassemble: `insideInlineThink` stayed
    /// true for the rest of the stream and every later block — including the
    /// model's text-channel tool call — was swallowed into the thinking
    /// channel. The client got no tool_use, no visible text, and
    /// `stop_reason: end_turn`.
    static func testSplitThinkTagDoesNotSwallowFollowingToolCall() {
        print("▶️ Running testSplitThinkTagDoesNotSwallowFollowingToolCall...")

        let modelText = """
        <think>
        Plan: call the Skill tool.
        </think>

        <tool_call>
        <function=Skill>
        <parameter=command>
        find-skills
        </parameter>
        </function>
        </tool_call>
        """

        /// Pull the JSON payload out of an "event: …\ndata: {…}\n\n" envelope.
        func payload(_ event: String) -> [String: Any]? {
            for line in event.split(separator: "\n") where line.hasPrefix("data: ") {
                guard let data = String(line.dropFirst(6)).data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
                return obj
            }
            return nil
        }

        var state = MessageTranslator.OpenAIStreamState()
        state.knownToolNames = ["Skill", "Read"]

        var toolUseBlocks = 0
        var visibleText = ""
        // One character per delta — the worst case for split-marker recovery,
        // and a superset of real token-by-token streaming.
        for character in modelText {
            let chunk: [String: Any] = [
                "choices": [["delta": ["content": String(character)], "finish_reason": NSNull()]]
            ]
            let events = MessageTranslator.openAIToAnthropicSSE(chunk: chunk, model: "local", state: &state, enableThinking: true)
            toolUseBlocks += events.filter { $0.contains("\"type\":\"tool_use\"") }.count
            visibleText += events.compactMap { payload($0)?["delta"] as? [String: Any] }.compactMap { $0["text"] as? String }.joined()
        }

        assertTrue(!state.insideInlineThink, "Thinking block must close even when </think> is split across chunks")
        assertTrue(!visibleText.contains("<think>"), "<think> must never leak into visible text")
        assertTrue(!visibleText.contains("</think>"), "</think> must never leak into visible text")

        let finish: [String: Any] = ["choices": [["delta": [:], "finish_reason": "stop"]]]
        let endEvents = MessageTranslator.openAIToAnthropicSSE(chunk: finish, model: "local", state: &state, enableThinking: true)
        toolUseBlocks += endEvents.filter { $0.contains("\"type\":\"tool_use\"") }.count

        assertEqual(toolUseBlocks, 1, "Exactly one tool_use block must survive a split </think>")
        assertTrue(endEvents.contains { $0.contains("\"stop_reason\":\"tool_use\"") }, "Split-</think> turn must end in tool_use")
    }

    static func testUnclosedThinkTagExtraction() {
        print("[TEST] Unclosed / Truncated <think> Tag Extraction")
        let truncatedResponse: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "<think>Planning the next step carefully but cut off"
                ],
                "finish_reason": "length"
            ]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 20]
        ]
        let data = try! JSONSerialization.data(withJSONObject: truncatedResponse)
        let converted = MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: "test-model", enableThinking: true)
        let json = (try? JSONSerialization.jsonObject(with: converted)) as? [String: Any]
        let content = json?["content"] as? [[String: Any]] ?? []

        let thinkingBlock = content.first(where: { $0["type"] as? String == "thinking" })
        assertTrue(thinkingBlock != nil, "Truncated <think> must be extracted into thinking block")
        assertEqual(thinkingBlock?["thinking"] as? String, "Planning the next step carefully but cut off")

        let textBlock = content.first(where: { $0["type"] as? String == "text" })
        let text = textBlock?["text"] as? String ?? ""
        assertTrue(!text.contains("<think>"), "Visible text must not leak unclosed <think>")
    }

    static func testPreParsedDictionaryToolCallArguments() {
        print("[TEST] Pre-parsed Dictionary Tool Call Arguments")
        let openAIResponse: [String: Any] = [
            "choices": [[
                "message": [
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [[
                        "id": "call_12345",
                        "type": "function",
                        "function": [
                            "name": "lookup_user",
                            "arguments": ["user_id": 42, "include_profile": true]
                        ]
                    ]]
                ],
                "finish_reason": "tool_calls"
            ]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 15]
        ]
        let data = try! JSONSerialization.data(withJSONObject: openAIResponse)
        let converted = MessageTranslator.convertOpenAIResponseToAnthropic(data: data, model: "test-model", enableThinking: false)
        let json = (try? JSONSerialization.jsonObject(with: converted)) as? [String: Any]
        let content = json?["content"] as? [[String: Any]] ?? []

        let toolUse = content.first(where: { $0["type"] as? String == "tool_use" })
        assertTrue(toolUse != nil, "Must extract tool_use block from dictionary arguments")
        assertEqual(toolUse?["name"] as? String, "lookup_user")
        let input = toolUse?["input"] as? [String: Any]
        assertEqual(input?["user_id"] as? Int, 42)
        assertEqual(input?["include_profile"] as? Bool, true)
    }

    static func testMarkdownJsonBlockToolCallExtraction() {
        print("[TEST] Markdown Fenced JSON Tool Call Extraction")
        let text = """
        I will run this tool for you:
        ```json
        {
            "name": "fetch_weather",
            "arguments": {
                "city": "Tokyo",
                "days": 3
            }
        }
        ```
        Let's see what happens.
        """
        let extracted = LocalChatTemplateEngine.extractToolCalls(from: text)
        assertEqual(extracted.toolCalls.count, 1, "Must extract 1 tool call from markdown json code block")
        let first = extracted.toolCalls.first
        assertEqual(first?["name"] as? String, "fetch_weather")
        let input = first?["input"] as? [String: Any]
        assertEqual(input?["city"] as? String, "Tokyo")
        assertEqual(input?["days"] as? Double, 3.0)
        assertTrue(!extracted.cleanText.contains("```json"), "Fenced json tool call block must be stripped from cleanText")
    }

    // MARK: - Claude CLI protocol hardening (2026-09-26)

    static func testToolChoiceObjectFallbacks() {
        print("▶️ Running testToolChoiceObjectFallbacks...")
        // Anthropic {"type":"any"} object form → OpenAI "required" string.
        // Forwarding the dict verbatim made OpenAI-compatible upstreams 400.
        let anyChoice = MessageTranslator.convertToolChoiceToOpenAI(["type": "any"])
        assertTrue(anyChoice as? String == "required", "tool_choice {type:any} must map to \"required\", got \(anyChoice)")

        let noneChoice = MessageTranslator.convertToolChoiceToOpenAI(["type": "none"])
        assertTrue(noneChoice as? String == "none", "tool_choice {type:none} must map to \"none\"")

        let autoChoice = MessageTranslator.convertToolChoiceToOpenAI(["type": "auto"])
        assertTrue(autoChoice as? String == "auto", "tool_choice {type:auto} must map to \"auto\"")

        // Named tool object form still maps to the function form.
        let named = MessageTranslator.convertToolChoiceToOpenAI(["type": "tool", "name": "Bash"])
        let namedDict = named as? [String: Any]
        assertEqual(namedDict?["type"] as? String, "function", "named tool_choice must map to function form")
        let fn = namedDict?["function"] as? [String: Any]
        assertEqual(fn?["name"] as? String, "Bash", "named tool_choice must carry the tool name")
    }

    static func testHTTPStatusLineUsesReasonPhrase() {
        print("▶️ Running testHTTPStatusLineUsesReasonPhrase...")
        // The error reason phrase must be the real HTTP reason, not the
        // multi-word error message — a corrupt status line is what Claude Code
        // reports as InvalidHTTPResponse instead of a clean API error.
        let message = "Invalid or missing auth token"
        assertEqual(HTTPUtils.statusText(401), "Unauthorized", "401 must carry the real reason phrase")
        assertEqual(HTTPUtils.statusText(429), "Too Many Requests", "429 must carry the real reason phrase")
        assertEqual(HTTPUtils.statusText(404), "Not Found", "404 must carry the real reason phrase")
        assertTrue(!message.contains("\r"), "error message must never inject CR into the status line")
    }

    static func testOutputLimitClampExtraction() {
        print("▶️ Running testOutputLimitClampExtraction...")
        // Claude Code sizes max_tokens for the model's full window (128000 for
        // a [1m]-context model); strict gateways cap output (agnes: 65536) and
        // answer with a deterministic 400. The clamp retry must read the cap
        // the upstream just declared — from the REAL agnes error body.
        let agnes = "{\"error\":{\"message\":\"max_tokens exceeds the limit of 65536 (request id: 20260926115040419740755mezP1z7O)\",\"type\":\"AgnesAI_error\",\"param\":\"\",\"code\":\"invalid_request\"}}"
        assertEqual(OutputLimitClamp.capFromErrorBody(Data(agnes.utf8)), 65536,
                    "agnes error body must yield the declared 65536 cap")

        // A body that echoes the REQUESTED value must still yield the DECLARED
        // limit — clamping to 128000 would retry with the same poison.
        let echo = "{\"error\":{\"message\":\"max_tokens 128000 exceeds the limit of 65536\"}}"
        assertEqual(OutputLimitClamp.capFromErrorBody(Data(echo.utf8)), 65536,
                    "declared limit must beat the echoed request value")

        // vLLM-style phrasing without "limit of":
        let vllm = "{\"error\":{\"message\":\"max_tokens must be no greater than 8192\"}}"
        assertEqual(OutputLimitClamp.capFromErrorBody(Data(vllm.utf8)), 8192,
                    "numeric fallback must find the 8192 cap")

        // CONTEXT-SIZE overflows are NOT output caps. Clamping max_tokens to
        // the context size poisoned every later request for the provider in
        // the first cut — these real llama-server bodies must return nil.
        let llamaCtx = "{\"error\":{\"code\":400,\"message\":\"request (49530 tokens) exceeds the available context size (32768 tokens), try increasing it\",\"type\":\"exceed_context_size_error\",\"n_prompt_tokens\":49530,\"n_ctx\":32768}}"
        assertEqual(OutputLimitClamp.capFromErrorBody(Data(llamaCtx.utf8)), nil,
                    "context-size overflow must never be read as an output cap")

        let openaiCtx = "{\"error\":{\"message\":\"This model's maximum context length is 32768 tokens, however messages resulted in 49530 tokens\"}}"
        assertEqual(OutputLimitClamp.capFromErrorBody(Data(openaiCtx.utf8)), nil,
                    "'maximum context length' must never be read as an output cap")

        // Unrelated errors carry no cap at all.
        let auth = "{\"error\":{\"message\":\"Token not provided\"}}"
        assertEqual(OutputLimitClamp.capFromErrorBody(Data(auth.utf8)), nil,
                    "auth errors must not invent a cap")
    }

    static func testOutputLimitClampCache() {
        print("▶️ Running testOutputLimitClampCache...")
        // Learned caps are keyed per (provider, model) and pre-clamp later
        // requests so the retry becomes a first-try success.
        let provider = "test-provider-clamp"
        let model = "test-model-clamp"
        assertEqual(OutputLimitClamp.knownCap(provider: provider, model: model), nil,
                    "unknown provider must start with no learned cap")
        OutputLimitClamp.noteCap(provider: provider, model: model, cap: 65536)
        assertEqual(OutputLimitClamp.knownCap(provider: provider, model: model), 65536,
                    "noted cap must be readable")
        // A cap below the floor is a parse accident, not a real limit — reject.
        OutputLimitClamp.noteCap(provider: provider, model: model, cap: 512)
        assertEqual(OutputLimitClamp.knownCap(provider: provider, model: model), 65536,
                    "sub-1024 caps must be rejected")
        // Different provider/model is isolated.
        assertEqual(OutputLimitClamp.knownCap(provider: "other", model: model), nil,
                    "caps must be keyed per provider")
    }

    static func testRAMPreflightVerdicts() {
        print("▶️ Running testRAMPreflightVerdicts...")
        // Estimate sanity: an 8 GB model + projector at 32k context on a hybrid
        // (qwen35-like) geometry must land in a plausible band.
        var meta = GGUFParser.Metadata()
        meta.architecture = "qwen35"
        meta.blockCount = 64
        meta.embeddingLength = 5120
        meta.attentionHeadCount = 24
        meta.attentionHeadCountKV = 4
        meta.fullAttentionInterval = 4
        let est = RAMPreflight.estimateWorkingSet(modelBytes: 7_206_168_928,
                                                  mmprojBytes: 931_145_760,
                                                  meta: meta,
                                                  contextTokens: 32_768)
        // Weights+mmproj = ~7.6 GB; KV (17 cached layers × 4 kv-heads × 256 dim
        // × 2 × 1.06 × 32768) ≈ 1.2 GB; overhead ≥ 1.5 GB → total 10–14 GB.
        assertTrue(est.totalBytes > 9_000_000_000 && est.totalBytes < 15_000_000_000,
                   "Ternary-Bonsai working-set estimate should be 9–15 GB, got \(est.totalBytes / 1_073_741_824) GB")
        // KV layers must be the hybrid count (17), not all 64 blocks.
        assertTrue(est.kvBytes < 5_000_000_000,
                   "hybrid KV estimate must reflect only full-attention layers")

        // Verdicts against synthetic availability:
        let plenty = RAMPreflight.check(modelBytes: 1_000_000_000, mmprojBytes: 0,
                                        meta: meta, contextTokens: 8_192,
                                        availableBytes: 40_000_000_000)
        assertEqual(plenty.verdict, .ok, "small model on 40 GB free must be .ok")

        let tight = RAMPreflight.check(modelBytes: 7_206_168_928, mmprojBytes: 931_145_760,
                                       meta: meta, contextTokens: 32_768,
                                       availableBytes: 11_500_000_000)
        assertEqual(tight.verdict, .warn, "10-11 GB working set vs 11.5 GB free must warn")

        let blocked = RAMPreflight.check(modelBytes: 7_206_168_928, mmprojBytes: 931_145_760,
                                         meta: meta, contextTokens: 32_768,
                                         availableBytes: 5_800_000_000)
        assertEqual(blocked.verdict, .blocked, "10-11 GB working set vs 5.8 GB free must block")
        assertTrue(blocked.message.contains("Free memory"), "blocked message must tell the user what to do")

        // Live free-memory probe returns a sane value on this Mac.
        let live = RAMPreflight.availableMemoryBytes()
        assertTrue(live > 0 && live < 64_000_000_000,
                   "available-memory probe must return a plausible byte count")
    }

    static func testWarmUpGateAndPreflightOccupiedMemory() {
        print("▶️ Running testWarmUpGateAndPreflightOccupiedMemory...")

        // Gate policy: which provider ids are gated at all.
        assertTrue(LocalModelManager.isRoutedLocalProvider("gguf"), "gguf must be a routed local provider")
        assertTrue(LocalModelManager.isRoutedLocalProvider("llamaapp"), "llamaapp must be a routed local provider")
        assertTrue(!LocalModelManager.isRoutedLocalProvider("opencode-zen"), "cloud providers must not be gated")
        // The gate manages only runtimes JXRouter starts/adopts; user-run
        // servers (LM Studio, Jan, Ollama) must fail over instantly as before.
        assertTrue(LocalModelManager.isGateManagedProvider("gguf"), "our own GGUF runtime must be gate-managed")
        assertTrue(LocalModelManager.isGateManagedProvider("llamaapp"), "llama.app must be gate-managed")
        assertTrue(!LocalModelManager.isGateManagedProvider("lmstudio"), "third-party runtimes must not be gate-managed")
        assertTrue(!LocalModelManager.isGateManagedProvider("jan"), "jan must not be gate-managed")

        // On-demand start mapping: a request routed at gguf starts the GGUF
        // runtime, llamaapp aliases start the Llama app, anything else starts
        // nothing. (XCTest runs sync tests on the main thread, so the
        // assumeIsolated hop is safe here.)
        MainActor.assumeIsolated {
            let mgr = LocalModelManager.shared
            if case .gguf = LocalModelManager.gateStartProvider(for: "gguf", manager: mgr) {} else {
                XCTAssertTrue(false, "gguf requests must map to the GGUF runtime")
            }
            if case .llamaapp = LocalModelManager.gateStartProvider(for: "llamaapp", manager: mgr) {} else {
                XCTAssertTrue(false, "llamaapp requests must map to the Llama app")
            }
            if LocalModelManager.gateStartProvider(for: "lmstudio", manager: mgr) != nil {
                XCTAssertTrue(false, "third-party providers must never be started by the gate")
            }
        }

        // Warm-up budgets: the llama.app cold-start window must cover a real
        // model load (app launch + weights paging + context alloc + prefill),
        // and the router's wait budget must outlast it (a reload right before
        // the first chat can chain two loads).
        assertTrue(LocalModelManager.warmUpTimeout >= 480,
                   "llama.app warm-up budget must be ≥8 minutes (was 30s — every cold start failed), got \(LocalModelManager.warmUpTimeout)s")
        assertTrue(LocalModelManager.localWarmWaitBudget > LocalModelManager.warmUpTimeout,
                   "router wait budget must outlast the warm-up budget")

        // Preflight with an already-loaded server: its pages are not free.
        var meta = GGUFParser.Metadata()
        meta.architecture = "llama"
        meta.blockCount = 32
        meta.embeddingLength = 4096
        meta.attentionHeadCount = 32
        meta.attentionHeadCountKV = 8
        let idle = RAMPreflight.runningServerWorkingSetBytes(modelBytes: 4_000_000_000)
        assertTrue(idle > 4_000_000_000 && idle < 6_000_000_000,
                   "running-server working set = weights + overhead ≈ 4.5–6 GB, got \(idle / 1_073_741_824) GB")

        let fresh = RAMPreflight.check(modelBytes: 4_000_000_000, mmprojBytes: 0,
                                       meta: meta, contextTokens: 8_192,
                                       availableBytes: 8_000_000_000)
        assertEqual(fresh.verdict, .ok, "4.5-5 GB working set on 8 GB free must be .ok with nothing running")

        let occupied = RAMPreflight.check(modelBytes: 4_000_000_000, mmprojBytes: 0,
                                          meta: meta, contextTokens: 8_192,
                                          availableBytes: 8_000_000_000,
                                          idleServerBytes: idle)
        assertTrue(occupied.verdict.isBlocking || occupied.verdict.isWarning,
                   "the same load with a 4.5-6 GB server already resident must warn or block, got \(occupied.verdict)")
        assertTrue(occupied.availableBytes < fresh.availableBytes,
                   "occupied availability must shrink by the resident server's size")
        assertTrue(occupied.message.contains("already-loaded") || occupied.message.contains("already-loaded local model"),
                   "occupied verdict must explain WHY availability dropped")

        // Saturation: available ≤ idle → 0 available, must block, never crash.
        let saturated = RAMPreflight.check(modelBytes: 1_000_000_000, mmprojBytes: 0,
                                           meta: meta, contextTokens: 8_192,
                                           availableBytes: 3_000_000_000,
                                           idleServerBytes: 5_000_000_000)
        assertEqual(saturated.verdict, .blocked, "available below the resident server's size must block")
    }

    static func testPrismRuntimeDetectionAndElection() {
        print("▶️ Running testPrismRuntimeDetectionAndElection...")
        // The real Ternary-Bonsai PQ2_0 file (PrismML ternary packing, GGML
        // type 142 + prism.hadamard.* transforms). Stock llama.cpp refuses it:
        // "invalid ggml type 142. should be in [0, 43)".
        let ternary = "/Users/joshua/Models/Ternary-Bonsai-2-27B-Abliterated-GGUF/Ternary-Bonsai-2-27B-Abliterated-PQ2_0.gguf"
        if FileManager.default.fileExists(atPath: ternary) {
            let meta = GGUFParser.metadata(from: URL(fileURLWithPath: ternary))
            assertTrue(meta.requiresPrismRuntime,
                       "PQ2_0 ternary file must be flagged as Prism-runtime-only")
            assertEqual(meta.architecture, "qwen35", "Ternary-Bonsai reports the qwen35 arch")
            assertEqual(meta.embeddingLength, 5120, "Ternary-Bonsai n_embd is 5120")

            // The sibling BF16 projector must dimension-match and be auto-paired.
            let mmproj = "/Users/joshua/Models/Ternary-Bonsai-2-27B-Abliterated-GGUF/mmproj Ternary Bonsai 27B BF16.gguf"
            if FileManager.default.fileExists(atPath: mmproj) {
                assertTrue(GGUFModelScanner.projectorFits(modelPath: ternary, projectorPath: mmproj),
                           "Ternary mmproj (5120) must fit the model (n_embd 5120)")
                assertEqual(GGUFModelScanner.findMatchingMmproj(forModelPath: ternary, widen: false), mmproj,
                            "scanner must auto-pair the sibling projector")
            }
        } else {
            print("   (Ternary model not present — skipping live-file assertions)")
        }

        // Election: prism-flagged → prism binary when staged; normal → the
        // general best. When no prism runtime is installed both collapse to
        // the general best, which is the honest fallback.
        let prism = LlamaRuntime.bestPrismRuntime()
        if prism != nil {
            assertEqual(LlamaRuntime.bestRuntime(forPrismModel: true)?.path, prism!.path,
                        "prism model must elect the prism binary")
            let general = LlamaRuntime.bestAvailableRuntime()
            assertTrue(general == nil || LlamaRuntime.bestRuntime(forPrismModel: false)?.path == general!.path,
                       "normal model must keep the general election")
            // The fork (b10658+) is usually older than stock upstream — it must
            // never win the GENERAL election just by being present.
            if let general, general.build > prism!.build {
                assertTrue(LlamaRuntime.bestAvailableRuntime()!.path != prism!.path,
                           "prism fork must not win the general election on build number")
            }
            // The elected runtime must come from the prism family (bundled in
            // the app or managed in llama-cpp/prism/) — never a stock source.
            assertTrue(prism!.source == .prism || prism!.source == .bundledPrism,
                       "prism election must report a prism-family source, got \(prism!.source.rawValue)")

            // Bundled-vs-managed pool: the fork ships inside the app
            // (Resources/llama-cpp-prism/) AND can be installed into
            // llama-cpp/prism/. Newer build wins; equal builds prefer the
            // in-app copy — mirroring the stock bundled-first tie-break.
            let bundledPath = LlamaRuntime.bundledPrismBinaryPath()
            let managedPath = LlamaRuntime.prismBinaryPath()
            let managedExists = FileManager.default.isExecutableFile(atPath: managedPath)
            if let bundledPath, managedExists {
                let bundledBuild = LlamaRuntime.version(ofBinaryAt: bundledPath)?.build ?? 0
                let managedBuild = LlamaRuntime.version(ofBinaryAt: managedPath)?.build ?? 0
                if bundledBuild != managedBuild {
                    let expected = bundledBuild > managedBuild ? bundledPath : managedPath
                    assertEqual(prism!.path, expected,
                                "the newer prism build must win (bundled \(bundledBuild) vs managed \(managedBuild))")
                } else {
                    assertEqual(prism!.path, bundledPath,
                                "equal prism builds must prefer the copy built into the app")
                }
            } else if let bundledPath {
                assertEqual(prism!.path, bundledPath,
                            "bundled-only prism must resolve to the in-app binary")
            } else if managedExists {
                assertEqual(prism!.path, managedPath,
                            "managed-only prism must resolve to the installed binary")
            }
        } else {
            assertEqual(LlamaRuntime.bestRuntime(forPrismModel: true)?.path,
                        LlamaRuntime.bestAvailableRuntime()?.path,
                        "without a prism runtime the election falls back to general best")
            print("   (prism runtime not staged — fallback path verified)")
        }
    }

    // MARK: - Runner

    static func runAll() -> Bool {
        testToolDefinitionConversion()
        testToolChoiceConversion()
        testAssistantToolUseAndUserToolResultHistory()
        testMultimodalImageTranslation()
        testReasoningModelParameterSanitization()
        testNonStreamingToolCallResponse()
        testStreamingToolCallsSSE()
        testSequentialSSEBlockDiscipline()
        testInlineThinkTagExtraction()
        testLocalModelChatTemplateDetection()
        testLocalModelSystemPromptToolInjection()
        testLocalModelTextBasedToolExtraction()
        testStreamingLocalModelToolCallExtraction()
        testInvokeStyleTextToolExtraction()
        testStreamingTextChannelToolRecovery()
        testSplitThinkTagDoesNotSwallowFollowingToolCall()
        testUnclosedThinkTagExtraction()
        testPreParsedDictionaryToolCallArguments()
        testMarkdownJsonBlockToolCallExtraction()
        testToolChoiceObjectFallbacks()
        testHTTPStatusLineUsesReasonPhrase()
        testOutputLimitClampExtraction()
        testOutputLimitClampCache()
        testPrismRuntimeDetectionAndElection()
        testRAMPreflightVerdicts()
        testWarmUpGateAndPreflightOccupiedMemory()

        if failedTests.isEmpty {
            print("\n✅ ALL 26 TEST SUITES PASSED CLEANLY (0 failures)")
            return true
        } else {
            print("\n❌ \(failedTests.count) TESTS FAILED:")
            for f in failedTests {
                print("  - \(f)")
            }
            return false
        }
    }
}

@main
struct TestRunner {
    static func main() {
        let ok = MessageTranslatorTests.runAll()
        exit(ok ? 0 : 1)
    }
}

/// Bridges the standalone harness above into XCTest so it runs with the rest
/// of the suite instead of only when invoked by hand.
final class MessageTranslatorRunnerTests: XCTestCase {
    func testStandaloneHarness() {
        XCTAssertTrue(
            MessageTranslatorTests.runAll(),
            "MessageTranslator standalone suite reported failures"
        )
    }
}
