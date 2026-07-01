import Foundation
import ManifoldEval
import ManifoldInference
import ManifoldOllama

/// The `ifeval-generate` subcommand: drives a live Ollama model through an
/// IFEval corpus and writes one `IFEvalResponseEntry` JSON object per line —
/// the exact schema `ifeval --responses` scores.
///
/// Generate and score share the corpus decode shape (`IFEvalCorpus.load`) and
/// the responses schema (`IFEvalResponseEntry`), so a generate run and a
/// later score run always see identical case keys — there is no separate
/// reshape step and no key-namespace mismatch between the two commands.
///
/// Unlike `bfcl-generate` (sequential — BFCL cases share a tool registry),
/// IFEval cases are independent single-turn text generations, so this fans
/// out up to `--concurrency` cases at once, each against its OWN
/// `InferenceService`/`OllamaBackend` pair (one per worker slot) — a single
/// shared service's `GenerationQueue` is FIFO, so sharing one across workers
/// would silently serialize them and defeat `--concurrency`.
///
/// Resumable: if `--out` already exists, keys already present are loaded via
/// `IFEvalLane.loadResponses(from:)` and skipped; new entries are appended
/// (not overwritten), and each completed case is written to disk as soon as
/// it finishes — via a single actor serializing writes — so a crash or
/// Ctrl-C partway through a multi-hour full-corpus run banks everything
/// generated so far.
///
/// Usage:
///
///     manifold-eval ifeval-generate --ollama-model <tag> --corpus <path> --out <responses.jsonl>
///                                    [--ollama-url URL] [--max-tokens N] [--concurrency N] [--timeout SECONDS]
///
/// `--ollama-model` Ollama model tag to drive (alias: `--model`).
/// `--corpus`       Path to an IFEval corpus JSONL file (`{"key":...,"prompt":...}` per line).
/// `--out`          Path to write/append the response JSONL to.
/// `--ollama-url`   Ollama server base URL. Default: `http://localhost:11434`.
/// `--max-tokens`   Per-case generation cap. Default: 512 (matches the verified overnight run).
/// `--concurrency`  Max cases in flight at once. Default: 6 (matches the verified overnight run).
/// `--timeout`      Per-case generation deadline in seconds. Default: 120.
enum IFEvalGenerateCommand {

