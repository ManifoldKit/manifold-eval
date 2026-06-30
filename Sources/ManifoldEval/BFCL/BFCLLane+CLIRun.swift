import Foundation
import ManifoldInference
import ManifoldTools

// MARK: - Responses wire type

/// One entry in a BFCL tool-calls responses JSONL file.
///
/// Each line is a JSON object with the BFCL case `id` and the list of tool
/// calls the model emitted for that case.
///
/// Example line:
/// ```json
/// {"id":"simple_0","calls":[{"id":"1","toolName":"add","arguments":"{\"a\":1,\"b\":2}"}]}
/// ```
public struct BFCLResponseEntry: Codable, Sendable, Equatable {
    public let id: String
    public let calls: [ToolCall]

    public init(id: String, calls: [ToolCall]) {
        self.id = id
        self.calls = calls
    }
}

// MARK: - CLI run extension

public extension BFCLLane {

    // MARK: - Responses loading

    /// Loads tool-calls response entries from a JSONL file (one JSON object per line).
    ///
    /// Blank lines are silently skipped. An empty file returns an empty array
    /// (all cases score with an empty emit — irrelevance passes, others fail).
    static func loadResponses(from url: URL) throws -> [BFCLResponseEntry] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        var entries: [BFCLResponseEntry] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            // Data(_:.utf8) is non-failable — no silent line-drop (the prior
            // `data(using:)`-guard-continue could mask a bad line; aligns with the
            // IFEval loader, which surfaces rather than skips).
            let data = Data(trimmed.utf8)
            do {
                entries.append(try decoder.decode(BFCLResponseEntry.self, from: data))
            } catch {
                throw BFCLCaseLoader.LoadError.fileUnreadable(
                    url,
                    underlying: error
                )
            }
        }
        return entries
    }

    // MARK: - End-to-end CLI run

    /// Loads pre-computed tool-call responses from disk and runs the BFCL lane.
    ///
    /// Cases whose ID does not appear in `responsesURL` are emitted with an empty
    /// call list — irrelevance cases pass; all other categories count as failed.
    func cliRun(corpusDir: URL, responsesURL: URL) async throws -> (result: LaneResult, markdown: String) {
        let entries = try BFCLLane.loadResponses(from: responsesURL)
        let responsesByID = Dictionary(
            entries.map { ($0.id, $0.calls) },
            uniquingKeysWith: { first, _ in first }
        )

        let result = await run(
            corpusSource: .localDirectory(corpusDir),
            emit: { @Sendable testCase in responsesByID[testCase.id] ?? [] }
        )

        return (result, BFCLLane.renderMarkdown(result: result))
    }

    // MARK: - Markdown rendering

    static func renderMarkdown(result: LaneResult) -> String {
        var lines: [String] = []
        lines.append("# BFCL Results")
        lines.append("")
        lines.append(result.fullCorpusSourced
            ? "> Full Gorilla corpus"
            : "> Fixture / local corpus (not full Gorilla)"
        )
        lines.append("")
        lines.append("| Category | Total | Passed | Accuracy |")
        lines.append("|----------|-------|--------|----------|")
        for cat in result.categoryResults {
            if cat.skipped {
                let reason = cat.skipReason ?? "unknown"
                lines.append("| \(cat.category.rawValue) | — | — | skipped: \(reason) |")
            } else {
                lines.append(
                    "| \(cat.category.rawValue) | \(cat.total) | \(cat.passed)"
                    + " | \(String(format: "%.1f", cat.accuracy * 100))% |"
                )
            }
        }
        lines.append("")
        lines.append(
            "**Overall:** \(result.overallPassed) / \(result.overallTotal)"
            + " (\(String(format: "%.1f", result.overallAccuracy * 100))%)"
        )
        return lines.joined(separator: "\n") + "\n"
    }
}
