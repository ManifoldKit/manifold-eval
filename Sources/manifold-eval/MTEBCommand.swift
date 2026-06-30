import Foundation
import ManifoldEval

/// The `mteb` subcommand: run the MTEB-STS lane against an Ollama embedding model.
///
/// Usage:
///
///     manifold-eval mteb --dataset <path-or-fixture> [--ollama-model nomic-embed-text] [--out <report.md>]
///
/// `--dataset`      Path to a JSON file of `[{"sentence1":...,"sentence2":...,"goldScore":...}]`,
///                  or the literal string `fixture` to use the built-in 15-pair scaffold.
/// `--ollama-model` Ollama model tag to use for embedding (default: nomic-embed-text).
///                  If omitted, the subcommand prints instructions and exits 0.
/// `--out`          Write the Markdown report to this file instead of stdout.
enum MTEBCommand {

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
        var datasetPath: String?
        var ollamaModel: String?
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
            case "--dataset":      datasetPath = value(&index, token)
            case "--ollama-model": ollamaModel  = value(&index, token)
            case "--out":          outPath       = value(&index, token)
            default:
                if token.hasPrefix("--") { die("unknown flag '\(token)'", 2) }
                die("unexpected argument '\(token)' — expected a flag", 2)
            }
            index += 1
        }

        guard let datasetPath else { die("mteb requires --dataset <path-or-fixture>", 2) }

        // No embedder: explain what's needed and exit cleanly (not an error).
        guard let ollamaModel else {
            warn("mteb: no --ollama-model specified; skipping embedding run.")
            warn("  To score MTEB-STS, provide: --ollama-model nomic-embed-text")
            warn("  Ensure Ollama is running at localhost:11434 with the model loaded.")
            warn("  Example: manifold-eval mteb --dataset fixture --ollama-model nomic-embed-text")
            exit(0)
        }

        let pairs: [STSPair]
        let datasetLabel: String
        do {
            (pairs, datasetLabel) = try MTEBLane.loadPairsOrBuiltin(from: datasetPath)
        } catch {
            die("mteb: failed to load dataset at '\(datasetPath)': \(error)", 1)
        }
        warn("mteb: \(pairs.count) pairs from \(datasetLabel)")

        let driver = OllamaEmbeddingDriver(modelName: ollamaModel)
        let result: MTEBLaneResult
        do {
            result = try await MTEBLane.run(pairs: pairs, embedder: driver, modelName: ollamaModel)
        } catch {
            die("mteb: embedding run failed: \(error)", 1)
        }

        let markdown = MTEBLane.renderMarkdown(result: result)

        if let outPath {
            do {
                try markdown.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                die("mteb: writing \(outPath): \(error)", 1)
            }
            warn("wrote \(outPath)")
            print(
                "MTEB-STS: spearman=\(String(format: "%.4f", result.spearmanCorrelation)), "
                + "pearson=\(String(format: "%.4f", result.pearsonCorrelation)), "
                + "pairs=\(result.pairCount)"
            )
        } else {
            print(markdown)
        }
    }
}
