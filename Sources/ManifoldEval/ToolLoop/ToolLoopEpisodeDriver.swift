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

    /// Records one episode. Never throws: an episode that times out or dies
    /// at the backend returns whatever was recorded up to the failure with
    /// ``ToolLoopTranscriptEntry/error`` set — partial evidence a human can
    /// triage, and a marker the scorer uses to exclude the entry from
    /// measurement (an infrastructure failure must not score as a
    /// capability zero).
    ///
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
    ) async -> ToolLoopTranscriptEntry {
        let messages = [StructuredMessage(role: "user", content: toolLoopCase.userPrompt)]
        let config = GenerationConfig(
            temperature: 0.0,
            topP: 0.9,
            repeatPenalty: 1.1,
            topK: 1,
            maxOutputTokens: 512,
            tools: toolLoopCase.tools.map(\.definition),
            toolChoice: .auto,
            maxToolIterations: maxToolIterations
        )

        // Accumulation lives in an actor so a timed-out or crashed drain
        // still yields everything recorded before the failure — a timeout on
        // turn 4 of a healthy 3-turn chain must not discard the chain.
        let recorder = EpisodeRecorder()

        func entry(error: String?) async -> ToolLoopTranscriptEntry {
            let (events, lastSegment) = await recorder.snapshot()
            return ToolLoopTranscriptEntry(
                id: toolLoopCase.id,
                repeatIndex: repeatIndex,
                events: events,
                finalText: lastSegment.trimmingCharacters(in: .whitespacesAndNewlines),
                error: error
            )
        }

        // Race the drain against the episode deadline; on timeout the backend
        // generation MUST be cancelled (not just abandoned) so a model that
        // never emits a stop token can't stall the whole run — the same
        // policy as BFCLRunner, applied per episode instead of per call.
        do {
            let (token, stream) = try service.enqueue(
                structuredMessages: messages, systemPrompt: "", config: config
            )
            try await withEpisodeTimeout(
                seconds: timeoutSeconds,
                cancel: { service.cancel(token) },
                drain: {
                    for try await event in stream.events {
                        switch event {
                        case .token(let text):
                            await recorder.recordToken(text)
                        case .toolCall(let call):
                            await recorder.recordCall(name: call.toolName, arguments: call.arguments)
                        case .toolResult(let result):
                            await recorder.recordResult(content: result.content)
                        default:
                            break
                        }
                    }
                }
            )
            return await entry(error: nil)
        } catch {
            return await entry(error: "\(error)")
        }
    }

    /// Thrown when an episode exceeds its deadline; caught inside
    /// ``recordEpisode`` and folded into the entry's error marker.
    public struct EpisodeTimeout: Error, CustomStringConvertible {
        public let seconds: Double
        public var description: String { "episode timed out after \(Int(seconds))s" }
    }

    /// Generic drain-vs-deadline race (`BFCLRunner.withCaseTimeout` is
    /// internal to ManifoldTools, so the shape is mirrored here rather than
    /// reused).
    static func withEpisodeTimeout(
        seconds: Double,
        cancel: () -> Void,
        drain: @escaping @Sendable () async throws -> Void
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await drain() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw EpisodeTimeout(seconds: seconds)
            }
            defer { group.cancelAll() }
            do {
                // First task to finish wins: a completed drain returns; the
                // sleep task throws EpisodeTimeout; a drain error rethrows.
                try await group.next()
            } catch {
                cancel()
                throw error
            }
        }
    }
}

/// Serializes transcript accumulation so partial state survives a cancelled
/// or failed drain task.
private actor EpisodeRecorder {
    private var events: [ToolLoopTranscriptEntry.Event] = []
    /// Text accumulates into the CURRENT segment; each tool result starts a
    /// new one. The final answer is the last segment — text the model
    /// produced after the last threaded result.
    private var currentSegment = ""

    func recordToken(_ text: String) {
        currentSegment += text
    }

    func recordCall(name: String, arguments: String) {
        events.append(.call(name: name, arguments: arguments))
    }

    func recordResult(content: String) {
        events.append(.result(content: content))
        currentSegment = ""
    }

    func snapshot() -> ([ToolLoopTranscriptEntry.Event], String) {
        (events, currentSegment)
    }
}
