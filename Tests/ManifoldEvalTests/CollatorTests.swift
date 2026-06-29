import XCTest
@testable import ManifoldEval
import ManifoldTools

/// Fixture-driven tests for the separate-process record collator. No live model
/// or backend — these run in CI on hosted runners. The real lanes that produce
/// records are hardware-gated and exercised via the CLI (see README).
final class CollatorTests: XCTestCase {

    private func fixture(_ name: String) throws -> URL {
        try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
    }

    // MARK: merge

    func testCollatesAcrossBackends() throws {
        let result = try Collator.collate(files: [
            try fixture("ollama-mistral"),
            try fixture("llama-mistral"),
        ])

        XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.backends, ["llama.cpp", "ollama"])
        XCTAssertEqual(result.coreCommits, ["4461529f"])
        XCTAssertFalse(result.hasErrors)
        XCTAssertTrue(result.diagnostics.isEmpty, "clean same-commit set should produce no diagnostics")
    }

    func testRenderSurfacesBothBackends() throws {
        let result = try Collator.collate(files: [
            try fixture("ollama-mistral"),
            try fixture("llama-mistral"),
        ])
        let markdown = CrossRuntimeMatrix.render(result)

        XCTAssertTrue(markdown.contains("ollama"), "matrix should name the ollama leg")
        XCTAssertTrue(markdown.contains("llama.cpp"), "matrix should name the llama.cpp leg")
        // Deterministic for a given record value (MatrixRenderer guarantees it).
        XCTAssertEqual(markdown, CrossRuntimeMatrix.render(result))
    }

    // MARK: comparability guard (the value-add over `cat *.json | matrix`)

    func testMixedCoreCommitsWarn() throws {
        let result = try Collator.collate(files: [
            try fixture("ollama-mistral"),            // coreCommit 4461529f
            try fixture("llama-mistral-othercommit"), // coreCommit deadbeef
        ])

        XCTAssertEqual(result.coreCommits, ["4461529f", "deadbeef"])
        XCTAssertFalse(result.hasErrors, "a mixed-commit set still renders — it's advisory, not fatal")
        let commitWarnings = result.diagnostics.filter {
            $0.severity == .warning && $0.message.contains("core commit")
        }
        XCTAssertEqual(commitWarnings.count, 1, "mixed core commits must raise exactly one warning")
    }

    // MARK: failure modes — never silently skip a leg

    func testEmptyInputThrows() {
        XCTAssertThrowsError(try Collator.collate(files: [])) { error in
            XCTAssertEqual(error as? CollationError, .noInput)
        }
    }

    func testUnreadableFileThrows() {
        let missing = URL(fileURLWithPath: "/nonexistent/path/records.json")
        XCTAssertThrowsError(try Collator.collate(files: [missing])) { error in
            guard case CollationError.unreadable = error else {
                return XCTFail("expected .unreadable, got \(error)")
            }
        }
    }

    func testMalformedJSONThrows() throws {
        let bad = try XCTUnwrap("{ not an array }".data(using: .utf8))
        XCTAssertThrowsError(try Collator.collate(jsonArrays: [bad])) { error in
            guard case CollationError.undecodable = error else {
                return XCTFail("expected .undecodable, got \(error)")
            }
        }
    }

    func testEmptyArrayCollatesToErrorDiagnostic() throws {
        let empty = try XCTUnwrap("[]".data(using: .utf8))
        let result = try Collator.collate(jsonArrays: [empty])
        XCTAssertTrue(result.hasErrors, "an all-empty corpus is an error-severity diagnostic")
        XCTAssertEqual(result.records.count, 0)
    }
}
