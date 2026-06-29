import Foundation

/// Invokes an external eval runner as a subprocess and decodes the ``RawRun`` it
/// emits on stdout.
///
/// This is the *only* coupling to manifold-llama: the llama leg is a separate repo
/// (built in parallel, P2.2) that manifold-eval must never link — `llama_backend_init`
/// is once-per-process (plan §2.2). The contract is a subprocess boundary: the
/// runner is invoked with the fixed flags below and emits one `RawRun` JSON object
/// on stdout. Anything on stderr is forwarded to the harness's stderr as diagnostics.
///
/// Fixed flag surface (the contract — do not extend without changing both repos):
///
///     <command> --model <gguf> --prompt-file <path> --temperature <d> \
///               --seed <n> --max-tokens <n> --repeat-index <n>
public struct LlamaRunnerDriver: Sendable {
    /// The runner command. May be multi-token (e.g.
    /// `"swift run --package-path ../manifold-llama eval-runner"`); it is executed
    /// via `/bin/sh -c` so a full command line works. Dynamic values (paths,
    /// model) are shell-quoted before interpolation.
    public let command: String

    public init(command: String) {
        self.command = command
    }

    public func run(
        modelArg: String,
        promptFile: URL,
        sampler: SamplerConfig,
        repeatIndex: Int
    ) async throws -> RawRun {
        let invocation = command
            + " --model " + Self.shellQuote(modelArg)
            + " --prompt-file " + Self.shellQuote(promptFile.path)
            + " --temperature " + String(sampler.temperature)
            + " --seed " + String(sampler.seed)
            + " --max-tokens " + String(sampler.maxTokens)
            + " --repeat-index " + String(repeatIndex)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", invocation]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw DifferentialError.runnerLaunchFailed(command: command, reason: "\(error)")
        }

        // Read both pipes fully before waiting, so a runner that fills a pipe
        // buffer can't deadlock against our wait.
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""
        if !stderrString.isEmpty {
            FileHandle.standardError.write(Data("[llama-runner] \(stderrString)\n".utf8))
        }

        guard process.terminationStatus == 0 else {
            throw DifferentialError.runnerNonZeroExit(
                command: command,
                code: process.terminationStatus,
                stderr: stderrString
            )
        }

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? "<non-utf8 stdout>"
        do {
            return try JSONDecoder().decode(RawRun.self, from: stdoutData)
        } catch {
            throw DifferentialError.runnerDecodeFailed(
                command: command,
                reason: "\(error)",
                stdout: stdoutString
            )
        }
    }

    /// Single-quote a value for `/bin/sh`, escaping embedded single quotes.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
