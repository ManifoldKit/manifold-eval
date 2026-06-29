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

        // Drain BOTH pipes CONCURRENTLY before waiting. llama.cpp logs heavily to
        // stderr; reading stdout to EOF first (or stderr only after stdout) lets the
        // child wedge: once its stderr pipe buffer (~64 KB) fills, the child blocks
        // writing stderr, never closes stdout, and the parent blocks forever on the
        // stdout read. Reading both at once on separate threads keeps both buffers
        // draining, so the child can always make progress regardless of stderr
        // volume.
        let (stdoutData, stderrData) = Self.drainConcurrently(
            stdout: stdoutPipe.fileHandleForReading,
            stderr: stderrPipe.fileHandleForReading
        )
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

    /// Reads two file handles to EOF concurrently and returns their bytes. Each
    /// handle is drained on its own queue so neither can back-pressure the child
    /// into a deadlock (see `run` for the failure mode this prevents). The
    /// `group.wait()` join establishes the happens-before edge that makes reading
    /// the boxes back here race-free.
    private static func drainConcurrently(
        stdout: FileHandle,
        stderr: FileHandle
    ) -> (stdout: Data, stderr: Data) {
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "manifold-eval.llama-runner-drain", attributes: .concurrent)
        queue.async(group: group) { outBox.set(stdout.readDataToEndOfFile()) }
        queue.async(group: group) { errBox.set(stderr.readDataToEndOfFile()) }
        group.wait()
        return (outBox.value, errBox.value)
    }
}

/// A lock-guarded byte buffer so the two concurrent pipe-drain tasks can each
/// publish their result and the joining thread can read it back. `@unchecked
/// Sendable` is sound only because every access is serialised by the lock (CLAUDE.md
/// concurrency gotcha #2: a real lock, not a bare mutable capture).
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) {
        lock.lock()
        defer { lock.unlock() }
        data = value
    }
    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return data
    }
}
