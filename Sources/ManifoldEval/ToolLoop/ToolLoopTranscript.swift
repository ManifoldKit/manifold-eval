import Foundation
import ManifoldInference

/// One recorded episode — the wire schema shared by `toolloop-generate`
/// (writer) and `toolloop` (reader).
///
/// Mirrors the BFCL discipline: the generator emits exactly what the scorer
/// consumes, one JSON object per line, so a generate → score round trip
/// needs no adapter and cannot drift into a different id namespace. Unlike
/// BFCL's single-call entries, an episode is *ordered*: the event sequence
/// (calls interleaved with results) is what makes threading scoreable —
/// "the chained call came after the result that contains its sentinel" is
/// an ordering fact.
public struct ToolLoopTranscriptEntry: Sendable, Codable, Equatable {

  /// The ``ToolLoopCase/id`` this episode drove.
  public let id: String
  /// Zero-based repeat index — every case runs N times so the scorer can
  /// report variance, never means-only (ORIGINS principle #4).
  public let repeatIndex: Int
  /// Ordered tool activity: calls as the model emitted them, results as
  /// the registry dispatched them.
  public let events: [Event]
  /// The model's final visible answer: text emitted AFTER the last tool
  /// result (or the whole visible text when no tool ran).
  public let finalText: String
  /// Non-nil when the episode did not run to completion (timeout, backend
  /// error). Events/finalText then hold whatever was recorded BEFORE the
  /// failure — partial evidence for human triage — and the scorer treats
  /// the entry as *not measured*, never as a measured miss: an Ollama
  /// outage over the last N cases must not read as N capability zeros
  /// (absence ≠ failure, ORIGINS #3).
  public let error: String?

  public init(
    id: String,
    repeatIndex: Int,
    events: [Event],
    finalText: String,
    error: String? = nil
  ) {
    self.id = id
    self.repeatIndex = repeatIndex
    self.events = events
    self.finalText = finalText
    self.error = error
  }

  /// One tool-loop event. Encoded with a `kind` discriminator so the JSONL
  /// stays greppable and stable:
  /// `{"kind":"call","name":"get_balance","arguments":"{...}"}` /
  /// `{"kind":"result","content":"{...}"}`.
  public enum Event: Sendable, Equatable {
    case call(name: String, arguments: String)
    case result(content: String)
  }

  /// Just the calls, in order — the shape most scoring checks want.
  public var calls: [(name: String, arguments: String)] {
    events.compactMap {
      if case .call(let name, let arguments) = $0 { return (name, arguments) }
      return nil
    }
  }

  /// Index (into ``events``) of the first `result` event, or `nil` when no
  /// tool result ever landed.
  public var firstResultIndex: Int? {
    events.firstIndex {
      if case .result = $0 { return true }
      return false
    }
  }
}

// MARK: - Event Codable

extension ToolLoopTranscriptEntry.Event: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, name, arguments, content
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "call":
      self = .call(
        name: try container.decode(String.self, forKey: .name),
        arguments: try container.decode(String.self, forKey: .arguments)
      )
    case "result":
      self = .result(content: try container.decode(String.self, forKey: .content))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind, in: container,
        debugDescription: "unknown tool-loop event kind '\(kind)'"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .call(let name, let arguments):
      try container.encode("call", forKey: .kind)
      try container.encode(name, forKey: .name)
      try container.encode(arguments, forKey: .arguments)
    case .result(let content):
      try container.encode("result", forKey: .kind)
      try container.encode(content, forKey: .content)
    }
  }
}

// MARK: - JSONL loading

extension ToolLoopTranscriptEntry {

  /// Decodes a transcript JSONL file (one entry per line, blank lines
  /// ignored) — the exact format `toolloop-generate --out` writes.
  public static func loadJSONL(from url: URL) throws -> [ToolLoopTranscriptEntry] {
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch {
      throw ToolLoopError.transcriptUnreadable(url, underlying: error)
    }
    let decoder = JSONDecoder()
    var entries: [ToolLoopTranscriptEntry] = []
    for rawLine in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespaces)
      guard !line.isEmpty else { continue }
      entries.append(
        try decoder.decode(ToolLoopTranscriptEntry.self, from: Data(line.utf8))
      )
    }
    return entries
  }
}

/// Errors surfaced by the tool-loop lane's file boundaries.
public enum ToolLoopError: Error, CustomStringConvertible {
  case transcriptUnreadable(URL, underlying: Error)
  case corpusUnreadable(URL, underlying: Error)
  case invalidCase(String, String)

  public var description: String {
    switch self {
    case .transcriptUnreadable(let url, let underlying):
      return "cannot read transcript file '\(url.path)': \(underlying)"
    case .corpusUnreadable(let url, let underlying):
      return "cannot read corpus file '\(url.path)': \(underlying)"
    case .invalidCase(let id, let reason):
      return "invalid corpus case '\(id)': \(reason)"
    }
  }
}
