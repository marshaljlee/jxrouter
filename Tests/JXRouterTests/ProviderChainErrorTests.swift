import XCTest
@testable import JXRouter

final class ProviderChainErrorTests: XCTestCase {

    func testRateLimitIsSurfacedOverLastFallback() {
        // The real-world case: primary rate-limited (429), local fallback
        // rejects the model name (400). The message must call out the 429.
        let msg = ProviderChainError.chainFailureMessage(
            [("opencode-zen", 429), ("nvidia-nim", 429), ("llamaapp", 400)],
            lastError: nil
        )
        XCTAssertTrue(msg.contains("429"), "should surface the rate limit, got: \(msg)")
        XCTAssertTrue(msg.contains("opencode-zen"))
        XCTAssertTrue(msg.contains("nvidia-nim"))
    }

    func testAuthFailureIsSurfaced() {
        let msg = ProviderChainError.chainFailureMessage(
            [("direct", 401), ("openrouter", 400)],
            lastError: nil
        )
        XCTAssertTrue(msg.contains("Authentication failed"))
        XCTAssertTrue(msg.contains("check the API key"))
    }

    func testNetworkOnlyFailures() {
        let msg = ProviderChainError.chainFailureMessage(
            [("nvidia-nim", 0), ("opencode-zen", 0)],
            lastError: nil
        )
        XCTAssertTrue(msg.contains("Could not reach any provider"))
    }

    func testGenericListWhenNoActionableSignal() {
        // NVIDIA 404s are actionable (account "Public API Endpoints" permission),
        // so this case returns the targeted hint instead of the generic list.
        let msg = ProviderChainError.chainFailureMessage(
            [("nvidia-nim", 404), ("llamaapp", 400)],
            lastError: nil
        )
        XCTAssertTrue(msg.contains("NVIDIA NIM is returning 404"))
        XCTAssertTrue(msg.contains("Public API Endpoints"))
        XCTAssertFalse(msg.contains("All providers failed"))
    }

    func testGenericListWhenNoActionableSignalForNonNvidia() {
        let msg = ProviderChainError.chainFailureMessage(
            [("deepseek", 404), ("llamaapp", 400)],
            lastError: nil
        )
        XCTAssertTrue(msg.contains("All providers failed"))
        XCTAssertTrue(msg.contains("deepseek (HTTP 404)"))
        XCTAssertTrue(msg.contains("llamaapp (HTTP 400)"))
    }

    func testEmptyFailuresFallsBackToLastError() {
        struct StubError: LocalizedError {
            var errorDescription: String? { "Provider nvidia-nim unavailable (HTTP 500)" }
        }
        let err = StubError()
        let msg = ProviderChainError.chainFailureMessage([], lastError: err)
        XCTAssertEqual(msg, "Provider nvidia-nim unavailable (HTTP 500)")
    }

    func testDuplicateProviderKeptFirstOnce() {
        // Same provider appearing twice (primary + fallback) must appear once.
        let msg = ProviderChainError.chainFailureMessage(
            [("nvidia-nim", 429), ("nvidia-nim", 500), ("llamaapp", 400)],
            lastError: nil
        )
        let occurrences = msg.components(separatedBy: "nvidia-nim").count - 1
        XCTAssertEqual(occurrences, 1, "provider should appear once, got: \(msg)")
    }
}
