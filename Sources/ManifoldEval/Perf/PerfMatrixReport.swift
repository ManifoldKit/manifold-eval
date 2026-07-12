import Foundation

/// Renders a collated ``PerfCollationResult`` as `PERF-MATRIX.md` — the perf
/// twin of `ManifoldTools.MatrixRenderer` / ``CrossRuntimeMatrix``. Pure and
/// deterministic (stable-sorted grouping), so it can be unit-tested against
/// hand-built fixtures with no live server.
public enum PerfMatrixReport {

    public static let defaultTitle = "Local-Inference Performance Matrix"

    /// Renders the full Markdown document for a collation result.
    public static func render(_ result: PerfCollationResult, title: String = defaultTitle) -> String {
        var sections: [String] = []
        sections.append("# \(title)")

        if !result.diagnostics.isEmpty {
            var lines = ["> **Collation diagnostics**", ">"]
            for diagnostic in result.diagnostics {
                lines.append("> - **\(diagnostic.severity.rawValue.uppercased())** — \(diagnostic.message)")
            }
            sections.append(lines.joined(separator: "\n"))
        }

        if let hardware = result.results.first?.hardware {
            sections.append(hardwareHeader(hardware, results: result.results))
        }

        sections.append(gridSection(result.results))
        sections.append(caveatsSection())

        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Hardware header

    private static func hardwareHeader(_ hardware: HardwareSnapshot, results: [BenchResult]) -> String {
        let specHashes = Set(results.map(\.specHash))
        let specHash = specHashes.count == 1 ? (specHashes.first ?? "—") : "MIXED (\(specHashes.count))"
        return [
            "## Hardware",
            "",
            "- **Chip:** \(hardware.chip)",
            "- **Memory:** \(Int(hardware.memoryGB)) GB",
            "- **OS:** \(hardware.os)",
            "- **Spec hash:** `\(specHash.prefix(12))\(specHash.count > 12 ? "…" : "")`",
        ].joined(separator: "\n")
    }

    // MARK: - Transport × engine grid

    private static func gridSection(_ results: [BenchResult]) -> String {
        var lines: [String] = []
        lines.append("## Transport × engine grid")
        lines.append(
            "Medians over the timed runs (warmup discarded). TTFT = wall-clock to "
            + "first streamed token. TPS = tokens ÷ total wall time, **prefill included**."
        )
        lines.append("")
        lines.append("| Lane | Transport | Engine | Model | Quant | Runs | TTFT (ms) | TPS |")
        lines.append("|------|-----------|--------|-------|-------|------|-----------|-----|")

        for result in results.sorted(by: { ($0.transport.rawValue, $0.lane) < ($1.transport.rawValue, $1.lane) }) {
            lines.append(
                "| \(esc(result.lane)) | \(esc(result.transport.rawValue)) | \(esc(result.engine)) | "
                + "\(esc(result.model)) | \(esc(result.quant)) | \(result.tpsPerRun.count) | "
                + "\(fixed(result.medianTtftMs, decimals: 1)) | \(fixed(result.medianTps, decimals: 2)) |"
            )
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Caveats

    private static func caveatsSection() -> String {
        [
            "## Caveats",
            "",
            "- Lanes were run **strictly sequentially** (never concurrently) to avoid "
                + "GPU-contention corrupting throughput numbers — see `BenchResult.runAlone`.",
            "- A quant-camp mismatch (flagged above, if present) means the compared "
                + "weights are not bit-identical; treat deltas as directional.",
            "- `http-openai` token counts prefer the server's `usage.completion_tokens` "
                + "when the endpoint honors `stream_options.include_usage`; otherwise they "
                + "fall back to counting non-empty SSE delta chunks, which assumes ~1 token "
                + "per chunk and may undercount a server that batches multiple tokens per event.",
            "- This spine measures HTTP-fronted lanes only. Companion server hosts "
                + "(manifold-server-mlx / manifold-server-llama) and in-process control "
                + "lanes are follow-ups, not yet wired into this matrix.",
        ].joined(separator: "\n")
    }

    // MARK: - Formatting

    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private static func esc(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
