import Foundation
import ManifoldEval

/// The `toolloop` subcommand: scores pre-recorded multi-turn tool-loop
/// transcripts against the corpus — offline, no model, hosted-CI safe.
///
/// Usage:
///
///     manifold-eval toolloop --responses <transcripts.jsonl> [--corpus <cases.jsonl>] [--title T] [--out PATH]
///
/// `--responses` Transcript JSONL as written by `toolloop-generate`.
/// `--corpus`    Corpus JSONL (one ToolLoopCase per line). Omit for the
///               built-in scaffold — the SAME default `toolloop-generate`
///               drives, so a generate → score round trip needs no flags to
///               line up.
/// `--title`     Report title. Default: "tool-loop".
/// `--out`       Write the Markdown report here (stdout otherwise).
///
/// Exit codes are verdict-shaped: `0` = every case passed and repeats were
/// deterministic; `1` = a threading failure or a temp=0 determinism-control
/// failure (VARIANT) a human should inspect; `3` = indeterminate — no
/// transcript matched any corpus case (wrong file or empty run, not a
/// measured zero).
enum ToolLoopCommand {

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) {
        var corpusPath: String?
        var responsesPath: String?
        var title = "tool-loop"
        var outPath: String?

        func value(_ index: inout Int, _ flag: String) -> String {
            index += 1
            guard index < args.count else { die("\(flag) requires a value", 2) }
            return args[index]
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--corpus":
                corpusPath = value(&index, token)
            case "--responses":
                responsesPath = value(&index, token)
            case "--title":
                title = value(&index, token)
            case "--out":
                outPath = value(&index, token)
            default:
                if token.hasPrefix("--") { die("unknown flag '\(token)'", 2) }
                die("unexpected argument '\(token)' — expected a flag", 2)
            }
            index += 1
        }

        guard let responsesPath else { die("toolloop requires --responses <transcripts.jsonl>", 2) }

        let cases: [ToolLoopCase]
        do {
            cases = try ToolLoopCorpus.load(path: corpusPath)
        } catch {
            die("toolloop: \(error)", 1)
        }
        guard !cases.isEmpty else { die("toolloop: corpus is empty", 1) }

        let transcripts: [ToolLoopTranscriptEntry]
        do {
            let url = URL(fileURLWithPath: (responsesPath as NSString).expandingTildeInPath)
            transcripts = try ToolLoopTranscriptEntry.loadJSONL(from: url)
        } catch {
            die("toolloop: \(error)", 1)
        }

        // Orphan transcript ids are a symptom of scoring against a different
        // corpus than the one generated — the exact id-namespace mismatch the
        // shared-corpus discipline exists to prevent. Surface loudly.
        let knownIDs = Set(cases.map(\.id))
        let orphans = Set(transcripts.map(\.id)).subtracting(knownIDs).sorted()
        if !orphans.isEmpty {
            warn(
                "toolloop: \(orphans.count) transcript id(s) match no corpus case and were ignored: "
                + orphans.joined(separator: ", ")
                + " — was this file generated against a different corpus?"
            )
        }

        let matched = transcripts.filter { knownIDs.contains($0.id) }
        guard !matched.isEmpty else {
            warn("toolloop: no transcript matched any corpus case — nothing was measured")
            exit(3)
        }

        let result = ToolLoopLane().score(cases: cases, transcripts: matched)
        let corpusLabel = corpusPath.map { "file: \($0)" } ?? "built-in scaffold"
        let markdown = ToolLoopReport.render(result: result, title: title, corpusLabel: corpusLabel)

        if let outPath {
            do {
                try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                die("toolloop: writing \(outPath): \(error)", 1)
            }
            print(
                "tool-loop: \(result.passed)/\(result.total) case(s) passed"
                + (result.variant > 0 ? ", \(result.variant) VARIANT" : "")
                + (result.missing > 0 ? ", \(result.missing) not measured" : "")
                + " → \(outPath)"
            )
        } else {
            print(markdown)
        }

        exit(result.allPassed && result.variant == 0 ? 0 : 1)
    }
}