    @MainActor
    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: @escaping @Sendable (String) -> Void
    ) async {
        let options: IFEvalGenerateOptions
        do {
            options = try IFEvalGenerateOptions.parse(args)
        } catch {
            die("ifeval-generate: \(error)", 2)
        }

        // Expand `~` the same way other commands' path flags do, so
        // `--out ~/foo.jsonl` works instead of failing with a confusing
        // "cannot open for writing" error.
        let corpusPath = (options.corpusPath as NSString).expandingTildeInPath
        let outPath = (options.outPath as NSString).expandingTildeInPath

        guard let ollamaURL = URL(string: options.ollamaURLString), ollamaURL.scheme != nil else {
            die("--ollama-url is not a valid URL: '\(options.ollamaURLString)'", 2)
        }

        let corpusURL = URL(fileURLWithPath: corpusPath)
        let cases: [IFEvalCase]
        do {
            cases = try IFEvalCorpus.load(from: corpusURL)
        } catch {
            die("ifeval-generate: failed to load corpus '\(corpusPath)': \(error)", 1)
        }
        guard !cases.isEmpty else {
            die("ifeval-generate: corpus '\(corpusPath)' contains no cases", 1)
        }

        // --- Resumability: skip keys already present in --out ---
        var completedKeys: Set<String> = []
        if FileManager.default.fileExists(atPath: outPath) {
            do {
                completedKeys = Set(try IFEvalLane.loadResponses(from: URL(fileURLWithPath: outPath)).map(\.key))
            } catch {
                die("ifeval-generate: failed to read existing '\(outPath)' for resume: \(error)", 1)
            }
        } else {
            guard FileManager.default.createFile(atPath: outPath, contents: nil) else {
                die("ifeval-generate: cannot create '\(outPath)'", 1)
            }
        }
        guard let fileHandle = FileHandle(forWritingAtPath: outPath) else {
            die("ifeval-generate: cannot open '\(outPath)' for writing", 1)
        }
        fileHandle.seekToEndOfFile()
        defer {
            do {
                try fileHandle.close()
            } catch {
                warn("ifeval-generate: failed to close '\(outPath)' cleanly: \(error)")
            }
        }

        // --- Build one Ollama-backed InferenceService PER worker slot ---
        //
        // `GenerationQueue` (ManifoldInference) is a FIFO queue: a shared
        // `InferenceService` processes one generation at a time. To get REAL
        // concurrency against Ollama (the whole point of `--concurrency`),
        // each worker slot gets its own backend/service pair rather than
        // sharing one, mirroring how `bfcl-generate` builds a single service
        // (it never needs more than one — its loop is sequential by design).
        let workerCount = max(1, options.concurrency)
        var built: [InferenceService] = []
        for slot in 0..<workerCount {
            // `OllamaBackend(_registrar:)` (used by ManifoldKit's own
            // `manifold-tools bfcl`) is `package`-scoped and unreachable from
            // an external consumer like this repo. The public
            // `init(urlSession:)` is deprecated in favor of the app-level
            // registrar/`quickStart` path, but that path is for multi-backend
            // `ModelRegistry` dispatch — overkill for a one-shot,
            // fixed-model-per-worker capture harness. Direct construction
            // (same as the deprecation notice's own fallback, and the same
            // call `bfcl-generate` already makes) is the right-sized tool.
            let ollama = OllamaBackend(urlSession: nil)
            ollama.configure(baseURL: ollamaURL, modelName: options.ollamaModel)
            do {
                try await ollama.loadModel(from: ollamaURL, plan: .cloud())
            } catch {
                die("ifeval-generate: failed to load Ollama model '\(options.ollamaModel)' (worker \(slot)): \(error)", 1)
            }
            built.append(
                InferenceService(backend: ollama, name: "ollama-worker-\(slot)", modelName: options.ollamaModel, toolRegistry: ToolRegistry())
            )
        }
        // Captured by the `@Sendable` `emit` closure below — a `let` array of
        // Sendable `InferenceService` references, never mutated after this
        // point, so it's safe to share (read-only) across worker tasks.
        let services = built

        warn(
            "ifeval-generate: driving '\(options.ollamaModel)' over \(cases.count) case(s) from '\(corpusPath)' "
            + "(concurrency \(workerCount), max-tokens \(options.maxTokens), timeout \(Int(options.timeoutSeconds))s)"
        )

        // --- Stream JSONL to disk as each case completes ---
        //
        // A full 541-case run is a potentially multi-hour operation even with
        // concurrency. Writing each entry as it completes (through a single
        // actor that serializes appends) means concurrent workers' writes
        // never interleave/corrupt the file, and a crash partway through
        // banks everything generated so far instead of losing the whole run.
        let writer = ResponseWriter(fileHandle: fileHandle, warn: warn)

        let maxTokens = options.maxTokens
        let timeoutSeconds = options.timeoutSeconds

        let result = await IFEvalLane.generateResponses(
            cases: cases,
            completedKeys: completedKeys,
            concurrency: workerCount,
            onProgress: { warn($0) },
            onEntry: { entry in await writer.append(entry) },
            emit: { slot, testCase in
                try await Self.generateResponse(
                    prompt: testCase.prompt,
                    service: services[slot],
                    maxTokens: maxTokens,
                    timeoutSeconds: timeoutSeconds
                )
            }
        )

        warn("ifeval-generate: wrote \(result.entries.count) entries to \(outPath) (\(result.errored) errored/timed out)")
        print(
            "IFEval generate: \(result.attempted) case(s) attempted, \(result.errored) errored → \(outPath)"
        )
    }

    // MARK: - Per-case generation

    /// Drives one case through the production generation path (no tools —
    /// IFEval is plain instruction-following text) and returns the
    /// concatenated visible text. Greedy/deterministic (`temperature: 0`),
    /// matching every other lane in this repo.
    private static func generateResponse(
        prompt: String,
        service: InferenceService,
        maxTokens: Int,
        timeoutSeconds: Double
    ) async throws -> String {
        let config = GenerationConfig(
            temperature: 0.0,
            topP: 0.9,
            repeatPenalty: 1.1,
            topK: 1,
            maxOutputTokens: maxTokens,
            tools: [],
            maxToolIterations: 1
        )
        let (token, stream) = try await service.enqueue(messages: [.user(prompt)], systemPrompt: "", config: config)
        return try await withCaseTimeout(
            seconds: timeoutSeconds,
            cancel: { await service.cancel(token) },
            drain: {
                var text = ""
                for try await event in stream.events {
                    if case .token(let fragment) = event { text += fragment }
                }
                return text
            }
        )
    }

    /// Thrown when one case's generation exceeds the per-case timeout.
    private struct CaseTimeout: Error, CustomStringConvertible {
        let seconds: Double
        var description: String { "generation timed out after \(Int(seconds))s" }
    }

    /// Races a stream-drain against a deadline. On timeout, calls `cancel` —
    /// which must halt backend generation so the drain unblocks — and throws
    /// ``CaseTimeout``. Equivalent to ManifoldTools' `BFCLRunner.withCaseTimeout`,
    /// which is `internal` to that module and so can't be imported here;
    /// `cancel` is `async` (rather than that helper's synchronous closure)
    /// because `InferenceService.cancel` is `@MainActor`-isolated and this
    /// runs from concurrent, non-MainActor worker tasks.
    private static func withCaseTimeout(
        seconds: Double,
        cancel: @escaping @Sendable () async -> Void,
        drain: @escaping @Sendable () async throws -> String
    ) async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask { try await drain() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw CaseTimeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            do {
                guard let text = try await group.next() else { return "" }
                return text
            } catch {
                await cancel()
                throw error
            }
        }
    }
}

// MARK: - Serialized JSONL append

/// Serializes appends to the `--out` file so concurrent workers' completions
/// never interleave/corrupt it — the crash-resilience property `bfcl-generate`
/// established via streamed (not batched) writes, extended here to a
/// genuinely concurrent producer set.
private actor ResponseWriter {
    private let fileHandle: FileHandle
    private let warn: @Sendable (String) -> Void
    private let encoder = JSONEncoder()

    init(fileHandle: FileHandle, warn: @escaping @Sendable (String) -> Void) {
        self.fileHandle = fileHandle
        self.warn = warn
    }

    func append(_ entry: IFEvalResponseEntry) {
        do {
            let data = try encoder.encode(entry)
            fileHandle.write(data)
            fileHandle.write(Data("\n".utf8))
        } catch {
            warn("ifeval-generate: failed to encode entry for '\(entry.key)': \(error)")
        }
    }
}
