import Foundation
import ManifoldInference

/// Drives one ``ToolLoopCase`` episode through a live `InferenceService` and
/// records the ordered transcript — the tool-loop analogue of
/// `BFCLRunner.emittedCalls`, with the defining difference inverted: BFCL
/// runs an EMPTY registry and `maxToolIterations: 1` (capture the first
/// call, never dispatch); this driver requires the case's ``ScriptedTool``s
/// REGISTERED so the production dispatch loop actually executes them and
/// threads their results into subsequent turns. The turn loop under test is
/// the real one.
///
/// Backend-agnostic: any `InferenceService` works. The caller owns registry
/// population (see `toolloop-generate` for the live Ollama wiring and the
/// RUN_OLLAMA_LIVE tests for the end-to-end proof).
@MainActor
public enum ToolLoopEpisodeDriver {

    /// Determinism-pinned config, matching `BFCLRunner.emittedCalls`' sampler
    /// (temp 0, topK 1) so tool-loop cells stay comparable with the
    /// single-turn BFCL cells measured on the same model.
    /// `maxOutputTokens` applies per turn.
    public static func recordEpisode(
        for toolLoopCase: ToolLoopCase,
        repeatIndex: Int,
        service: InferenceService,
        maxToolIterations: Int = 4,
        timeoutSeconds: Double = 180
    ) async throws -> ToolLoopTranscriptEntry {
        let messages = [StructuredMessage(role: "user", content: toolLoopCase.userPrompt)]
        var config = GenerationConfig(
            temperature: 0.0,
            topP: 0.9,
            repeatPenalty: 1.1,
            topK: 1,
            maxOutputTokens: 512,
            tools: toolLoopCase.tools.map(\.definition),
            toolChoice: .auto,
            maxToolIterations: maxToolIterations
        )
        // Opt in to the promptRendered event — off by default for privacy,
        // and the only source of the rendered-bytes comparability hash.
        config.captureRenderedPrompt = true
        let (token, stream) = try service.enqueue(
            structuredMessages: messages, systemPrompt: "", config: config
        )

        // Race the drain against the episode deadline; on timeout the backend
        // generation MUST be cancelled (not just abandoned) so a model that
        // never emits a stop token can't stall the whole run — the same
        // policy as BFCLRunner, applied per episode instead of per call.
        let recording = try await withEpisodeTimeout(
            seconds: timeoutSeconds,
            cancel: { service.cancel(token) },
            drain: {
                var events: [ToolLoopTranscriptEntry.Event] = []
                // Text accumulates into the CURRENT segment; each tool result
                // starts a new one. The final answer is the last segment —
                // text the model produced after the last threaded result.
                var currentSegment = ""
                var promptSHA: String?

                for try await event in stream.events {
                    switch event {
                    case .promptRendered(let text):
                        // First render wins: it is the episode's opening
                        // prompt bytes, the comparability anchor.
                        if promptSHA == nil {
                            promptSHA = PromptHash.sha256Hex(of: text)
                        }
                    case .token(let text):
                        currentSegment += text
                    case .toolCall(let call):
                        events.append(.call(name: call.toolName, arguments: call.arguments))
                    case .toolResult(let result):
                        events.append(.result(content: result.content))
                        currentSegment = ""
                    default:
                        break
                    }
                }
                return (events, currentSegment, promptSHA)
            }
        )

        return ToolLoopTranscriptEntry(
            id: toolLoopCase.id,
            repeatIndex: repeatIndex,
            events: recording.0,
            finalText: recording.1.trimmingCharacters(in: .whitespacesAndNewlines),
            promptSHA256: recording.2
        )
    }

    /// Thrown when an episode exceeds its deadline; the generate loop records
    /// the episode as errored-empty and continues.
    public struct EpisodeTimeout: Error, CustomStringConvertible {
        public let seconds: Double
        public var description: String { "episode timed out after \(Int(seconds))s" }
    }

    /// Generic drain-vs-deadline race (`BFCLRunner.withCaseTimeout` is
    /// internal to ManifoldTools and typed to `[ToolCall]`, so the shape is
    /// mirrored here rather than reused).
    static func withEpisodeTimeout<T: Sendable>(
        seconds: Double,
        cancel: () -> Void,
        drain: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await drain() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw EpisodeTimeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            do {
                guard let value = try await group.next() else {
                    throw EpisodeTimeout(seconds: seconds)
                }
                return value
            } catch {
                cancel()
                throw error
            }
        }
    }
}
