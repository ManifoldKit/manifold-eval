import Foundation
import ManifoldEval
import ManifoldInference
import ManifoldOllama

/// The `toolloop-generate` subcommand — the multi-turn lane's LIVE consumer.
///
/// Drives a live Ollama model over every corpus case with the case's
/// ``ScriptedTool``s registered in a real `ToolRegistry`, so the production
/// dispatch loop executes tools and threads their results across turns —
/// then records one ``ToolLoopTranscriptEntry`` JSON object per line: the
/// exact schema `toolloop --responses` scores. This is deliberately NOT the
/// BFCL capture-only shape: an empty registry can never exercise (or catch a
/// bug in) turn-2 result threading, which is the entire point of the lane.
///
/// Usage:
///
///     manifold-eval toolloop-generate --ollama-model <tag> --out <transcripts.jsonl>
///                                     [--corpus <cases.jsonl>] [--repeats N] [--ollama-url URL]
///                                     [--max-tool-iterations N] [--timeout SECONDS]
///
/// `--ollama-model`       Ollama model tag to drive (alias: `--model`).
/// `--out`                Path to write the transcript JSONL to.
/// `--corpus`             Corpus JSONL (one ToolLoopCase per line). Omit for
///                        the built-in scaffold `toolloop` also defaults to.
/// `--repeats`            Episodes per case. Default: 3 — the determinism
///                        control; the scorer flags cross-repeat variance.
/// `--ollama-url`         Ollama server base URL. Default: `http://localhost:11434`.
/// `--max-tool-iterations` Dispatch-loop turn budget per episode. Default: 4.
/// `--timeout`            Per-episode deadline in seconds. Default: 180
///                        (episodes span multiple generations, so the BFCL
///                        per-call 120s would under-budget a healthy chain).
enum ToolLoopGenerateCommand {

    @MainActor
    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
        var ollamaModel: String?
        var corpusPath: String?
        var rawOutPath: String?
        var ollamaURLString = "http://localhost:11434"
        var repeats = 3
        var maxToolIterations = 4
        var timeoutSeconds: Double = 180

        func value(_ index: inout Int, _ flag: String) -> String {
            index += 1
            guard index < args.count else { die("\(flag) requires a value", 2) }
            return args[index]
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--ollama-model", "--model":
                ollamaModel = value(&index, token)
            case "--corpus":
                corpusPath = value(&index, token)
            case "--out":
                rawOutPath = value(&index, token)
            case "--ollama-url":
                ollamaURLString = value(&index, token)
            case "--repeats":
                let raw = value(&index, token)
                guard let n = Int(raw), n > 0 else {
                    die("--repeats requires a positive integer, got '\(raw)'", 2)
                }
                repeats = n
            case "--max-tool-iterations":
                let raw = value(&index, token)
                guard let n = Int(raw), n > 0 else {
                    die("--max-tool-iterations requires a positive integer, got '\(raw)'", 2)
                }
                maxToolIterations = n
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

        guard let ollamaModel else { die("toolloop-generate requires --ollama-model <tag>", 2) }
        guard let rawOutPath else { die("toolloop-generate requires --out <transcripts.jsonl>", 2) }
        let outPath = (rawOutPath as NSString).expandingTildeInPath

        guard let ollamaURL = URL(string: ollamaURLString), ollamaURL.scheme != nil else {
            die("--ollama-url is not a valid URL: '\(ollamaURLString)'", 2)
        }

        let cases: [ToolLoopCase]
        do {
            cases = try ToolLoopCorpus.load(path: corpusPath)
        } catch {
            die("toolloop-generate: \(error)", 1)
        }
        guard !cases.isEmpty else { die("toolloop-generate: corpus is empty", 1) }

        // One backend, loaded once, shared across the run (the bfcl-generate
        // construction — see that command for why direct `OllamaBackend`
        // construction is right-sized here). A FRESH InferenceService +
        // ToolRegistry is built per case so each episode advertises and
        // dispatches exactly its own scripted tools — no cross-case leakage.
        let ollama = OllamaBackend(urlSession: nil)
        ollama.configure(baseURL: ollamaURL, modelName: ollamaModel)
        do {
            try await ollama.loadModel(from: ollamaURL, plan: .cloud())
        } catch {
            die("toolloop-generate: failed to load Ollama model '\(ollamaModel)': \(error)", 1)
        }

        warn(
            "toolloop-generate: driving '\(ollamaModel)' over \(cases.count) case(s) × \(repeats) repeat(s)"
            + " (corpus: \(corpusPath ?? "built-in scaffold"))"
        )

        // Stream JSONL to disk as each episode completes so an interrupted
        // run banks everything generated so far (same policy as the other
        // generators).
        guard FileManager.default.createFile(atPath: outPath, contents: nil),
              let fileHandle = FileHandle(forWritingAtPath: outPath) else {
            die("toolloop-generate: cannot open '\(outPath)' for writing", 1)
        }
        defer {
            do {
                try fileHandle.close()
            } catch {
                warn("toolloop-generate: failed to close '\(outPath)' cleanly: \(error)")
            }
        }
        let encoder = JSONEncoder()

        let result = await ToolLoopLane().generateTranscripts(
            cases: cases,
            repeats: repeats,
            onProgress: { warn($0) },
            onEntry: { entry in
                do {
                    let data = try encoder.encode(entry)
                    fileHandle.write(data)
                    fileHandle.write(Data("\n".utf8))
                } catch {
                    warn("toolloop-generate: failed to encode entry for '\(entry.id)': \(error)")
                }
            },
            emit: { toolLoopCase, repeatIndex in
                let registry = ToolRegistry(
                    tools: toolLoopCase.tools.map { ScriptedTool(spec: $0) }
                )
                let service = InferenceService(
                    backend: ollama, name: "ollama", modelName: ollamaModel, toolRegistry: registry
                )
                return try await ToolLoopEpisodeDriver.recordEpisode(
                    for: toolLoopCase,
                    repeatIndex: repeatIndex,
                    service: service,
                    maxToolIterations: maxToolIterations,
                    timeoutSeconds: timeoutSeconds
                )
            }
        )

        warn(
            "toolloop-generate: wrote \(result.entries.count) episode(s) to \(outPath)"
            + " (\(result.errored) errored/timed out)"
        )
        print(
            "tool-loop generate: \(result.entries.count) episode(s) recorded, "
            + "\(result.errored) errored → \(outPath)"
        )
    }
}
