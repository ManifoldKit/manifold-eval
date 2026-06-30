import Foundation
import ManifoldEval

/// The `bfcl` subcommand: score pre-computed tool-call responses against the BFCL corpus.
///
/// Usage:
///
///     manifold-eval bfcl --corpus <dir> --responses <jsonl-file> [--out <report.md>]
///
/// `--corpus`   Directory containing BFCL fixture files
///              (`<category>_questions.jsonl`, `<category>_answers.jsonl`).
/// `--responses` Path to a tool-calls JSONL file; each line:
///              `{"id":"<case-id>","calls":[{"id":"...","toolName":"...","arguments":"..."},...]}`.
///              Cases absent from the file are scored with an empty call list
///              (irrelevance passes; all other categories count as failed).
/// `--out`      Write the Markdown report to this file instead of stdout.
enum BFCLCommand {

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
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
            case "--corpus":    corpusPath    = value(&index, token)
            case "--responses": responsesPath = value(&index, token)
            case "--out":       outPath        = value(&index, token)
            default:
                if token.hasPrefix("--") { die("unknown flag '\(token)'", 2) }
                die("unexpected argument '\(token)' — expected a flag", 2)
            }
            index += 1
        }

        guard let corpusPath else { die("bfcl requires --corpus <dir>", 2) }
        guard let responsesPath else {
            die(
                "bfcl requires --responses <jsonl-file>\n"
                + "  File format (one JSON object per line):\n"
                + "  {\"id\":\"<case-id>\",\"calls\":[{\"id\":\"...\",\"toolName\":\"...\",\"arguments\":\"...\"}]}",
                2
            )
        }

        let corpusDir    = URL(fileURLWithPath: corpusPath)
        let responsesURL = URL(fileURLWithPath: responsesPath)

        let lane = BFCLLane()
        let result: BFCLLane.LaneResult
        let markdown: String
        do {
            (result, markdown) = try await lane.cliRun(corpusDir: corpusDir, responsesURL: responsesURL)
        } catch {
            die("bfcl: \(error)", 1)
        }

        if let outPath {
            do {
                try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                die("bfcl: writing \(outPath): \(error)", 1)
            }
            warn("wrote \(outPath)")
            print(
                "BFCL: \(result.overallPassed)/\(result.overallTotal) passed, "
                + "accuracy \(String(format: "%.1f", result.overallAccuracy * 100))%"
            )
        } else {
            print(markdown)
        }
    }
}
