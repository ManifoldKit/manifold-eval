import Foundation
import ManifoldInference

/// One multi-turn tool-loop conformance case.
///
/// A case is a self-contained *episode*: a user prompt, a set of tools whose
/// results are **scripted** (deterministic canned payloads — see
/// ``ToolScript``), and the expectations that make tool-result threading
/// *measurable*. The scripted results carry **sentinel values** — arbitrary
/// tokens like `"K97"` or `"ACC-77120"` that do not occur in any model's
/// priors for the prompt — so an expectation can only pass if the model
/// actually read the tool result out of the transcript. That is the whole
/// probe: single-turn AST scoring (BFCL) checks "did it call the right
/// function"; this lane checks "did the tool result *thread* into what the
/// model did next".
///
/// Three expectation axes, each optional so a case probes exactly what it
/// means to probe:
/// - ``ToolLoopExpectations/firstCall``: the opening call is the right tool
///   with the right arguments (turn-1 correctness, the BFCL overlap).
/// - ``ToolLoopExpectations/chainedCall``: a later call carries an argument
///   value that ONLY exists in an earlier scripted result (result → argument
///   threading, the failure mode single-turn scoring structurally misses).
/// - ``ToolLoopExpectations/finalAnswerMustContain``: sentinels from scripted
///   results that must surface in the model's final visible answer
///   (result → answer threading).
public struct ToolLoopCase: Sendable, Codable, Equatable {
  /// Stable case identifier — the join key between a generate run's
  /// transcript entries and a later scoring run.
  public let id: String
  /// The user message that opens the episode.
  public let userPrompt: String
  /// The tools advertised to the model, each with its scripted result.
  public let tools: [ScriptedToolSpec]
  /// What must be true of the episode transcript for the case to pass.
  public let expect: ToolLoopExpectations

  public init(
    id: String,
    userPrompt: String,
    tools: [ScriptedToolSpec],
    expect: ToolLoopExpectations
  ) {
    self.id = id
    self.userPrompt = userPrompt
    self.tools = tools
    self.expect = expect
  }
}

/// A tool definition plus the script that answers it.
///
/// The `parameters` schema is standard JSON-Schema (``JSONSchemaValue``), the
/// same shape ``ToolDefinition`` advertises to backends.
public struct ScriptedToolSpec: Sendable, Codable, Equatable {
  public let name: String
  public let description: String
  public let parameters: JSONSchemaValue
  public let script: ToolScript

  public init(
    name: String,
    description: String,
    parameters: JSONSchemaValue,
    script: ToolScript
  ) {
    self.name = name
    self.description = description
    self.parameters = parameters
    self.script = script
  }

  /// The ``ToolDefinition`` advertised to the backend for this spec.
  public var definition: ToolDefinition {
    ToolDefinition(name: name, description: description, parameters: parameters)
  }
}

/// Deterministic canned result for a scripted tool.
///
/// The default shape is one fixed `result` string returned for every
/// invocation. When a case needs the SAME tool to answer differently per
/// argument (e.g. two quotes compared in one episode), set `argumentKey` and
/// `resultsByArgument`: the invocation's parsed argument value under
/// `argumentKey` selects the payload, falling back to `result` when the value
/// is absent or unmatched. Keying on an argument the model copies from the
/// prompt keeps the script deterministic without hardcoding call order.
public struct ToolScript: Sendable, Codable, Equatable {
  /// Result content returned when no argument-keyed entry matches.
  public let result: String
  /// Name of the argument whose value selects from ``resultsByArgument``.
  public let argumentKey: String?
  /// Argument-value–keyed result payloads.
  public let resultsByArgument: [String: String]?

  public init(
    result: String,
    argumentKey: String? = nil,
    resultsByArgument: [String: String]? = nil
  ) {
    self.result = result
    self.argumentKey = argumentKey
    self.resultsByArgument = resultsByArgument
  }
}

