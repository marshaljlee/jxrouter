import XCTest
@testable import JXRouter

/// Tests for the RequestClassifier that decides whether an HTTP request
/// should be routed through JXProxy's AI providers, passed through directly,
/// or passed through OpenAI without interception.
final class RequestClassifierTests: XCTestCase {

    // MARK: - Known AI hosts

    func testAnthropicIsRouted() {
        let classifier = RequestClassifier(routeOpenAI: true)
        XCTAssertEqual(classifier.classify(host: "api.anthropic.com"), .routeAI)
    }

    func testOpenAIRoutedWhenEnabled() {
        let classifier = RequestClassifier(routeOpenAI: true)
        XCTAssertEqual(classifier.classify(host: "api.openai.com"), .routeAI)
    }

    func testOpenAIPassThroughWhenDisabled() {
        let classifier = RequestClassifier(routeOpenAI: false)
        XCTAssertEqual(classifier.classify(host: "api.openai.com"), .passThroughOpenAI)
    }

    func testDeepSeekIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.deepseek.com"), .routeAI)
    }

    func testOpenRouterIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.openrouter.ai"), .routeAI)
    }

    func testNvidiaIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "integrate.api.nvidia.com"), .routeAI)
    }

    func testMistralIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.mistral.ai"), .routeAI)
    }

    func testCodestralIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "codestral.mistral.ai"), .routeAI)
    }

    func testGroqIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.groq.com"), .routeAI)
    }

    func testFireworksIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.fireworks.ai"), .routeAI)
    }

    func testSambaNovaIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.sambanova.ai"), .routeAI)
    }

    func testCerebrasIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.cerebras.ai"), .routeAI)
    }

    func testHuggingFaceIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "router.huggingface.co"), .routeAI)
    }

    func testXAIIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.x.ai"), .routeAI)
    }

    func testCohereIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.cohere.ai"), .routeAI)
    }

    func testOpenCodeIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "opencode.ai"), .routeAI)
    }

    func testAntigravityIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.antigravity.dev"), .routeAI)
    }

    func testGeminiIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "generativelanguage.googleapis.com"), .routeAI)
    }

    // MARK: - Non-AI hosts

    func testGitHubIsPassthrough() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "api.github.com"), .passthrough)
    }

    func testAppleIsPassthrough() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "apple.com"), .passthrough)
    }

    func testGoogleIsPassthrough() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "www.google.com"), .passthrough)
    }

    // MARK: - Host name heuristic

    func testHostnameContainingAnthropicIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "my-custom-anthropic-proxy.example.com"), .routeAI)
    }

    func testHostnameContainingOpenAIIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "my-openai-proxy.example.com"), .routeAI)
    }

    func testHostnameContainingGeminiIsRouted() {
        let classifier = RequestClassifier()
        XCTAssertEqual(classifier.classify(host: "gemini-backend.example.com"), .routeAI)
    }

    // MARK: - isOpenAIHost static method

    func testIsOpenAIHostReturnsTrueForApiOpenAI() {
        XCTAssertTrue(RequestClassifier.isOpenAIHost("api.openai.com"))
    }

    func testIsOpenAIHostReturnsFalseForOtherHosts() {
        XCTAssertFalse(RequestClassifier.isOpenAIHost("api.anthropic.com"))
        XCTAssertFalse(RequestClassifier.isOpenAIHost("api.deepseek.com"))
        XCTAssertFalse(RequestClassifier.isOpenAIHost("openai.example.com"))
    }
}
