import Foundation
import ManifoldEval
import ManifoldTools

// Minimal hand-rolled argv parsing keeps the dependency surface to ManifoldKit
// alone (no ArgumentParser). Subcommands:
//
//   manifold-eval collate <record.json>... [--out PATH] [--title T]
//   manifold-eval diff    --model <tag> (--prompt-file P | --messages-file M --template-gguf G)
//                         [options…]
//   manifold-eval ifeval  --corpus <path> --responses <jsonl> [--out PATH]
//   manifold-eval ifeval-generate --ollama-model <tag> --corpus <path> --out <responses.jsonl>
//                         [--ollama-url URL] [--max-tokens N] [--concurrency N] [--timeout SECONDS]
//   manifold-eval bfcl    (--corpus <dir> | --gorilla-cache-dir <dir>) --responses <jsonl> [--out PATH]
//   manifold-eval bfcl-generate --ollama-model <tag> [--category simple|multiple|parallel|parallel_multiple|irrelevance|all]
//                         [--ollama-url URL] [--cache-dir DIR] --out <responses.jsonl> [--timeout SECONDS]
//   manifold-eval mteb    --dataset <path-or-fixture> [--ollama-model <tag>] [--out PATH]
//   manifold-eval regress --backend ollama|llama --baseline-model M --redriven-model M
//                         --prompt-file P --expected REF [options…]

func die(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(code)
}

func warn(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let subcommand = arguments.first else {
    print("usage:")
    print("  manifold-eval collate <record.json>... [--out PATH] [--title T]")
    print("  manifold-eval diff --model <ollama-tag> (--prompt-file P | --messages-file M --template-gguf G)")
    print("                     [--llama-runner CMD] [--llama-model GGUF] [--repeats N] [--seed N]")
    print("                     [--max-tokens N] [--temperature D] [--top-k N] [--repeat-penalty D] [--bos ID]")
    print("                     [--cohort sameWeights|sameFamily|cloud] [--ollama-url URL]")
    print("                     [--core-commit SHA] [--out DIVERGENCE.md]")
    print("  manifold-eval ifeval --corpus <path> --responses <jsonl> [--out PATH]")
    print("  manifold-eval ifeval-generate --ollama-model <tag> --corpus <path> --out <responses.jsonl>")
    print("                     [--ollama-url URL] [--max-tokens N] [--concurrency N] [--timeout SECONDS]")
    print("  manifold-eval bfcl   (--corpus <dir> | --gorilla-cache-dir <dir>) --responses <jsonl> [--out PATH]")
    print("  manifold-eval bfcl-generate --ollama-model <tag> [--category simple|multiple|parallel|parallel_multiple|irrelevance|all]")
    print("                     [--ollama-url URL] [--cache-dir DIR] --out <responses.jsonl> [--timeout SECONDS]")
    print("  manifold-eval mteb   --dataset <path-or-fixture> [--ollama-model nomic-embed-text] [--out PATH]")
    print("  manifold-eval regress --backend ollama|llama --baseline-model M --redriven-model M")
    print("                     --prompt-file P --expected REF [--scorer contains|exact] [--ignore-case]")
    print("                     [--threshold D] [--seed N] [--max-tokens N] [--temperature D]")
    print("                     [--llama-runner CMD] [--ollama-url URL] [--core-commit SHA] [--out REGRESSION.md]")
    exit(2)
}

switch subcommand {
case "collate":
    var files: [URL] = []
    var outPath: String?
    var title: String?

    let rest = Array(arguments.dropFirst())
    var index = 0
    while index < rest.count {
        let token = rest[index]
        switch token {
        case "--out":
            index += 1
            guard index < rest.count else { die("--out requires a path", code: 2) }
            outPath = rest[index]
        case "--title":
            index += 1
            guard index < rest.count else { die("--title requires a value", code: 2) }
            title = rest[index]
        default:
            // An unrecognized `--flag` is a usage error, not a filename — otherwise
            // a typo'd flag (e.g. `--titel`) silently becomes a "record file" that
            // later fails as unreadable with a confusing message.
            if token.hasPrefix("--") {
                die("unknown flag '\(token)'", code: 2)
            }
            files.append(URL(fileURLWithPath: token))
        }
        index += 1
    }

    // Insufficient arguments is a usage error (exit 2), consistent with the
    // no-subcommand case — not a runtime error (exit 1).
    guard !files.isEmpty else {
        die("collate requires at least one record file", code: 2)
    }

    let result: CollationResult
    do {
        result = try Collator.collate(files: files)
    } catch {
        die("\(error)", code: 1)
    }

    // Diagnostics go to stderr so they're visible even when --out captures stdout.
    for diagnostic in result.diagnostics {
        warn("[\(diagnostic.severity.rawValue)] \(diagnostic.message)")
    }

    let markdown = CrossRuntimeMatrix.render(result, title: title ?? CrossRuntimeMatrix.defaultTitle)

    if let outPath {
        do {
            try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
        } catch {
            die("writing \(outPath): \(error)", code: 1)
        }
        print("wrote \(outPath)  (\(result.records.count) records; backends: \(result.backends.joined(separator: ", ")))")
    } else {
        print(markdown)
    }

    // Non-zero only on an error-severity diagnostic (e.g. empty corpus). Warnings
    // — mixed core commits, tooling drift — render and exit 0; they're advisory.
    exit(result.hasErrors ? 1 : 0)

case "diff":
    // Top-level `await` is permitted in main.swift (implicit async main). The diff
    // orchestration lives in DiffCommand to keep this dispatch readable.
    await DiffCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

case "ifeval":
    IFEvalCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

case "ifeval-generate":
    await IFEvalGenerateCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

case "bfcl":
    await BFCLCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

case "bfcl-generate":
    // Drives a live Ollama model over the BFCL corpus and writes the
    // BFCLResponseEntry JSONL that `bfcl` scores — the full-corpus generator
    // `bfcl`/`cliRun` never had. See BFCLGenerateCommand.
    await BFCLGenerateCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

case "mteb":
    await MTEBCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

case "regress":
    // The replay-regression moat entry point (plan §8). Orchestration lives in
    // RegressCommand; the gate/runner/report it drives live in ManifoldEval/Replay.
    await RegressCommand.run(Array(arguments.dropFirst()), die: die, warn: warn)

default:
    die("unknown subcommand '\(subcommand)' (expected: collate, diff, ifeval, ifeval-generate, bfcl, bfcl-generate, mteb, regress)", code: 2)
}
