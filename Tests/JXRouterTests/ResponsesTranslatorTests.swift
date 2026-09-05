import XCTest
@testable import JXRouter

/// Tests for the ResponsesTranslator that converts between OpenAI Responses
/// API format and Chat Completions format.
final class ResponsesTranslatorTests: XCTestCase {

    // MARK: - toChatCompletions

    func testToChatCompletionsMapsModel() {
        let input: [String: Any] = ["model": "gpt-4o"]
        let result = ResponsesTranslator.toChatCompletions(input)
        XCTAssertEqual(result["model"] as? String, "gpt-4o")
    }

    func testToChatCompletionsMapsInstructionsToSystemMessage() {
        let input: [String: Any] = [
            "model": "gpt-4o",
            "instructions": "You are a helpful assistant.",
        ]
        let result = ResponsesTranslator.toChatCompletions(input)
        let messages = result["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.first?["content"] as? String, "You are a helpful assistant.")
    }

    func testToChatCompletionsMapsStringInput() {
        let input: [String: Any] = [
            "model": "gpt-4o",
            "input": "Hello, world!",
        ]
        let result = ResponsesTranslator.toChatCompletions(input)
        let messages = result["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
        XCTAssertEqual(messages?.last?["content"] as? String, "Hello, world!")
    }

    func testToChatCompletionsMapsArrayInput() {
        let input: [String: Any] = [
            "model": "gpt-4o",
            "input": [
                ["role": "user", "content": "What is 2+2?"],
                ["role": "assistant", "content": "4"],
                ["role": "user", "content": "And 3+3?"],
            ],
        ]
        let result = ResponsesTranslator.toChatCompletions(input)
        let messages = result["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        XCTAssertEqual(messages?.count, 3)
        XCTAssertEqual(messages?.first?["content"] as? String, "What is 2+2?")
    }

    func testToChatCompletionsCombinesInstructionsAndInput() {
        let input: [String: Any] = [
            "model": "gpt-4o",
            "instructions": "Be concise.",
            "input": "Hi!",
        ]
        let result = ResponsesTranslator.toChatCompletions(input)
        let messages = result["messages"] as? [[String: Any]]
        XCTAssertNotNil(messages)
        XCTAssertEqual(messages?.count, 2)
        XCTAssertEqual(messages?.first?["role"] as? String, "system")
        XCTAssertEqual(messages?.last?["role"] as? String, "user")
    }

    func testToChatCompletionsMapsStream() {
        let input: [String: Any] = ["model": "gpt-4o", "stream": true]
        let result = ResponsesTranslator.toChatCompletions(input)
        XCTAssertEqual(result["stream"] as? Bool, true)
    }

    func testToChatCompletionsMapsMaxOutputTokens() {
        let input: [String: Any] = ["model": "gpt-4o", "max_output_tokens": 1024]
        let result = ResponsesTranslator.toChatCompletions(input)
        XCTAssertEqual(result["max_tokens"] as? Int, 1024)
    }

    func testToChatCompletionsHandlesEmptyInput() {
        let input: [String: Any] = [:]
        let result = ResponsesTranslator.toChatCompletions(input)
        // Should return a valid (possibly empty) dictionary without crashing.
        XCTAssertNotNil(result)
    }

    // MARK: - toResponses

    func testToResponsesMapsChoicesToOutput() {
        let chatJSON: [String: Any] = [
            "choices": [
                ["message": ["content": "The answer is 42."]],
            ],
        ]
        let result = ResponsesTranslator.toResponses(chatJSON, model: "gpt-4o")
        XCTAssertEqual(result["object"] as? String, "response")
        XCTAssertEqual(result["status"] as? String, "completed")
        XCTAssertEqual(result["model"] as? String, "gpt-4o")

        let output = result["output"] as? [[String: Any]]
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.count, 1)
        XCTAssertEqual(output?.first?["type"] as? String, "message")

        let content = output?.first?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.first?["text"] as? String, "The answer is 42.")
    }

    func testToResponsesHandlesEmptyChoices() {
        let chatJSON: [String: Any] = ["choices": []]
        let result = ResponsesTranslator.toResponses(chatJSON, model: "gpt-4o")
        let output = result["output"] as? [[String: Any]]
        XCTAssertNotNil(output)
        XCTAssertEqual(output?.count, 0)
    }

    func testToResponsesGeneratesUniqueId() {
        let chatJSON: [String: Any] = [
            "choices": [["message": ["content": "Hello"]]],
        ]
        let result1 = ResponsesTranslator.toResponses(chatJSON, model: "gpt-4o")
        let result2 = ResponsesTranslator.toResponses(chatJSON, model: "gpt-4o")
        XCTAssertNotEqual(result1["id"] as? String, result2["id"] as? String,
                          "Each response should have a unique ID")
    }

    func testToResponsesPreservesModel() {
        let chatJSON: [String: Any] = [
            "choices": [["message": ["content": "test"]]],
        ]
        let result = ResponsesTranslator.toResponses(chatJSON, model: "claude-3-opus")
        XCTAssertEqual(result["model"] as? String, "claude-3-opus")
    }

    func testToResponsesHandlesMissingMessageContent() {
        let chatJSON: [String: Any] = [
            "choices": [["message": ["role": "assistant"]]],
        ]
        let result = ResponsesTranslator.toResponses(chatJSON, model: "gpt-4o")
        let output = result["output"] as? [[String: Any]]
        // No content string → no output entry.
        XCTAssertEqual(output?.count, 0)
    }
}
