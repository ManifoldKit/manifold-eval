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

        sections.append(percentilePolicySection(result.results))
        sections.append(gridSection(result.results))
        if result.results.contains(where: { $0.medianGenerateTps != nil || $0.coldTtftMs != nil }) {
            sections.append(nativeSplitSection(result.results))
        }
        sections.append(caveatsSection())

        return sections.joined(separator: "\n\n") + "\n"
    }

    // MARK: - Hardware header

    private static func hardwareHeader(_ hardware: HardwareSnapshot, results: [BenchResult]) -> String {
        let specHashes = Set(results.map(\.specHash))
        let specHash = specHashes.count == 1 ? (specHashes.first ?? "—") : "MIXED (\(specHashes.count))"
        var lines = [
            "## Hardware",
            "",
            "- **Chip:** \(hardware.chip)",
            "- **Memory:** \(Int(hardware.memoryGB)) GB",
            "- **OS:** \(hardware.os)",
            "- **Spec hash:** `\(specHash.prefix(12))\(specHash.count > 12 ? "…" : "")`",
        ]
        let versions = results.compactMap(\.engineVersion)
        if !versions.isEmpty {
            lines.append("- **Engine version(s):** \(Set(versions).sorted().joined(separator: ", "))")
        }
        let digests = results.compactMap(\.modelDigest)
        if !digests.isEmpty {
            let short = digests.map { $0.count > 16 ? String($0.prefix(16)) + "…" : $0 }
            lines.append("- **Model digest(s):** \(Set(short).sorted().joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Percentile policy

    private static func percentilePolicySection(_ results: [BenchResult]) -> String {
        let n = results.map(\.ttftMsPerRun.count).max() ?? 0
        var lines = [
            "## Percentile policy",
            "",
            "Publication policy (ManifoldKit #2335):",
            "",
            "- **median + min/max** always — the honest summary at small `n`.",
            "- **p90** only when `timed_runs ≥ \(BenchResult.p90PublicationMinimumSamples)` "
                + "(nearest-rank otherwise collapses toward the max).",
            "- **p99** only when `timed_runs ≥ \(BenchResult.p99PublicationMinimumSamples)` "
                + "(below that, nearest-rank p99 **is** the sample maximum).",
            "",
            "This run's largest sample count is **\(n)**"
                + (n >= BenchResult.p90PublicationMinimumSamples
                    ? " — p90 is published where available."
                    : " — report median + min/max only; p90/p99 are stored on the "
                        + "JSON record but not presented as publication figures."),
        ]
        return lines.joined(separator: "\n")
    }

    // MARK: - Transport × engine grid

    private static func gridSection(_ results: [BenchResult]) -> String {
        var lines: [String] = []
        lines.append("## Transport × engine grid")
        lines.append(
            "Medians over the timed runs (warmup discarded). TTFT = wall-clock to "
            + "first streamed token. TPS = tokens ÷ total wall time, **prefill included** "
            + "(see native-split table for decode-only tok/s)."
        )
        lines.append("")

        let anyP90 = results.contains(where: \.publishesP90)
        if anyP90 {
            lines.append(
                "| Lane | Transport | Engine | Model | Quant | Runs | TTFT med (ms) | TTFT min/max | TTFT p90 | TPS med | TPS min/max | TPS p90 |"
            )
            lines.append(
                "|------|-----------|--------|-------|-------|------|---------------|--------------|----------|---------|-------------|---------|"
            )
        } else {
            lines.append(
                "| Lane | Transport | Engine | Model | Quant | Runs | TTFT med (ms) | TTFT min/max | TPS med | TPS min/max |"
            )
            lines.append(
                "|------|-----------|--------|-------|-------|------|---------------|--------------|---------|-------------|"
            )
        }

        for result in results.sorted(by: { ($0.transport.rawValue, $0.lane) < ($1.transport.rawValue, $1.lane) }) {
            let minMaxTtft = "\(fixed(result.minTtftMs, decimals: 1))–\(fixed(result.maxTtftMs, decimals: 1))"
            let minMaxTps = "\(fixed(result.minTps, decimals: 2))–\(fixed(result.maxTps, decimals: 2))"
            var row =
                "| \(esc(result.lane)) | \(esc(result.transport.rawValue)) | \(esc(result.engine)) | "
                + "\(esc(result.model)) | \(esc(result.quant)) | \(result.tpsPerRun.count) | "
                + "\(fixed(result.medianTtftMs, decimals: 1)) | \(minMaxTtft) | "
            if anyP90 {
                let p90Ttft = result.publishesP90 ? fixed(result.p90TtftMs, decimals: 1) : "—"
                let p90Tps = result.publishesP90 ? fixed(result.p90Tps, decimals: 2) : "—"
                row += "\(p90Ttft) | \(fixed(result.medianTps, decimals: 2)) | \(minMaxTps) | \(p90Tps) |"
            } else {
                row += "\(fixed(result.medianTps, decimals: 2)) | \(minMaxTps) |"
            }
            lines.append(row)
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - Native split + cold

    private static func nativeSplitSection(_ results: [BenchResult]) -> String {
        var lines: [String] = []
        lines.append("## Native split (load / prefill / decode)")
        lines.append(
            "Ollama reports `load_duration`, `prompt_eval_*`, and `eval_*` on the final "
            + "chunk — captured per run. OpenAI-compatible lanes derive **decode** tok/s as "
            + "`tokens / (wall − TTFT)`; load + prefill stay blank. "
            + "Wall TPS above remains **prefill-included** for continuity."
        )
        lines.append("")
        lines.append(
            "| Lane | Load med (ms) | Prefill tok/s | Decode tok/s | Cold load (ms) | Cold TTFT (ms) |"
        )
        lines.append(
            "|------|---------------|---------------|--------------|----------------|----------------|"
        )
        for result in results.sorted(by: { ($0.transport.rawValue, $0.lane) < ($1.transport.rawValue, $1.lane) }) {
            lines.append(
                "| \(esc(result.lane)) | \(opt(result.medianLoadDurationMs, decimals: 1)) | "
                + "\(opt(result.medianPrefillTps, decimals: 2)) | "
                + "\(opt(result.medianGenerateTps, decimals: 2)) | "
                + "\(opt(result.coldLoadDurationMs, decimals: 1)) | "
                + "\(opt(result.coldTtftMs, decimals: 1)) |"
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
            "- **Wall TPS is prefill-included** (`tokens ÷ total wall time`). Use the "
                + "native-split **Decode tok/s** column for generation-only throughput.",
            "- `http-openai` token counts prefer the server's `usage.completion_tokens` "
                + "when the endpoint honors `stream_options.include_usage`; otherwise they "
                + "fall back to counting non-empty SSE delta chunks, which assumes ~1 token "
                + "per chunk and may undercount a server that batches multiple tokens per event.",
            "- Cold-start uses Ollama `keep_alive: 0` to force unload, then one measured "
                + "reload. OpenAI-compatible lanes have no unload verb — cold columns stay blank.",
            "- Peak/steady-state memory and cancellation latency are **out of scope** for "
                + "the HTTP spine (client cannot see server RSS; HTTP has no cancel verb). "
                + "Those metrics gate on ManifoldKit #2245 companion server hosts / in-process E2E.",
            "- This spine measures HTTP-fronted lanes only. Companion server hosts "
                + "(manifold-server-mlx / manifold-server-llama) and in-process control "
                + "lanes are follow-ups, not yet wired into this matrix.",
        ].joined(separator: "\n")
    }

    // MARK: - Formatting

    private static func fixed(_ value: Double, decimals: Int) -> String {
        String(format: "%.\(decimals)f", value)
    }

    private static func opt(_ value: Double?, decimals: Int) -> String {
        guard let value else { return "—" }
        return fixed(value, decimals: decimals)
    }

    private static func esc(_ value: String) -> String {
        value.replacingOccurrences(of: "|", with: "\\|")
    }
}
