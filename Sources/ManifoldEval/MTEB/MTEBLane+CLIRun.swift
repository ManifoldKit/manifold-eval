import Foundation

// MARK: - CLI run extension

public extension MTEBLane {

    // MARK: - Dataset resolution

    /// Resolves STS pairs for a CLI `--dataset` argument.
    ///
    /// - `"fixture"`: returns ``builtinFixture`` (the 15-pair scaffold; no file I/O).
    /// - Any other string: treated as a file path; falls back to ``builtinFixture``
    ///   when the file is absent, with a label noting the fallback.
    ///
    /// Throws only when the file exists but is unreadable or not valid JSON.
    static func loadPairsOrBuiltin(from path: String) throws -> (pairs: [STSPair], label: String) {
        if path == "fixture" {
            return (builtinFixture, "built-in scaffold (15 pairs)")
        }
        let url = URL(fileURLWithPath: path)
        if let pairs = try loadPairs(from: url) {
            return (pairs, url.lastPathComponent)
        }
        return (builtinFixture, "built-in scaffold (15 pairs; \(path) not found — using fixture)")
    }

    // MARK: - Markdown rendering

    static func renderMarkdown(result: MTEBLaneResult) -> String {
        var lines: [String] = []
        lines.append("# MTEB-STS Results")
        lines.append("")
        lines.append("| Metric | Value |")
        lines.append("|--------|-------|")
        lines.append("| Model | \(result.modelName) |")
        lines.append("| Pairs | \(result.pairCount) |")
        lines.append("| Spearman ρ | \(String(format: "%.4f", result.spearmanCorrelation)) |")
        lines.append("| Pearson r | \(String(format: "%.4f", result.pearsonCorrelation)) |")
        return lines.joined(separator: "\n") + "\n"
    }
}