/// The pass criteria for one case. All specified axes must hold, over every
/// repeat, for the case to pass — see `ToolLoopLane` for the exact policy.
public struct ToolLoopExpectations: Sendable, Codable, Equatable {
  /// The episode's first tool call must match this tool name and (when
  /// given) these argument values exactly.
  public let firstCall: ToolLoopExpectedCall?
  /// Some call AFTER the first tool result must carry the sentinel — the
  /// result → argument threading probe.
  public let chainedCall: ToolLoopChainedCall?
  /// Sentinels that must appear verbatim in the final visible answer (the
  /// text after the last tool result).
  public let finalAnswerMustContain: [String]

  public init(
    firstCall: ToolLoopExpectedCall? = nil,
    chainedCall: ToolLoopChainedCall? = nil,
    finalAnswerMustContain: [String] = []
  ) {
    self.firstCall = firstCall
    self.chainedCall = chainedCall
    self.finalAnswerMustContain = finalAnswerMustContain
  }
}

/// Expected shape of one tool call: name, plus optional exact argument
/// equalities compared on canonicalized argument values (see
/// `ToolLoopArguments`).
public struct ToolLoopExpectedCall: Sendable, Codable, Equatable {
  public let toolName: String
  /// Argument key → expected canonical value. Keys not listed are ignored
  /// (the probe checks threading, not exhaustive AST equality — BFCL
  /// already owns that surface single-turn).
  public let arguments: [String: String]?

  public init(toolName: String, arguments: [String: String]? = nil) {
    self.toolName = toolName
    self.arguments = arguments
  }
}

/// The chained-call probe: `toolName` must be invoked with
/// `arguments[argumentKey] == expectedValue`, where `expectedValue` is a
/// sentinel that exists ONLY inside an earlier scripted tool result — never
/// in the prompt. A pass therefore proves the model read the first result
/// and threaded it into the next call's arguments.
public struct ToolLoopChainedCall: Sendable, Codable, Equatable {
  public let toolName: String
  public let argumentKey: String
  public let expectedValue: String

  public init(toolName: String, argumentKey: String, expectedValue: String) {
    self.toolName = toolName
    self.argumentKey = argumentKey
    self.expectedValue = expectedValue
  }
}

// MARK: - Argument canonicalization

/// Parses a ``ToolCall``'s raw JSON `arguments` string into canonical
/// per-key string values so expectations can compare exactly without
/// caring whether a backend emitted `"7"` or `7`.
///
/// Canonical form: strings as-is; integral numbers without a decimal point;
/// other numbers via their shortest `Double` description; booleans as
/// `true`/`false`; null as `null`; nested containers re-serialized with
/// sorted keys (deterministic, though no bundled case currently nests).
public enum ToolLoopArguments {

  /// Returns the parsed top-level arguments, or `nil` when the raw string
  /// is not a JSON object (a malformed emission scores as a miss upstream,
  /// never a crash).
  public static func canonicalized(_ rawArguments: String) -> [String: String]? {
    guard let data = rawArguments.data(using: .utf8),
      let parsed = try? JSONSerialization.jsonObject(with: data),
      let object = parsed as? [String: Any]
    else {
      return nil
    }
    var canonical: [String: String] = [:]
    for (key, value) in object {
      canonical[key] = canonicalValue(value)
    }
    return canonical
  }

  private static func canonicalValue(_ value: Any) -> String {
    switch value {
    case let string as String:
      return string
    case let number as NSNumber:
      // NSNumber bridges JSON bools too — distinguish via the ObjC type
      // encoding ("c" is the boolean encoding JSONSerialization uses).
      if String(cString: number.objCType) == "c" {
        return number.boolValue ? "true" : "false"
      }
      let double = number.doubleValue
      if double.rounded() == double, abs(double) < 1e15 {
        return String(Int64(double))
      }
      return String(double)
    case is NSNull:
      return "null"
    default:
      // Nested container: re-serialize deterministically.
      guard
        let data = try? JSONSerialization.data(
          withJSONObject: value, options: [.sortedKeys]
        )
      else { return "\(value)" }
      return String(decoding: data, as: UTF8.self)
    }
  }
}
