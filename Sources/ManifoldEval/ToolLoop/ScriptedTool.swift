import Foundation
import ManifoldInference

/// A `ToolExecutor` that answers from a ``ToolScript`` — the deterministic
/// tool half of the tool-loop lane.
///
/// This is what makes the lane exercise the REAL turn loop rather than a
/// simulation: registering scripted executors in a live `ToolRegistry` means
/// the production dispatch path (`GenerationToolDispatchLoop` → registry
/// dispatch → result threading back into the next backend turn) runs
/// end-to-end, with the only substitution being the tool's *payload*. The
/// payload is canned precisely so every repeat of an episode sees identical
/// tool bytes — a determinism control, not a shortcut.
public struct ScriptedTool: ToolExecutor {

  public let definition: ToolDefinition
  private let script: ToolScript

  /// Read-only by construction: scripted lookups have no side effects, so
  /// concurrent dispatch is safe and no approval gate applies.
  public var supportsConcurrentDispatch: Bool { true }
  public var requiresApproval: Bool { false }

  public init(spec: ScriptedToolSpec) {
    self.definition = spec.definition
    self.script = spec.script
  }

  public func execute(arguments: JSONSchemaValue) async throws -> ToolResult {
    // callId is stamped by ToolRegistry from the incoming ToolCall; an
    // empty placeholder here is the documented contract.
    ToolResult(callId: "", content: resolveContent(arguments: arguments))
  }

  /// Selects the scripted payload: argument-keyed when the script asks for
  /// it and the invocation carries a matching value, else the fixed result.
  private func resolveContent(arguments: JSONSchemaValue) -> String {
    guard let key = script.argumentKey,
      let table = script.resultsByArgument,
      case .object(let object) = arguments,
      let value = object[key],
      case .string(let stringValue) = value,
      let keyed = table[stringValue]
    else {
      return script.result
    }
    return keyed
  }
}
