import XCTest
@testable import SuperVibe

final class LLMServiceTests: XCTestCase {

    func testRefusalMarkerInOutputOnlyIsARefusal() {
        XCTAssertTrue(LLMService.looksLikeRefusal("抱歉，我无法处理这段内容。", input: "今天开会讨论排期"))
        XCTAssertTrue(LLMService.looksLikeRefusal("I can't help with that.", input: "translate this"))
    }

    func testMarkerDictatedByTheUserIsNotARefusal() {
        // The user said the marker word; a faithful polish contains it too.
        XCTAssertFalse(LLMService.looksLikeRefusal("抱歉，我今天来晚了。", input: "抱歉我今天来晚了"))
        XCTAssertFalse(LLMService.looksLikeRefusal("The report is incomplete.", input: "the report is incomplete"))
    }

    func testOrdinaryOutputIsNotARefusal() {
        XCTAssertFalse(LLMService.looksLikeRefusal("今天开会讨论排期。", input: "今天开会讨论排期"))
    }

    func testSanitizeLeavesOrdinaryWordsIntact() {
        let llm = LLMService()
        XCTAssertEqual(llm.sanitize("pass the class assignment"), "pass the class assignment")
        XCTAssertEqual(llm.sanitize("这个操作逼近了上限"), "这个操作逼近了上限")
    }

    func testSanitizeReplacesWholeWordsAndPhrases() {
        let llm = LLMService()
        XCTAssertEqual(llm.sanitize("what an ass"), "what an butt")
        XCTAssertEqual(llm.sanitize("Shit, it broke"), "crap, it broke")
        XCTAssertEqual(llm.sanitize("他妈的又挂了"), "该死的又挂了")
    }
}

final class HotwordBuilderTests: XCTestCase {

    private func ambient(_ text: String) -> AmbientSnapshot {
        AmbientSnapshot(bundleId: "test", appName: "Test", windowTitle: "", visibleWindowText: text)
    }

    /// Terms from the user's own hotwords file come first and vary per
    /// machine, so assertions look at membership, not position.
    func testExtractsIdentifiersAndAcronyms() {
        let words = HotwordBuilder.build(
            ambient: ambient("调用 useState 之后检查 BOM 和 text_insertion_point"),
            corrections: [],
            maxHotwords: 500
        )
        XCTAssertTrue(words.contains("BOM"))
        XCTAssertTrue(words.contains("text_insertion_point"))
    }

    func testEnglishWordsInCJKTextAreNotSkippedAlternately() {
        let words = HotwordBuilder.build(
            ambient: ambient("我们用 kafka redis postgres 做存储"),
            corrections: [],
            maxHotwords: 500
        )
        XCTAssertTrue(words.contains("kafka"))
        XCTAssertTrue(words.contains("redis"))
        XCTAssertTrue(words.contains("postgres"))
    }

    func testOrdinaryWordsInEnglishTextAreNotHotwords() {
        let words = HotwordBuilder.build(
            ambient: ambient("this sentence only contains ordinary english words with nothing special"),
            corrections: [],
            maxHotwords: 500
        )
        XCTAssertFalse(words.contains("sentence"))
        XCTAssertFalse(words.contains("ordinary"))
    }

    func testRespectsCap() {
        let many = (0..<200).map { "Term\($0)Name" }.joined(separator: " ")
        let words = HotwordBuilder.build(ambient: ambient(many), corrections: [], maxHotwords: 10, maxUserHotwords: 10)
        XCTAssertLessThanOrEqual(words.count, 10)
    }
}

final class EditTrackerTests: XCTestCase {

    func testSmallEditIsNotLarge() {
        let a = EditTracker.analyze(original: "今天讨论 super invite 的排期", current: "今天讨论 SuperVibe 的排期", inserted: "今天讨论 super invite 的排期")
        XCTAssertFalse(a.isLargeModify)
    }

    func testWipingMostOfTheFieldIsLarge() {
        let original = String(repeating: "abcdefghij", count: 10)
        let a = EditTracker.analyze(original: original, current: "abc", inserted: original)
        XCTAssertTrue(a.isLargeModify)
    }

    func testExtractEditedSpanBetweenAnchors() {
        let span = EditTracker.extractEditedSpan(
            originalBefore: "Hello team, ",
            originalAfter: " Thanks.",
            originalInserted: "super invite is ready.",
            currentFull: "Hello team, SuperVibe is ready. Thanks."
        )
        XCTAssertEqual(span, "SuperVibe is ready.")
    }

    func testNormalizeDropsNewlinesAndZeroWidth() {
        XCTAssertEqual(EditTracker.normalize("a\r\nb\u{200B}c"), "abc")
    }
}
