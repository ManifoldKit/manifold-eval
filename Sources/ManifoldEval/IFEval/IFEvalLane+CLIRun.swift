import Foundation

// MARK: - Responses wire type

/// One entry in an IFEval responses JSONL file.
///
/// Each line of the file is a JSON object with a `key` matching an ``IFEvalCase``
/// and a `response` string (the model output to score).
///
/// Example line:
/// ```json
/// {"key":"1001","response":"The capital of France is Paris."}
/// ```
public struct IFEvalResponseEntry: Codable, Sendable, Equatable {
    public let key: String
    public let response: String

    public init(key: String, response: String) {
        self.key = key
        self.response = response
    }
}

// MARK: - CLI run extension

public extension IFEvalLane {

    // MARK: - Nested result type

    struct CLIRunResult: Sendable {
        public let score: IFEvalAggregateScore
        public let markdown: String
    }

    // MARK: - Responses loading

    /// Loads response entries from a JSONL file (one JSON object per line).
    ///
    /// Blank lines are silently skipped. Throws on the first malformed line.
    static func loadResponses(from url: URL) throws -> [IFEvalResponseEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var entries: [IFEvalResponseEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                throw IFEvalCorpus.LoadError.decodingFailed(entries.count, "UTF-8 conversion failed")
            }
            do {
                entries.append(try decoder.decode(IFEvalResponseEntry.self, from: data))
            } catch {
                throw IFEvalCorpus.LoadError.decodingFailed(entries.count, error.localizedDescription)
            }
        }
        return entries
    }

    // MARK: - End-to-end CLI run

    /// Loads corpus and responses from disk, evaluates every case, and renders a markdown report.
    ///
    /// Cases whose key does not appear in `responsesURL` are scored against an empty string
    /// (all verifiers fail — conservative, not a skip). This mirrors the way
    /// `IFEvalLane.evaluate(case:response:)` handles missing responses.
    func cliRun(
        corpusURL: URL,
        responsesURL: URL,
        modelName: String? = nil
    ) throws -> CLIRunResult {
        let cases = try IFEvalCorpus.load(from: corpusURL)
        let responseEntries = try IFEvalLane.loadResponses(from: responsesURL)
        let responsesByKey = Dictionary(
            responseEntries.map { ($0.key, $0.response) },
            uniquingKeysWith: { first, _ in first }
        )

        var results: [IFEvalResult] = []
        for evalCase in cases {
            let response = responsesByKey[evalCase.key] ?? ""
            results.append(evaluate(case: evalCase, response: response))
        }

        let score = aggregate(results: results, cases: cases)
        let markdown = IFEvalLane.renderMarkdown(score: score, modelName: modelName)
        return CLIRunResult(score: score, markdown: markdown)
    }

    // MARK: - Markdown rendering

    static func renderMarkdown(score: IFEvalAggregateScore, modelName: String?) -> String {
        var lines: [String] = []
        lines.append("# IFEval Results")
        lines.append("")
        if let modelName {
            lines.append("**Model:** \(modelName)")
            lines.append("")
        }
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        lines.append("| Total Cases | \(score.totalCases) |")
        lines.append("| Passed Cases | \(score.passedCases) |")
        lines.append("| Strict Accuracy | \(String(format: "%.1f", score.strictAccuracy * 100))% |")

        if !score.perInstructionAccuracy.isEmpty {
            lines.append("")
            lines.append("## Per-Instruction Accuracy")
            lines.append("")
            lines.append("| Instruction ID | Accuracy |")
            lines.append("|----------------|----------|")
            for (id, acc) in score.perInstructionAccuracy.sorted(by: { $0.key < $1.key }) {
                lines.append("| \(id) | \(String(format: "%.1f", acc * 100))% |")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }
}
