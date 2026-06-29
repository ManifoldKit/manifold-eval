import Foundation

/// Inputs for one `manifold-eval diff` run.
public struct DifferentialConfig: Sendable {
    /// The Ollama model tag for the Ollama leg (e.g. `"llama3.1-8b:latest"`).
    public var ollamaModel: String
    /// The exact prompt STRING fed to every leg — the same-bytes anchor.
    public var prompt: String
    public var sampler: SamplerConfig
    public var repeats: Int
    /// Optional external runner command (manifold-llama). When `nil`, the run is
    /// Ollama-only (a determinism control); cross-backend triage needs both legs.
    public var llamaRunner: String?
    /// The `--model` value passed to the runner (a GGUF path). Defaults to
    /// `ollamaModel` when unset.
    public var llamaModelArg: String?
    public var bos: BOSNormalization
    /// Operator-declared cohort when the weights are known to be pinned; falls back
    /// to the heuristic classifier when `nil` (see ``Cohort/classify(_:_:cloudBackends:)``).
    public var cohortOverride: Cohort?

    public init(
        ollamaModel: String,
        prompt: String,
        sampler: SamplerConfig = .greedy,
        repeats: Int = 3,
        llamaRunner: String? = nil,
        llamaModelArg: String? = nil,
        bos: BOSNormalization = .autoDetect,
        cohortOverride: Cohort? = nil
    ) {
        self.ollamaModel = ollamaModel
        self.prompt = prompt
        self.sampler = sampler
        self.repeats = repeats
        self.llamaRunner = llamaRunner
        self.llamaModelArg = llamaModelArg
        self.bos = bos
        self.cohortOverride = cohortOverride
    }
}

/// The result of a `diff` run: per-leg determinism reports plus the cross-backend
/// comparison (present only when a second leg ran).
public struct DifferentialOutcome: Sendable, Equatable {
    public let promptSha256: String
    public let ollama: DeterminismReport
    public let llama: DeterminismReport?
    public let comparison: DifferentialRecord?

    public init(
        promptSha256: String,
        ollama: DeterminismReport,
        llama: DeterminismReport?,
        comparison: DifferentialRecord?
    ) {
        self.promptSha256 = promptSha256
        self.ollama = ollama
        self.llama = llama
        self.comparison = comparison
    }
}

/// Orchestrates a differential run: drive the Ollama leg N times, optionally drive
/// the external runner N times against the *same* prompt file, then triage.
public struct DifferentialHarness: Sendable {
    let ollamaDriver: OllamaRawDriver

    public init(ollamaDriver: OllamaRawDriver) {
        self.ollamaDriver = ollamaDriver
    }

    public func run(_ config: DifferentialConfig) async throws -> DifferentialOutcome {
        let promptSha = PromptHash.sha256Hex(of: config.prompt)

        let ollamaReport = try await DeterminismHarness.measure(repeats: config.repeats) { index in
            try await ollamaDriver.run(
                model: config.ollamaModel,
                prompt: config.prompt,
                sampler: config.sampler,
                repeatIndex: index
            )
        }

        guard let runnerCommand = config.llamaRunner else {
            // Ollama-only: a determinism control, no cross-backend comparison.
            return DifferentialOutcome(
                promptSha256: promptSha,
                ollama: ollamaReport,
                llama: nil,
                comparison: nil
            )
        }

        // Write the SAME prompt bytes to a temp file once and hand it to every
        // runner repeat — the runner's contract takes a --prompt-file, and reusing
        // one file guarantees the bytes are identical across repeats.
        let promptFile = try writeTempPrompt(config.prompt)
        defer { try? FileManager.default.removeItem(at: promptFile) }

        let runner = LlamaRunnerDriver(command: runnerCommand)
        let modelArg = config.llamaModelArg ?? config.ollamaModel
        let llamaReport = try await DeterminismHarness.measure(repeats: config.repeats) { index in
            try await runner.run(
                modelArg: modelArg,
                promptFile: promptFile,
                sampler: config.sampler,
                repeatIndex: index
            )
        }

        let comparison = DifferentialRecord.compare(
            ollamaReport,
            llamaReport,
            bos: config.bos,
            cohortOverride: config.cohortOverride
        )

        return DifferentialOutcome(
            promptSha256: promptSha,
            ollama: ollamaReport,
            llama: llamaReport,
            comparison: comparison
        )
    }

    private func writeTempPrompt(_ prompt: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("manifold-eval-prompt-\(UUID().uuidString).txt")
        do {
            try Data(prompt.utf8).write(to: url)
        } catch {
            throw DifferentialError.promptSourceUnreadable(path: url.path, reason: "writing temp prompt: \(error)")
        }
        return url
    }
}
