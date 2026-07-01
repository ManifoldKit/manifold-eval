import Foundation
import ManifoldEval

/// The `diff` subcommand: render/accept a prompt, drive Ollama N times (a
/// determinism control), optionally shell an external `--llama-runner` against the
/// SAME prompt bytes, triage, and emit a deterministic `DIVERGENCE.md`.
///
/// All diagnostics go to stderr; the report goes to stdout or `--out`, so the
/// report is never polluted by progress noise.
enum DiffCommand {

    /// The result of parsing `diff`'s argv — extracted from ``run`` so the flag
    /// grammar (including `--top-k` / `--repeat-penalty`) is unit-testable
    /// without touching the network (no Ollama probe, no harness run).
    struct ParsedArguments {
        var model: String?
        var promptFile: String?
        var messagesFile: String?
        var templateGGUF: String?
        var llamaRunner: String?
        var llamaModel: String?
        var repeats = 3
        var seed = 0
        var maxTokens = 128
        var temperature = 0.0
        var topK = 0
        var repeatPenalty = 1.0
        var bosID: Int?
        var cohort: Cohort?
        var ollamaURLString = "http://localhost:11434"
        var coreCommit = "unknown"
        var outPath: String?
    }

    /// Parses argv into ``ParsedArguments``. `die` is invoked (and never
    /// returns) on any malformed flag/value; well-formed argv returns without
    /// calling it.
    static func parseArguments(_ args: [String], die: (String, Int32) -> Never) -> ParsedArguments {
        var parsed = ParsedArguments()

        func value(_ index: inout Int, _ flag: String) -> String {
            index += 1
            guard index < args.count else { die("\(flag) requires a value", 2) }
            return args[index]
        }
        func intValue(_ index: inout Int, _ flag: String) -> Int {
            let raw = value(&index, flag)
            guard let n = Int(raw) else { die("\(flag) requires an integer, got '\(raw)'", 2) }
            return n
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--model": parsed.model = value(&index, token)
            case "--prompt-file": parsed.promptFile = value(&index, token)
            case "--messages-file": parsed.messagesFile = value(&index, token)
            case "--template-gguf": parsed.templateGGUF = value(&index, token)
            case "--llama-runner": parsed.llamaRunner = value(&index, token)
            case "--llama-model": parsed.llamaModel = value(&index, token)
            case "--repeats": parsed.repeats = intValue(&index, token)
            case "--seed": parsed.seed = intValue(&index, token)
            case "--max-tokens": parsed.maxTokens = intValue(&index, token)
            case "--temperature":
                let raw = value(&index, token)
                guard let d = Double(raw) else { die("--temperature requires a number, got '\(raw)'", 2) }
                parsed.temperature = d
            case "--top-k": parsed.topK = intValue(&index, token)
            case "--repeat-penalty":
                let raw = value(&index, token)
                guard let d = Double(raw) else { die("--repeat-penalty requires a number, got '\(raw)'", 2) }
                parsed.repeatPenalty = d
            case "--bos": parsed.bosID = intValue(&index, token)
            case "--cohort":
                let raw = value(&index, token)
                guard let c = Cohort(rawValue: raw) else {
                    die("--cohort must be sameWeights|sameFamily|cloud, got '\(raw)'", 2)
                }
                parsed.cohort = c
            case "--ollama-url": parsed.ollamaURLString = value(&index, token)
            case "--core-commit": parsed.coreCommit = value(&index, token)
            case "--out": parsed.outPath = value(&index, token)
            default:
                die("unknown flag '\(token)'", 2)
            }
            index += 1
        }
        return parsed
    }

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
        let parsed = parseArguments(args, die: die)
        let model = parsed.model
        let promptFile = parsed.promptFile
        let messagesFile = parsed.messagesFile
        let templateGGUF = parsed.templateGGUF
        let llamaRunner = parsed.llamaRunner
        let llamaModel = parsed.llamaModel
        let repeats = parsed.repeats
        let seed = parsed.seed
        let maxTokens = parsed.maxTokens
        let temperature = parsed.temperature
        let topK = parsed.topK
        let repeatPenalty = parsed.repeatPenalty
        let bosID = parsed.bosID
        let cohort = parsed.cohort
        let ollamaURLString = parsed.ollamaURLString
        let coreCommit = parsed.coreCommit
        let outPath = parsed.outPath

        // --- Validate argument combinations ---
        guard let model else { die("diff requires --model <ollama-tag>", 2) }
        guard repeats >= 1 else { die("--repeats must be >= 1", 2) }

        if (promptFile == nil) == (messagesFile == nil) {
            die("diff requires exactly one of --prompt-file or --messages-file", 2)
        }

        guard let ollamaURL = URL(string: ollamaURLString), ollamaURL.scheme != nil else {
            die("--ollama-url is not a valid URL: '\(ollamaURLString)'", 2)
        }

        // --- Resolve the prompt bytes (the same-bytes anchor) ---
        let prompt: String
        if let promptFile {
            do {
                // NOTE: `String(contentsOfFile:encoding:.utf8)` strips a leading
                // UTF-8 BOM. For a standalone llama run on a BOM'd prompt file the
                // hashed bytes here would then differ from the raw file bytes the
                // runner reads, surfacing as a false promptDivergence. Keep prompt
                // files BOM-free (the same-bytes anchor is the UTF-8 content).
                prompt = try String(contentsOfFile: promptFile, encoding: .utf8)
            } catch {
                die("cannot read --prompt-file '\(promptFile)': \(error)", 1)
            }
        } else if let messagesFile {
            guard let templateGGUF else {
                die("--messages-file requires --template-gguf <gguf> (the chat_template source)", 2)
            }
            do {
                let messages = try PromptRendering.decodeMessages(at: URL(fileURLWithPath: messagesFile))
                prompt = try PromptRendering.render(messages: messages, ggufURL: URL(fileURLWithPath: templateGGUF))
            } catch {
                die("\(error)", 1)
            }
        } else {
            // Unreachable given the XOR validation above, but the compiler can't
            // prove it — fail loudly rather than force-unwrap.
            die("internal: no prompt source resolved", 1)
        }

        // --- Build the harness ---
        // topK / repeatPenalty are exposed so an operator debugging a divergence
        // can explicitly force-match both legs' sampler config instead of being
        // stuck with the hardcoded neutral defaults (topK=0 "disabled",
        // repeatPenalty=1.0 "no-op") — see OllamaRawDriver's doc comments for why
        // these matter the moment either leg runs above temperature 0. Both
        // values reach BOTH legs: OllamaRawDriver's request body, and (as of a
        // PR #13 follow-up) LlamaRunnerDriver's `--top-k`/`--repeat-penalty`
        // flags to the external runner — see LlamaRunnerDriver's doc comment for
        // the invocation contract.
        let sampler = SamplerConfig(
            temperature: temperature,
            seed: seed,
            topK: topK,
            repeatPenalty: repeatPenalty,
            maxTokens: maxTokens
        )
        let bos: BOSNormalization = bosID.map { .explicit(bosID: $0) } ?? .autoDetect

        // Best-effort Ollama version for the tooling record — a failure here is a
        // diagnostic, not fatal (the differential still runs).
        var toolingVersions: [String: String] = [:]
        let probeDriver = OllamaRawDriver(baseURL: ollamaURL)
        do {
            toolingVersions["ollama"] = try await probeDriver.serverVersion()
        } catch {
            warn("could not read Ollama version (\(error)); recording 'unknown'")
            toolingVersions["ollama"] = "unknown"
        }

        let driver = OllamaRawDriver(
            baseURL: ollamaURL,
            coreCommit: coreCommit,
            toolingVersions: toolingVersions
        )
        let harness = DifferentialHarness(ollamaDriver: driver)
        let config = DifferentialConfig(
            ollamaModel: model,
            prompt: prompt,
            sampler: sampler,
            repeats: repeats,
            llamaRunner: llamaRunner,
            llamaModelArg: llamaModel,
            bos: bos,
            cohortOverride: cohort
        )

        warn("driving Ollama '\(model)' x\(repeats) at temp=\(temperature) (raw mode)…")
        if llamaRunner != nil {
            warn("driving external runner x\(repeats) against the same prompt…")
        }

        let outcome: DifferentialOutcome
        do {
            outcome = try await harness.run(config)
        } catch {
            die("\(error)", 1)
        }

        let report = DivergenceReport.render(outcome)

        if let outPath {
            do {
                try report.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                die("writing \(outPath): \(error)", 1)
            }
            warn("wrote \(outPath)")
        } else {
            print(report)
        }

        // Exit code reflects the verdict so CI/scripts can branch on it:
        //   0 = no actionable divergence (identical / samplerNondeterminism)
        //   1 = a control failure or genuine divergence a human should look at
        //       (promptDivergence / tokenizerDivergence / samplerMismatch /
        //        genuineDivergence), OR an Ollama-only determinism control that came
        //        back VARIANT (the control itself failed — N3)
        //   3 = indeterminate — a leg's determinism was never assessed; rerun with
        //       more --repeats (neither a clean pass nor a confirmed divergence)
        //   4 = degenerateRepetitionLengthMismatch — both outputs are the same
        //       repeating unit at different lengths, a stopping-length artifact.
        //       Non-zero (worth a look — why did the lengths differ?) but
        //       deliberately distinct from 1 so a script can tell "same content,
        //       different repeat count" apart from a genuine content divergence.
        guard let divergence = outcome.comparison?.divergence else {
            // Ollama-only run: no cross-backend comparison, just the determinism
            // control. A VARIANT control (assessed but not reproducible) is itself a
            // finding worth surfacing; a stable or unassessed control passes.
            if outcome.ollama.wasAssessed && !outcome.ollama.isDeterministic {
                warn("Ollama determinism control came back VARIANT — temp=0 not reproducible")
                exit(1)
            }
            exit(0)
        }
        switch divergence {
        case .promptDivergence, .tokenizerDivergence, .samplerMismatch, .genuineDivergence:
            exit(1)
        case .indeterminate:
            exit(3)
        case .degenerateRepetitionLengthMismatch:
            exit(4)
        case .identical, .samplerNondeterminism:
            exit(0)
        }
    }
}
