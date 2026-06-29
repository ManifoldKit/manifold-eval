import Foundation
import ManifoldEval
import ManifoldTools

// Minimal hand-rolled argv parsing keeps the dependency surface to ManifoldKit
// alone (no ArgumentParser). One subcommand today: `collate`.
//
//   manifold-eval collate <record.json>... [--out PATH] [--title T]
//
// Reads each file as a [ConformanceRecord] JSON array (the shape every eval leg
// emits via `manifold-tools score --emit-records`), collates them with the
// comparability guard, and renders the cross-runtime matrix to stdout or --out.

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
    print("                     [--max-tokens N] [--temperature D] [--bos ID]")
    print("                     [--cohort sameWeights|sameFamily|cloud] [--ollama-url URL]")
    print("                     [--core-commit SHA] [--out DIVERGENCE.md]")
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

default:
    die("unknown subcommand '\(subcommand)' (expected: collate, diff)", code: 2)
}
