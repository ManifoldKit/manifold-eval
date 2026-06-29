import Foundation

/// Loads an IFEval dataset from a JSONL file (one JSON object per line).
///
/// The full IFEval corpus (`google/IFEval` on HuggingFace or
/// `google-research/instruction_following_eval`) has 541 cases. The test
/// target bundles the corpus as `Fixtures/ifeval.jsonl` (a `.copy` resource);
/// set `IFEVAL_DATA_PATH` to override with a local file.
public enum IFEvalCorpus {

    public enum LoadError: Error {
        case fileNotFound(String)
        case decodingFailed(Int, String)
    }

    /// Loads all cases from a JSONL file at `url`.
    public static func load(from url: URL) throws -> [IFEvalCase] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        return try parse(jsonl: contents)
    }

    /// Loads all cases from a JSONL string.
    public static func parse(jsonl: String) throws -> [IFEvalCase] {
        let decoder = JSONDecoder()
        var cases: [IFEvalCase] = []
        for (lineIndex, line) in jsonl.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8) else {
                throw LoadError.decodingFailed(lineIndex, "UTF-8 conversion failed")
            }
            do {
                let c = try decoder.decode(IFEvalCase.self, from: data)
                cases.append(c)
            } catch {
                throw LoadError.decodingFailed(lineIndex, error.localizedDescription)
            }
        }
        return cases
    }
}
