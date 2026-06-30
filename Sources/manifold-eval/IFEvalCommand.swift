import Foundation
import ManifoldEval

/// The `ifeval` subcommand: score pre-computed model responses against the IFEval corpus.
///
/// Usage:
///
///     manifold-eval ifeval --corpus <path> --responses <jsonl-file> [--out <report.md>]
///
/// `--corpus`   Path to an IFEval corpus JSONL file (e.g. the full 541-case dataset).
/// `--responses` Path to a responses JSONL file; each line: `{"key":"...","response":"..."}`.
///              Cases missing from the responses file are scored against an empty string.
/// `--out`      Write the Markdown report to this file instead of stdout.
enum IFEvalCommand {

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) {
        var corpusPath: String?
        var responsesPath: String?
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
            case "--corpus":   corpusPath    = value(&index, token)
            case "--responses": responsesPath = value(&index, token)
            case "--out":      outPath        = value(&index, token)
            default:
                if token.hasPrefix("--") { die("unknown flag '\(token)'", 2) }
                die("unexpected argument '\(token)' — expected a flag", 2)
            }
            index += 1
        }

        guard let corpusPath else { die("ifeval requires --corpus <path>", 2) }
        guard let responsesPath else {
            die(
                "ifeval requires --responses <jsonl-file>\n"
                + "  File format (one JSON object per line):\n"
                + "  {\"key\":\"<case-key>\",\"response\":\"<model output>\"}",
                2
            )
        }

        let corpusURL    = URL(fileURLWithPath: corpusPath)
        let responsesURL = URL(fileURLWithPath: responsesPath)

        let lane = IFEvalLane()
        let runResult: IFEvalLane.CLIRunResult
        do {
            runResult = try lane.cliRun(corpusURL: corpusURL, responsesURL: responsesURL)
        } catch {
            die("ifeval: \(error)", 1)
        }

        if let outPath {
            do {
                try runResult.markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                die("ifeval: writing \(outPath): \(error)", 1)
            }
            warn("wrote \(outPath)")
            let s = runResult.score
            print(
                "IFEval: \(s.passedCases)/\(s.totalCases) passed, "
                + "strict accuracy \(String(format: "%.1f", s.strictAccuracy * 100))%"
            )
        } else {
            print(runResult.markdown)
        }
    }
}
