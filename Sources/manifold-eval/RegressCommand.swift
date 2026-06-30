import Foundation
import ManifoldEval

/// The `regress` subcommand: the end-to-end entry point for the replay-regression
/// moat (plan §8). Capture a baseline run, re-drive the SAME prompt against a
/// *different quant* (or build) of the model on the same backend, score both, and
/// run them through ``RegressionGate`` — emitting a deterministic `REGRESSION.md`
/// and a verdict-shaped exit code.
///
/// Cross-quant is the card core can't play: re-driving a captured session against
/// a re-quantised GGUF and detecting whether the score moved. Both legs run on one
/// backend (so quant is the only variable), greedy/temp=0 by default (the only
/// sampler the differential trusts).
///
///     manifold-eval regress --backend ollama \
///         --baseline-model qwen2.5:0.5b-instruct-q8_0 \
///         --redriven-model qwen2.5:0.5b-instruct-q4_K_M \
///         --prompt-file probe.txt --expected "4" [--scorer contains]
///
///     manifold-eval regress --backend llama --llama-runner "<cmd>" \
///         --baseline-model ./model-Q8_0.gguf --redriven-model ./model-Q4_K_M.gguf \
///         --prompt-file probe.txt --expected "Paris" --scorer exact
enum RegressCommand {

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
        var backend = "ollama"
        var baselineModel: String?
        var reDrivenModel: String?
        var promptFile: String?
        var expected: String?
        var scorerKind = "contains"
        var ignoreCase = false
        var threshold = 0.05
        var seed = 0
        var maxTokens = 128
        var temperature = 0.0
        var llamaRunner: String?
        var ollamaURLString = "http://localhost:11434"
        var coreCommit = "unknown"
        var outPath: String?

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
            case "--backend": backend = value(&index, token)
            case "--baseline-model": baselineModel = value(&index, token)
            case "--redriven-model": reDrivenModel = value(&index, token)
            case "--prompt-file": promptFile = value(&index, token)
            case "--expected": expected = value(&index, token)
            case "--scorer": scorerKind = value(&index, token)
            case "--ignore-case": ignoreCase = true
            case "--threshold":
                let raw = value(&index, token)
                guard let d = Double(raw) else { die("--threshold requires a number, got '\(raw)'", 2) }
                threshold = d
            case "--seed": seed = intValue(&index, token)
            case "--max-tokens": maxTokens = intValue(&index, token)
            case "--temperature":
                let raw = value(&index, token)
                guard let d = Double(raw) else { die("--temperature requires a number, got '\(raw)'", 2) }
                temperature = d
            case "--llama-runner": llamaRunner = value(&index, token)
            case "--ollama-url": ollamaURLString = value(&index, token)
            case "--core-commit": coreCommit = value(&index, token)
            case "--out": outPath = value(&index, token)
            default:
                die("unknown flag '\(token)'", 2)
            }
            index += 1
        }

        // --- Validate ---
        guard let baselineModel else { die("regress requires --baseline-model", 2) }
        guard let reDrivenModel else { die("regress requires --redriven-model", 2) }
        guard let promptFile else { die("regress requires --prompt-file", 2) }
        guard let expected else { die("regress requires --expected <reference answer>", 2) }
        guard backend == "ollama" || backend == "llama" else {
            die("--backend must be ollama|llama, got '\(backend)'", 2)
        }
        if backend == "llama" && llamaRunner == nil {
            die("--backend llama requires --llama-runner <command>", 2)
        }

        let scorer: any RegressionScorer
        switch scorerKind {
        case "exact":
            scorer = ExactMatchRegressionScorer(expected: expected, caseSensitive: !ignoreCase)
        case "contains":
            scorer = SubstringRegressionScorer(expected: expected, caseSensitive: !ignoreCase)
        default:
            die("--scorer must be exact|contains, got '\(scorerKind)'", 2)
        }

        // --- Resolve prompt bytes (the same-bytes anchor shared by both legs) ---
        let promptFileURL = URL(fileURLWithPath: promptFile)
        let prompt: String
        do {
            // Keep prompt files BOM-free: String(contentsOf:) strips a leading BOM,
            // which would desync the hashed bytes from what the llama runner reads
            // off the raw file (a false prompt mismatch). Same note as DiffCommand.
            prompt = try String(contentsOf: promptFileURL, encoding: .utf8)
        } catch {
            die("cannot read --prompt-file '\(promptFile)': \(error)", 1)
        }

        let sampler = SamplerConfig(temperature: temperature, seed: seed, maxTokens: maxTokens)
        let gate = RegressionGate(threshold: threshold)

        // --- Build the two capture thunks for the chosen backend ---
        // Both legs use the SAME prompt + SAME sampler, so the only variable is the
        // model/quant — which is the whole point. Same prompt → same promptSha256,
        // so the gate's same-bytes invariant holds within a backend.
        let captureBaseline: () async throws -> RawRun
        let captureReDriven: () async throws -> RawRun

        switch backend {
        case "ollama":
            guard let ollamaURL = URL(string: ollamaURLString), ollamaURL.scheme != nil else {
                die("--ollama-url is not a valid URL: '\(ollamaURLString)'", 2)
            }
            var toolingVersions: [String: String] = [:]
            do {
                toolingVersions["ollama"] = try await OllamaRawDriver(baseURL: ollamaURL).serverVersion()
            } catch {
                warn("could not read Ollama version (\(error)); recording 'unknown'")
                toolingVersions["ollama"] = "unknown"
            }
            let driver = OllamaRawDriver(
                baseURL: ollamaURL, coreCommit: coreCommit, toolingVersions: toolingVersions
            )
            captureBaseline = { try await driver.run(model: baselineModel, prompt: prompt, sampler: sampler, repeatIndex: 0) }
            captureReDriven = { try await driver.run(model: reDrivenModel, prompt: prompt, sampler: sampler, repeatIndex: 0) }
        case "llama":
            // llamaRunner non-nil checked above.
            let driver = LlamaRunnerDriver(command: llamaRunner!)
            captureBaseline = { try await driver.run(modelArg: baselineModel, promptFile: promptFileURL, sampler: sampler, repeatIndex: 0) }
            captureReDriven = { try await driver.run(modelArg: reDrivenModel, promptFile: promptFileURL, sampler: sampler, repeatIndex: 0) }
        default:
            die("internal: unhandled backend '\(backend)'", 1)
        }

        warn("regress: baseline='\(baselineModel)' vs re-driven='\(reDrivenModel)' on \(backend) (greedy temp=\(temperature))…")

        let outcome: RegressionOutcome
        do {
            outcome = try await RegressionRunner.run(
                gate: gate,
                scorer: scorer,
                captureBaseline: captureBaseline,
                captureReDriven: captureReDriven
            )
        } catch {
            die("\(error)", 1)
        }

        let report = RegressionReport.render(outcome)
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

        // Verdict-shaped exit code so CI/scripts can branch:
        //   0 = stable (no score movement)
        //   1 = moved (a human should judge quant drift vs regression)
        //   3 = indeterminate (a control failed — e.g. prompt mismatch / unscorable)
        switch outcome.verdict {
        case .stable: exit(0)
        case .moved: exit(1)
        case .indeterminate: exit(3)
        }
    }
}
