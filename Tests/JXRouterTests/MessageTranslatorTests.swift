import Foundation

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

        if failedTests.isEmpty {
            print("\n✅ ALL 13 TEST SUITES PASSED CLEANLY (0 failures)")
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
