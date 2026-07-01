import Foundation
import ManifoldEval
import ManifoldInference
import ManifoldOllama
import ManifoldTools

/// The `bfcl-generate` subcommand: drives a live Ollama model through the
/// BFCL Gorilla corpus and writes one `BFCLResponseEntry` JSON object per line
/// — the exact schema `bfcl --responses` scores.
///
/// Generate and score share ``BFCLLane``'s corpus loader
/// (`BFCLLane.loadCases`, via `generateResponses`), so case ids and corpus
/// layout are identical by construction — there is no separate reshape step
/// and no id-namespace mismatch between the two commands.
///
/// This is a CAPTURE-ONLY pass: the tool registry is empty, so the model's
/// first tool call is observed and recorded, never dispatched/executed —
/// mirroring ManifoldKit's own `manifold-tools bfcl` / `BFCLRunner`.
///
/// Usage:
///
///     manifold-eval bfcl-generate --ollama-model <tag> [--category simple|multiple|parallel|parallel_multiple|irrelevance|all]
///                                 [--ollama-url URL] [--cache-dir DIR] --out <responses.jsonl> [--timeout SECONDS]
///
/// `--category`     One or more of `simple|multiple|parallel|parallel_multiple|irrelevance`
///                  (comma-separated) or `all`. Default: `multiple`.
/// `--ollama-model` Ollama model tag to drive (alias: `--model`).
/// `--ollama-url`   Ollama server base URL. Default: `http://localhost:11434`.
/// `--cache-dir`    Gorilla v4 corpus download/cache directory. Default: `~/.cache/manifold-eval/bfcl`.
/// `--out`          Path to write the response JSONL to.
/// `--timeout`      Per-case generation deadline in seconds. Default: 120 (matches `BFCLRunner`).
enum BFCLGenerateCommand {

    @MainActor
    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
        var ollamaModel: String?
        var categoryArg = "multiple"
        var ollamaURLString = "http://localhost:11434"
        var cacheDirPath = "~/.cache/manifold-eval/bfcl"
        var outPath: String?
        var timeoutSeconds: Double = 120

        func value(_ index: inout Int, _ flag: String) -> String {
            index += 1
            guard index < args.count else { die("\(flag) requires a value", 2) }
            return args[index]
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--category":
                categoryArg = value(&index, token)
            case "--ollama-model", "--model":
                ollamaModel = value(&index, token)
            case "--ollama-url":
                ollamaURLString = value(&index, token)
            case "--cache-dir":
                cacheDirPath = value(&index, token)
            case "--out":
                outPath = value(&index, token)
            case "--timeout":
                let raw = value(&index, token)
                guard let t = Double(raw), t > 0 else {
                    die("--timeout requires a positive number, got '\(raw)'", 2)
                }
                timeoutSeconds = t
            default:
                if token.hasPrefix("--") { die("unknown flag '\(token)'", 2) }
                die("unexpected argument '\(token)' — expected a flag", 2)
            }
            index += 1
        }

        guard let ollamaModel else { die("bfcl-generate requires --ollama-model <tag>", 2) }
        guard let outPath else { die("bfcl-generate requires --out <responses.jsonl>", 2) }

        let categories: [BFCLCategory]
        do {
            categories = try BFCLCategory.parseList(categoryArg)
        } catch {
            die("bfcl-generate: \(error)", 2)
        }

        guard let ollamaURL = URL(string: ollamaURLString), ollamaURL.scheme != nil else {
            die("--ollama-url is not a valid URL: '\(ollamaURLString)'", 2)
        }

        let cacheDir = URL(fileURLWithPath: (cacheDirPath as NSString).expandingTildeInPath)

        // --- Build a live Ollama-backed InferenceService (capture-only: empty tool registry) ---
        //
        // `OllamaBackend(_registrar:)` (used by ManifoldKit's own `manifold-tools
        // bfcl`) is `package`-scoped and unreachable from an external consumer
        // like this repo. The public `init(urlSession:)` is deprecated in favor
        // of the app-level registrar/`quickStart` path, but that path is for
        // multi-backend `ModelRegistry` dispatch — overkill for a one-shot,
        // single-model capture harness. Direct construction (same as the
        // deprecation notice's own fallback) is the right-sized tool here.
        let ollama = OllamaBackend(urlSession: nil)
        ollama.configure(baseURL: ollamaURL, modelName: ollamaModel)
        do {
            try await ollama.loadModel(from: ollamaURL, plan: .cloud())
        } catch {
            die("bfcl-generate: failed to load Ollama model '\(ollamaModel)': \(error)", 1)
        }
        // Empty registry: we capture the model's first tool call and score it
        // elsewhere; we never dispatch/execute it. Tools are advertised via
        // GenerationConfig inside BFCLRunner.emittedCalls.
        let service = InferenceService(backend: ollama, name: "ollama", modelName: ollamaModel, toolRegistry: ToolRegistry())

        warn(
            "bfcl-generate: driving '\(ollamaModel)' over "
            + "\(categories.map(\.rawValue).joined(separator: ", ")) (cache: \(cacheDir.path))"
        )

        // --- Stream JSONL to disk as each case completes ---
        //
        // A full-corpus run is potentially 1,235 cases at up to 120s/case — a
        // multi-hour operation. Writing each entry as it completes (rather than
        // buffering to the end) means a crash or Ctrl-C partway through banks
        // everything generated so far instead of losing the whole run.
        guard FileManager.default.createFile(atPath: outPath, contents: nil),
              let fileHandle = FileHandle(forWritingAtPath: outPath) else {
            die("bfcl-generate: cannot open '\(outPath)' for writing", 1)
        }
        defer { try? fileHandle.close() }
        let encoder = JSONEncoder()

        // `emit` below is `@Sendable`; a captured `var` can't cross into
        // concurrently-executing code, so snapshot it into a `let` first.
        let perCaseTimeout = timeoutSeconds

        let lane = BFCLLane()
        let result = await lane.generateResponses(
            categories: categories,
            corpusSource: .gorilla(cacheDir: cacheDir),
            onProgress: { warn($0) },
            onEntry: { entry in
                do {
                    let data = try encoder.encode(entry)
                    fileHandle.write(data)
                    fileHandle.write(Data("\n".utf8))
                } catch {
                    warn("bfcl-generate: failed to encode entry for '\(entry.id)': \(error)")
                }
            },
            emit: { testCase in
                try await BFCLRunner.emittedCalls(for: testCase, service: service, timeoutSeconds: perCaseTimeout)
            }
        )

        warn("bfcl-generate: wrote \(result.entries.count) entries to \(outPath) (\(result.errored) errored/timed out)")
        print(
            "BFCL generate: \(result.attempted) case(s) attempted, \(result.errored) errored → \(outPath)"
        )
    }
}
