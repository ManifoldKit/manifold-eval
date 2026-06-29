import XCTest
@testable import ManifoldEval

/// Unit tests for each IFEval verifier: one pass case, one fail case, and at
/// least one edge case per verifier. Every assertion targets an exact result —
/// no `XCTAssertTrue(result == true || ambiguous)` escape hatches.
final class IFEvalVerifierTests: XCTestCase {

    // MARK: - Helpers

    private func kw(_ pairs: (String, IFEvalKwarg)...) -> [String: IFEvalKwarg] {
        Dictionary(uniqueKeysWithValues: pairs)
    }

    // MARK: - Word count

    func testWordCountAtLeastPass() {
        let v = WordCountVerifier()
        let response = Array(repeating: "word", count: 50).joined(separator: " ")
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("relation", .string("at least")), ("num_words", .int(50)))))
    }

    func testWordCountAtLeastFail() {
        let v = WordCountVerifier()
        let response = Array(repeating: "word", count: 20).joined(separator: " ")
        XCTAssertFalse(v.verify(response: response, kwargs: kw(("relation", .string("at least")), ("num_words", .int(50)))))
    }

    func testWordCountAround() {
        let v = WordCountVerifier()
        // "around 100" allows ±10 (max(5, 10% of 100)).
        let response = Array(repeating: "word", count: 95).joined(separator: " ")
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("relation", .string("around")), ("num_words", .int(100)))))
        let tooFew = Array(repeating: "word", count: 80).joined(separator: " ")
        XCTAssertFalse(v.verify(response: tooFew, kwargs: kw(("relation", .string("around")), ("num_words", .int(100)))))
    }

    func testWordCountLessThan() {
        let v = WordCountVerifier()
        XCTAssertTrue(v.verify(response: "just five words here now",
                               kwargs: kw(("relation", .string("less than")), ("num_words", .int(10)))))
        XCTAssertFalse(v.verify(response: "one two three four five six seven eight nine ten",
                                kwargs: kw(("relation", .string("less than")), ("num_words", .int(10)))))
    }

    func testWordCountMissingKwargsFail() {
        XCTAssertFalse(WordCountVerifier().verify(response: "hello", kwargs: [:]))
    }

    // MARK: - Sentence count

    func testSentenceCountAtLeastPass() {
        let v = SentenceCountVerifier()
        let response = "First sentence. Second sentence. Third sentence."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("relation", .string("at least")), ("num_sentences", .int(3)))))
    }

    func testSentenceCountFail() {
        let v = SentenceCountVerifier()
        XCTAssertFalse(v.verify(response: "Just one.", kwargs: kw(("relation", .string("at least")), ("num_sentences", .int(3)))))
    }

    func testSentenceCountQuestionMarks() {
        let v = SentenceCountVerifier()
        XCTAssertTrue(v.verify(response: "Why? Because! Sure.",
                               kwargs: kw(("relation", .string("exactly")), ("num_sentences", .int(3)))))
    }

    // MARK: - Paragraph count

    func testParagraphCountExactPass() {
        let v = ParagraphCountVerifier()
        let response = "Para one.\n\nPara two.\n\nPara three."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("num_paragraphs", .int(3)))))
    }

    func testParagraphCountFail() {
        let v = ParagraphCountVerifier()
        XCTAssertFalse(v.verify(response: "Only one para.",
                                kwargs: kw(("num_paragraphs", .int(3)))))
    }

    func testParagraphCountTripleNewline() {
        let v = ParagraphCountVerifier()
        let response = "First.\n\n\nSecond."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("num_paragraphs", .int(2)))))
    }

    // MARK: - Nth paragraph first word

    func testNthParagraphFirstWordPass() {
        let v = NthParagraphFirstWordVerifier()
        let response = "The first paragraph.\n\nBooster rockets are expensive."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(
            ("first_word", .string("booster")),
            ("nth_paragraph", .int(2)),
            ("num_paragraphs", .int(2))
        )))
    }

    func testNthParagraphFirstWordFail() {
        let v = NthParagraphFirstWordVerifier()
        let response = "Alpha paragraph.\n\nBeta paragraph."
        XCTAssertFalse(v.verify(response: response, kwargs: kw(
            ("first_word", .string("gamma")),
            ("nth_paragraph", .int(2)),
            ("num_paragraphs", .int(2))
        )))
    }

    func testNthParagraphFirstWordInsufficientParagraphs() {
        let v = NthParagraphFirstWordVerifier()
        XCTAssertFalse(v.verify(response: "Only one paragraph here.",
                                kwargs: kw(
                                    ("first_word", .string("only")),
                                    ("nth_paragraph", .int(2)),
                                    ("num_paragraphs", .int(2))
                                )))
    }

    // MARK: - Keyword inclusion

    func testKeywordInclusionPass() {
        let v = KeywordInclusionVerifier()
        XCTAssertTrue(v.verify(response: "The quick brown Fox jumps.",
                               kwargs: kw(("keywords", .stringArray(["fox", "quick"])))))
    }

    func testKeywordInclusionFail() {
        let v = KeywordInclusionVerifier()
        XCTAssertFalse(v.verify(response: "No relevant words here.",
                                kwargs: kw(("keywords", .stringArray(["missing"])))))
    }

    func testKeywordInclusionCaseInsensitive() {
        let v = KeywordInclusionVerifier()
        XCTAssertTrue(v.verify(response: "LOUD TEXT",
                               kwargs: kw(("keywords", .stringArray(["loud"])))))
    }

    // MARK: - Keyword exclusion

    func testKeywordExclusionPass() {
        let v = KeywordExclusionVerifier()
        XCTAssertTrue(v.verify(response: "No forbidden content here.",
                               kwargs: kw(("forbidden_words", .stringArray(["ban", "remove"])))))
    }

    func testKeywordExclusionFail() {
        let v = KeywordExclusionVerifier()
        XCTAssertFalse(v.verify(response: "This is banned content.",
                                kwargs: kw(("forbidden_words", .stringArray(["banned"])))))
    }

    func testKeywordExclusionCaseInsensitive() {
        let v = KeywordExclusionVerifier()
        XCTAssertFalse(v.verify(response: "ECONOMY matters.",
                                kwargs: kw(("forbidden_words", .stringArray(["economy"])))))
    }

    // MARK: - Keyword frequency

    func testKeywordFrequencyAtLeastPass() {
        let v = KeywordFrequencyVerifier()
        XCTAssertTrue(v.verify(
            response: "war is war and war never changes",
            kwargs: kw(("keyword", .string("war")), ("relation", .string("at least")), ("frequency", .int(3)))
        ))
    }

    func testKeywordFrequencyFail() {
        let v = KeywordFrequencyVerifier()
        XCTAssertFalse(v.verify(
            response: "peace only once",
            kwargs: kw(("keyword", .string("peace")), ("relation", .string("at least")), ("frequency", .int(3)))
        ))
    }

    func testKeywordFrequencyLessThan() {
        let v = KeywordFrequencyVerifier()
        XCTAssertTrue(v.verify(
            response: "the cat sat",
            kwargs: kw(("keyword", .string("the")), ("relation", .string("less than")), ("frequency", .int(2)))
        ))
        XCTAssertFalse(v.verify(
            response: "the the the",
            kwargs: kw(("keyword", .string("the")), ("relation", .string("less than")), ("frequency", .int(2)))
        ))
    }

    // MARK: - Letter frequency

    func testLetterFrequencyAtLeastPass() {
        let v = LetterFrequencyVerifier()
        XCTAssertTrue(v.verify(
            response: "aaaa bbb",
            kwargs: kw(("letter", .string("a")), ("let_relation", .string("at least")), ("let_frequency", .int(4)))
        ))
    }

    func testLetterFrequencyFail() {
        let v = LetterFrequencyVerifier()
        XCTAssertFalse(v.verify(
            response: "ab",
            kwargs: kw(("letter", .string("a")), ("let_relation", .string("at least")), ("let_frequency", .int(4)))
        ))
    }

    func testLetterFrequencyLessThan() {
        let v = LetterFrequencyVerifier()
        XCTAssertTrue(v.verify(
            response: "x marks the spot",
            kwargs: kw(("letter", .string("x")), ("let_relation", .string("less than")), ("let_frequency", .int(2)))
        ))
    }

    func testLetterFrequencyCaseInsensitive() {
        let v = LetterFrequencyVerifier()
        XCTAssertTrue(v.verify(
            response: "AaAa",
            kwargs: kw(("letter", .string("a")), ("let_relation", .string("at least")), ("let_frequency", .int(4)))
        ))
    }

    // MARK: - JSON output

    func testJSONOutputObjectPass() {
        XCTAssertTrue(JSONOutputVerifier().verify(response: #"{"key": "value"}"#, kwargs: [:]))
    }

    func testJSONOutputArrayPass() {
        XCTAssertTrue(JSONOutputVerifier().verify(response: "[1, 2, 3]", kwargs: [:]))
    }

    func testJSONOutputFail() {
        XCTAssertFalse(JSONOutputVerifier().verify(response: "Not JSON at all.", kwargs: [:]))
    }

    func testJSONOutputWhitespaceStripped() {
        XCTAssertTrue(JSONOutputVerifier().verify(response: "  { \"a\": 1 }  ", kwargs: [:]))
    }

    // MARK: - Bullet list

    func testBulletListPass() {
        let v = BulletListVerifier()
        let response = "* Item one\n* Item two\n* Item three"
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("num_bullets", .int(3)))))
    }

    func testBulletListFail() {
        let v = BulletListVerifier()
        XCTAssertFalse(v.verify(response: "* Only one",
                                kwargs: kw(("num_bullets", .int(3)))))
    }

    func testBulletListDashNotCounted() {
        let v = BulletListVerifier()
        // IFEval reference uses `* ` specifically.
        XCTAssertFalse(v.verify(response: "- item\n- item\n- item",
                                kwargs: kw(("num_bullets", .int(3)))))
    }

    // MARK: - Highlighted sections

    func testHighlightedSectionsPass() {
        let v = HighlightedSectionsVerifier()
        let response = "Here is *section one* and *section two* and *section three*."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("num_highlights", .int(3)))))
    }

    func testHighlightedSectionsFail() {
        let v = HighlightedSectionsVerifier()
        XCTAssertFalse(v.verify(response: "No highlights here.",
                                kwargs: kw(("num_highlights", .int(1)))))
    }

    func testHighlightedSectionsBoldNotCounted() {
        let v = HighlightedSectionsVerifier()
        // **bold** should not count as an italic highlight.
        XCTAssertFalse(v.verify(response: "**bold** text",
                                kwargs: kw(("num_highlights", .int(1)))))
    }

    // MARK: - Title

    func testTitlePass() {
        XCTAssertTrue(TitleVerifier().verify(response: "# My Title\n\nSome text.", kwargs: [:]))
    }

    func testTitleFail() {
        XCTAssertFalse(TitleVerifier().verify(response: "No title here.", kwargs: [:]))
    }

    func testTitleSubheadingCounts() {
        XCTAssertTrue(TitleVerifier().verify(response: "## Section\nContent.", kwargs: [:]))
    }

    // MARK: - Section separator

    func testSectionSeparatorPass() {
        let v = SectionSeparatorVerifier()
        let response = "SECTION 1\nContent.\nSECTION 2\nMore content."
        XCTAssertTrue(v.verify(response: response,
                               kwargs: kw(("section_spliter", .string("SECTION")), ("num_sections", .int(2)))))
    }

    func testSectionSeparatorFail() {
        let v = SectionSeparatorVerifier()
        XCTAssertFalse(v.verify(response: "SECTION 1\nOnly one.",
                                kwargs: kw(("section_spliter", .string("SECTION")), ("num_sections", .int(3)))))
    }

    func testSectionSeparatorDaySplitter() {
        let v = SectionSeparatorVerifier()
        let response = "Day 1\nMonday.\nDay 2\nTuesday.\nDay 3\nWednesday."
        XCTAssertTrue(v.verify(response: response,
                               kwargs: kw(("section_spliter", .string("Day")), ("num_sections", .int(3)))))
    }

    // MARK: - Placeholders

    func testPlaceholderCountPass() {
        let v = PlaceholderCountVerifier()
        XCTAssertTrue(v.verify(response: "[name] lives at [address] near [city].",
                               kwargs: kw(("num_placeholders", .int(3)))))
    }

    func testPlaceholderCountFail() {
        let v = PlaceholderCountVerifier()
        XCTAssertFalse(v.verify(response: "[only one] here.",
                                kwargs: kw(("num_placeholders", .int(3)))))
    }

    func testPlaceholderCountAtLeast() {
        let v = PlaceholderCountVerifier()
        XCTAssertTrue(v.verify(response: "[a] [b] [c] [d] [e]",
                               kwargs: kw(("num_placeholders", .int(3)))))
    }

    // MARK: - Postscript

    func testPostscriptPass() {
        let v = PostscriptVerifier()
        let response = "Main body text.\n\nP.S. Additional note."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("postscript_marker", .string("P.S.")))))
    }

    func testPostscriptFail() {
        let v = PostscriptVerifier()
        XCTAssertFalse(v.verify(response: "No postscript.",
                                kwargs: kw(("postscript_marker", .string("P.S.")))))
    }

    func testPostscriptPPSMarker() {
        let v = PostscriptVerifier()
        let response = "Body.\nP.P.S another note."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("postscript_marker", .string("P.P.S")))))
    }

    // MARK: - Constrained response

    func testConstrainedResponsePass() {
        XCTAssertTrue(ConstrainedResponseVerifier().verify(
            response: "My answer is yes.", kwargs: [:]
        ))
    }

    func testConstrainedResponseFailMultiLine() {
        XCTAssertFalse(ConstrainedResponseVerifier().verify(
            response: "My answer is yes.\nSome explanation.", kwargs: [:]
        ))
    }

    func testConstrainedResponseFailMarkdown() {
        XCTAssertFalse(ConstrainedResponseVerifier().verify(
            response: "* My answer is yes.", kwargs: [:]
        ))
    }

    // MARK: - Two responses

    func testTwoResponsesPass() {
        XCTAssertTrue(TwoResponsesVerifier().verify(
            response: "Response one. ****** Response two.",
            kwargs: [:]
        ))
    }

    func testTwoResponsesFail() {
        XCTAssertFalse(TwoResponsesVerifier().verify(
            response: "Only one response here.",
            kwargs: [:]
        ))
    }

    // MARK: - Repeat prompt

    func testRepeatPromptPass() {
        let v = RepeatPromptVerifier()
        let prompt = "Write a short poem about clouds."
        let response = "Write a short poem about clouds.\n\nClouds drift high..."
        XCTAssertTrue(v.verify(response: response, kwargs: kw(("prompt_to_repeat", .string(prompt)))))
    }

    func testRepeatPromptFail() {
        let v = RepeatPromptVerifier()
        XCTAssertFalse(v.verify(
            response: "Just an answer without the prompt.",
            kwargs: kw(("prompt_to_repeat", .string("Write a short poem.")))
        ))
    }

    // MARK: - All lowercase

    func testAllLowercasePass() {
        XCTAssertTrue(AllLowercaseVerifier().verify(response: "all lowercase text here.", kwargs: [:]))
    }

    func testAllLowercaseFail() {
        XCTAssertFalse(AllLowercaseVerifier().verify(response: "Contains Capital letter.", kwargs: [:]))
    }

    func testAllLowercasePunctuationIgnored() {
        XCTAssertTrue(AllLowercaseVerifier().verify(response: "hello! world? yes.", kwargs: [:]))
    }

    // MARK: - All uppercase

    func testAllUppercasePass() {
        XCTAssertTrue(AllUppercaseVerifier().verify(response: "ALL CAPS TEXT HERE.", kwargs: [:]))
    }

    func testAllUppercaseFail() {
        XCTAssertFalse(AllUppercaseVerifier().verify(response: "Not ALL CAPS.", kwargs: [:]))
    }

    func testAllUppercaseNumbers() {
        XCTAssertTrue(AllUppercaseVerifier().verify(response: "HELLO 123 WORLD", kwargs: [:]))
    }

    // MARK: - Capital word frequency

    func testCapitalWordFrequencyAtLeastPass() {
        let v = CapitalWordFrequencyVerifier()
        let response = "Alice and Bob went to Paris and London."
        XCTAssertTrue(v.verify(response: response,
                               kwargs: kw(("capital_relation", .string("at least")), ("capital_frequency", .int(4)))))
    }

    func testCapitalWordFrequencyFail() {
        let v = CapitalWordFrequencyVerifier()
        XCTAssertFalse(v.verify(response: "just lowercase words",
                                kwargs: kw(("capital_relation", .string("at least")), ("capital_frequency", .int(3)))))
    }

    func testCapitalWordFrequencyLessThan() {
        let v = CapitalWordFrequencyVerifier()
        XCTAssertTrue(v.verify(response: "Alice is here.",
                               kwargs: kw(("capital_relation", .string("less than")), ("capital_frequency", .int(3)))))
    }

    // MARK: - Starts with (helper verifier)

    func testStartsWithPass() {
        XCTAssertTrue(StartsWithVerifier().verify(
            response: "Summary: this is an overview.",
            kwargs: kw(("start_phrase", .string("summary:")))
        ))
    }

    func testStartsWithFail() {
        XCTAssertFalse(StartsWithVerifier().verify(
            response: "Introduction: something else.",
            kwargs: kw(("start_phrase", .string("summary:")))
        ))
    }

    // MARK: - Ends with

    func testEndsWithPass() {
        XCTAssertTrue(EndsWithVerifier().verify(
            response: "Some text here. The end.",
            kwargs: kw(("end_phrase", .string("the end.")))
        ))
    }

    func testEndsWithFail() {
        XCTAssertFalse(EndsWithVerifier().verify(
            response: "This does not end correctly.",
            kwargs: kw(("end_phrase", .string("the end.")))
        ))
    }

    func testEndsWithTrailingWhitespace() {
        XCTAssertTrue(EndsWithVerifier().verify(
            response: "See you soon.  \n",
            kwargs: kw(("end_phrase", .string("see you soon.")))
        ))
    }

    // MARK: - No comma

    func testNoCommaPass() {
        XCTAssertTrue(NoCommaVerifier().verify(response: "No commas in this sentence at all.", kwargs: [:]))
    }

    func testNoCommaFail() {
        XCTAssertFalse(NoCommaVerifier().verify(response: "One, two, three.", kwargs: [:]))
    }

    // MARK: - Quoted wrap

    func testQuotedWrapPass() {
        XCTAssertTrue(QuotedWrapVerifier().verify(response: "\"This is the entire response.\"", kwargs: [:]))
    }

    func testQuotedWrapFail() {
        XCTAssertFalse(QuotedWrapVerifier().verify(response: "Not wrapped in quotes.", kwargs: [:]))
    }

    func testQuotedWrapOnlyOpening() {
        XCTAssertFalse(QuotedWrapVerifier().verify(response: "\"missing closing quote", kwargs: [:]))
    }

    // MARK: - Language (script detection path)

    func testLanguageArabicPass() {
        let v = ResponseLanguageVerifier()
        // Arabic text: "السلام عليكم" (peace be upon you)
        XCTAssertTrue(v.verify(
            response: "السلام عليكم ورحمة الله وبركاته",
            kwargs: kw(("language", .string("ar")))
        ))
    }

    func testLanguageArabicFail() {
        let v = ResponseLanguageVerifier()
        XCTAssertFalse(v.verify(
            response: "This is definitely English text.",
            kwargs: kw(("language", .string("ar")))
        ))
    }

    func testLanguageDevanagariHindi() {
        let v = ResponseLanguageVerifier()
        // Hindi: "नमस्ते" (hello)
        XCTAssertTrue(v.verify(
            response: "नमस्ते दुनिया यह हिंदी में है",
            kwargs: kw(("language", .string("hi")))
        ))
    }

    func testLanguageEmptyFail() {
        XCTAssertFalse(ResponseLanguageVerifier().verify(response: "", kwargs: kw(("language", .string("ar")))))
    }
}
