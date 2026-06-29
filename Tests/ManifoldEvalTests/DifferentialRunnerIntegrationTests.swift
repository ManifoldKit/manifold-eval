import XCTest
@testable import ManifoldEval

/// Exercises the subprocess + hash-integration surface that fixture tests can't
/// reach: `LlamaRunnerDriver`'s flag construction, stdout/stderr separation,
/// non-zero-exit and malformed-JSON handling, the pipe-drain deadlock guard (B1),
/// and the lynchpin same-bytes property — the runner's temp prompt-file must hash
/// to the same `promptSha256` the Ollama leg records.
///
/// Uses a tiny `/bin/sh` stub written to a temp dir, so no real llama.cpp / Ollama
/// is needed; these run unconditionally on hosted CI.
final class DifferentialRunnerIntegrationTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("manifold-eval-runner-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    // MARK: - stub authoring

    /// Write an executable `/bin/sh` script and return its path.
    private func writeExecutable(_ body: String, name: String = "stub.sh") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try ("#!/bin/sh\n" + body).write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func writePrompt(_ text: String, name: String = "prompt.txt") throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// A happy-path stub: records its argv, floods stderr (to regression-guard the
    /// B1 pipe-drain deadlock), and emits a valid `RawRun` whose `promptSha256` is
    /// the SHA-256 of the `--prompt-file` contents — the lynchpin property.
    private func happyStub(argsOut: URL, output: String, stderrFloodLines: Int) -> String {
        """
        echo "$@" > '\(argsOut.path)'
        prompt_file=""
        while [ $# -gt 0 ]; do
          case "$1" in
            --prompt-file) prompt_file="$2"; shift 2 ;;
            *) shift ;;
          esac
        done
        i=0
        while [ $i -lt \(stderrFloodLines) ]; do
          echo "llama.cpp: loading tensors .................................. noise line $i" >&2
          i=$((i+1))
        done
        sha=$(shasum -a 256 "$prompt_file" | awk '{print $1}')
        cat <<EOF
        {"backend":"llama.cpp","model":"x.gguf","quant":"Q4_K_M","promptSha256":"$sha","inputTokenIds":[128000,1,2,3],"output":"\(output)","outputTokenIds":[9],"sampler":{"temperature":0.0,"seed":0,"topK":0,"repeatPenalty":1.0,"maxTokens":128},"coreCommit":"deadbeef","toolingVersions":{"llama.cpp":"b9999"},"repeatIndex":0}
        EOF
        """
    }

    // MARK: - LlamaRunnerDriver (a)

    func testRunnerHappyPathDecodesRawRunAndPassesFlags() async throws {
        let argsOut = scratch.appendingPathComponent("args.txt")
        let stub = try writeExecutable(happyStub(argsOut: argsOut, output: "Hello", stderrFloodLines: 10))
        let prompt = try writePrompt("2 + 2 =")

        let driver = LlamaRunnerDriver(command: Self.shellQuotePath(stub.path))
        let raw = try await driver.run(
            modelArg: "/models/x.gguf",
            promptFile: prompt,
            sampler: SamplerConfig(temperature: 0, seed: 7, maxTokens: 64),
            repeatIndex: 2
        )

        // stdout decoded into the RawRun contract.
        XCTAssertEqual(raw.backend, "llama.cpp")
        XCTAssertEqual(raw.inputTokenIds, [128000, 1, 2, 3])
        XCTAssertEqual(raw.output, "Hello")

        // Flag construction: the fixed flag surface reached the child verbatim.
        let received = try String(contentsOf: argsOut, encoding: .utf8)
        XCTAssertTrue(received.contains("--model /models/x.gguf"), "got: \(received)")
        XCTAssertTrue(received.contains("--prompt-file \(prompt.path)"), "got: \(received)")
        XCTAssertTrue(received.contains("--temperature 0.0"), "got: \(received)")
        XCTAssertTrue(received.contains("--seed 7"), "got: \(received)")
        XCTAssertTrue(received.contains("--max-tokens 64"), "got: \(received)")
        XCTAssertTrue(received.contains("--repeat-index 2"), "got: \(received)")
    }

    func testRunnerNonZeroExitSurfacesAsError() async throws {
        let stub = try writeExecutable("echo 'model failed to load' >&2\nexit 3\n")
        let prompt = try writePrompt("hi")
        let driver = LlamaRunnerDriver(command: Self.shellQuotePath(stub.path))
        do {
            _ = try await driver.run(modelArg: "m", promptFile: prompt, sampler: .greedy, repeatIndex: 0)
            XCTFail("expected runnerNonZeroExit")
        } catch let error as DifferentialError {
            guard case .runnerNonZeroExit(_, let code, let stderr) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertEqual(code, 3)
            XCTAssertTrue(stderr.contains("model failed to load"))
        }
    }

    func testRunnerMalformedJSONSurfacesAsDecodeError() async throws {
        let stub = try writeExecutable("echo 'this is not json {'\nexit 0\n")
        let prompt = try writePrompt("hi")
        let driver = LlamaRunnerDriver(command: Self.shellQuotePath(stub.path))
        do {
            _ = try await driver.run(modelArg: "m", promptFile: prompt, sampler: .greedy, repeatIndex: 0)
            XCTFail("expected runnerDecodeFailed")
        } catch let error as DifferentialError {
            guard case .runnerDecodeFailed(_, _, let stdout) = error else {
                return XCTFail("wrong case: \(error)")
            }
            XCTAssertTrue(stdout.contains("not json"))
        }
    }

    func testRunnerHeavyStderrDoesNotDeadlock() async throws {
        // B1 regression guard: ~320 KB of stderr — far past the ~64 KB pipe buffer.
        // The pre-fix sequential drain (stdout to EOF, then stderr) deadlocked here;
        // concurrent draining must complete and still decode stdout.
        let argsOut = scratch.appendingPathComponent("args.txt")
        let stub = try writeExecutable(happyStub(argsOut: argsOut, output: "ok", stderrFloodLines: 4000))
        let prompt = try writePrompt("flood test")
        let driver = LlamaRunnerDriver(command: Self.shellQuotePath(stub.path))
        let raw = try await driver.run(modelArg: "m", promptFile: prompt, sampler: .greedy, repeatIndex: 0)
        XCTAssertEqual(raw.output, "ok", "heavy stderr must not corrupt or block the stdout RawRun")
    }

    // MARK: - same-bytes lynchpin via the full harness (b)

    func testRunnerPromptFileHashesToSameShaAsOllamaLeg() async throws {
        let prompt = "Tell me about manifolds.\nLine two.\n"
        let argsOut = scratch.appendingPathComponent("args.txt")
        let stub = try writeExecutable(happyStub(argsOut: argsOut, output: "OUTPUT", stderrFloodLines: 5))

        // Fake Ollama leg: records promptSha256 the same way the real driver does.
        struct FakeOllama: RawRunProducer {
            let output: String
            func run(model: String, prompt: String, sampler: SamplerConfig, repeatIndex: Int) async throws -> RawRun {
                RawRun(
                    backend: "ollama", model: model, quant: "server",
                    promptSha256: PromptHash.sha256Hex(of: prompt),
                    inputTokenIds: [], output: output, outputTokenIds: [],
                    sampler: sampler, coreCommit: "test", toolingVersions: [:], repeatIndex: repeatIndex
                )
            }
        }

        let harness = DifferentialHarness(ollamaDriver: FakeOllama(output: "OUTPUT"))
        let config = DifferentialConfig(
            ollamaModel: "m",
            prompt: prompt,
            sampler: .greedy,
            repeats: 2,
            llamaRunner: Self.shellQuotePath(stub.path),
            llamaModelArg: "/models/x.gguf"
        )
        let outcome = try await harness.run(config)

        let expected = PromptHash.sha256Hex(of: prompt)
        // The #1 lynchpin: the bytes the harness wrote to the runner's prompt file
        // hash to exactly the sha the Ollama leg recorded over the same string.
        XCTAssertEqual(outcome.ollama.representative?.promptSha256, expected)
        XCTAssertEqual(outcome.llama?.representative?.promptSha256, expected, "runner prompt-file bytes must match the same-bytes anchor")
        XCTAssertEqual(outcome.promptSha256, expected)
        // Same bytes ⇒ never a promptDivergence; equal outputs here ⇒ identical.
        XCTAssertEqual(outcome.comparison?.divergence, .identical)
    }

    /// Single-quote a path for the `--llama-runner` command (the driver runs it via
    /// `/bin/sh -c`, so a path with spaces must be quoted).
    private static func shellQuotePath(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
