import XCTest
@testable import JXRouter

final class RecommendedEnhancementsTests: XCTestCase {

    func testResponseHygieneStripsControlTokens() {
        let input = "<|im_start|>system\nHello world<|im_end|>\n<|assistant|><|eot_id|>"
        let cleaned = ResponseHygiene.stripControlTokens(input)
        XCTAssertEqual(cleaned, "Hello world\n")
    }

    func testGGUFTemplateSanitizerNeutralizesRaiseException() {
        let rawTemplate = "{%- if not messages %}{{- raise_exception('No messages provided.') }}{%- endif %}"
        let (changed, sanitized) = GGUFTemplateSanitizer.sanitizeTemplateString(rawTemplate)
        XCTAssertTrue(changed)
        XCTAssertEqual(sanitized.utf8.count, rawTemplate.utf8.count, "Byte count must be exactly preserved")
        XCTAssertFalse(sanitized.contains("raise_exception"))
    }

    func testGGUFTemplateSanitizerLeavesCleanTemplateUntouched() {
        let clean = "{%- for msg in messages %}{{ msg.content }}{%- endfor %}"
        let (changed, sanitized) = GGUFTemplateSanitizer.sanitizeTemplateString(clean)
        XCTAssertFalse(changed)
        XCTAssertEqual(sanitized, clean)
    }
}
