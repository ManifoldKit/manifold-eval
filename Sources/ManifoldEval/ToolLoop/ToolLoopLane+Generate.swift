import Foundation

// MARK: - Episode generation

/// Backend-agnostic generation loop shared by `manifold-eval toolloop-generate`
/// — the mirror image of ``ToolLoopLane/score(cases:transcripts:)``, exactly
/// as `BFCLLane+Generate` mirrors its scorer: the generator produces the
/// precise ``ToolLoopTranscriptEntry`` values the scorer reads, both sides
/// walk the same corpus, and a generate → score round trip needs no adapter.
extension ToolLoopLane {

  /// Aggregate outcome of a generation run.
  public struct GenerateResult: Sendable {
    /// One entry per attempted (case × repeat), in corpus order then
    /// repeat order.
    public let entries: [ToolLoopTranscriptEntry]
    /// Episodes whose `emit` threw (timeout, backend error). These still
    /// get an entry — with the error recorded on the wire — so the later
    /// scoring run sees the attempt and reports it as a HOLE (not
    /// measured), never as a measured miss.
    public let errored: Int

    public init(entries: [ToolLoopTranscriptEntry], errored: Int) {
      self.entries = entries
      self.errored = errored
    }
  }

  /// Drives every case through `emit`, `repeats` times each, sequentially.
  ///
  /// Sequential on purpose: episodes are multi-turn and stateful at the
  /// backend, and the run doubles as a determinism control — interleaving
  /// concurrent episodes on one Ollama server would confound repeat-to-
  /// repeat comparison with scheduler noise for no meaningful wall-clock
  /// win on an 8-case scaffold.
  ///
  /// - Parameters:
  ///   - cases: the corpus to drive (use the SAME corpus the scoring run
  ///     will load, so ids line up by construction).
  ///   - repeats: episodes generated per case. 3 is the determinism-control
  ///     default; 1 is a smoke run.
  ///   - onProgress: human-readable progress sink (the CLI wires stderr).
  ///   - onEntry: called per finished episode, in order — lets the CLI
  ///     stream JSONL to disk so a long run banks progress incrementally.
  ///   - emit: produces one recorded episode for (case, repeatIndex). Throwing
  ///     records an empty entry and continues; it never aborts the run.
  @MainActor
  public func generateTranscripts(
    cases: [ToolLoopCase],
    repeats: Int,
    onProgress: (String) -> Void = { _ in },
    onEntry: (ToolLoopTranscriptEntry) -> Void = { _ in },
    emit: (ToolLoopCase, Int) async throws -> ToolLoopTranscriptEntry
  ) async -> GenerateResult {
    var entries: [ToolLoopTranscriptEntry] = []
    var errored = 0

    for (offset, toolLoopCase) in cases.enumerated() {
      for repeatIndex in 0..<max(1, repeats) {
        var entry: ToolLoopTranscriptEntry
        do {
          entry = try await emit(toolLoopCase, repeatIndex)
        } catch {
          // A throwing emit (synthetic producers; the live driver
          // folds its own failures into the entry) records the
          // error ON THE WIRE so the scorer can exclude the
          // episode as a hole instead of reading it as a miss.
          entry = ToolLoopTranscriptEntry(
            id: toolLoopCase.id,
            repeatIndex: repeatIndex,
            events: [],
            finalText: "",
            error: "\(error)"
          )
        }
        if let episodeError = entry.error {
          errored += 1
          onProgress(
            "  [\(offset + 1)/\(cases.count) r\(repeatIndex)] \(toolLoopCase.id): "
              + "ERROR \(episodeError) — recorded as a hole (partial transcript kept)"
          )
        } else {
          let calls = entry.calls.map(\.name).joined(separator: " → ")
          onProgress(
            "  [\(offset + 1)/\(cases.count) r\(repeatIndex)] \(toolLoopCase.id): "
              + (calls.isEmpty ? "<no tool call>" : calls)
              + " | final: \(entry.finalText.prefix(60).replacingOccurrences(of: "\n", with: " "))"
          )
        }
        entries.append(entry)
        onEntry(entry)
      }
    }

    return GenerateResult(entries: entries, errored: errored)
  }
}
