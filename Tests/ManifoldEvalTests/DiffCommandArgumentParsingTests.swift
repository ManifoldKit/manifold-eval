import XCTest
@testable import ManifoldEval
@testable import manifold_eval

/// Unit tests for `DiffCommand.parseArguments` — the pure argv parser
/// extracted from `DiffCommand.run` specifically so the flag grammar is
/// testable without touching the network (no Ollama version probe, no
/// differential harness run). Focused on the two new flags this PR adds
/// (`--top-k` / `--repeat-penalty`) plus their defaults, since the rest of the
/// flag grammar is unchanged.
final class DiffCommandArgumentParsingTests: XCTestCase {

    /// Parses `args`, failing the test (rather than crashing the process) if
    /// `die` is invoked — every case here is expected to be well-formed argv.
    private func parse(_ args: [String], file: StaticString = #filePath, line: UInt = #line) -> DiffCommand.ParsedArguments {
        var diedMessage: String?
        let parsed = DiffCommand.parseArguments(args) { message, _ in
            diedMessage = message
            fatalError("die() called unexpectedly with: \(message)")
        }
        XCTAssertNil(diedMessage, file: file, line: line)
        return parsed
    }

    func testTopKFlagParsesIntoParsedArguments() {
        let parsed = parse(["--model", "m", "--prompt-file", "p.txt", "--top-k", "40"])
        XCTAssertEqual(parsed.topK, 40)
    }

    func testRepeatPenaltyFlagParsesIntoParsedArguments() {
        let parsed = parse(["--model", "m", "--prompt-file", "p.txt", "--repeat-penalty", "1.15"])
        XCTAssertEqual(parsed.repeatPenalty, 1.15, accuracy: 0.0001)
    }

    func testTopKAndRepeatPenaltyDefaultsMatchSamplerConfigDefaults() {
        // Force-matching only makes sense if the CLI's defaults agree with
        // what SamplerConfig would already use unrequested — otherwise adding
        // the flags would silently change the neutral baseline.
        let parsed = parse(["--model", "m", "--prompt-file", "p.txt"])
        let defaultSampler = SamplerConfig()
        XCTAssertEqual(parsed.topK, defaultSampler.topK)
        XCTAssertEqual(parsed.repeatPenalty, defaultSampler.repeatPenalty, accuracy: 0.0001)
    }

    func testTopKAndRepeatPenaltyBothOverridableTogetherAlongsideExistingFlags() {
        // Mirrors the existing --temperature/--seed parsing style and must
        // compose with them without disturbing unrelated fields.
        let parsed = parse([
            "--model", "m", "--prompt-file", "p.txt",
            "--temperature", "0.6", "--seed", "9",
            "--top-k", "1", "--repeat-penalty", "1.05",
        ])
        XCTAssertEqual(parsed.temperature, 0.6, accuracy: 0.0001)
        XCTAssertEqual(parsed.seed, 9)
        XCTAssertEqual(parsed.topK, 1)
        XCTAssertEqual(parsed.repeatPenalty, 1.05, accuracy: 0.0001)
    }
}
