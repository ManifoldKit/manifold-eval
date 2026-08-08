import Foundation

/// Errors raised while building a pre-triage brief. Every failure is surfaced
/// (never a silent skip), matching ``DifferentialError``'s discipline.
public enum TriageError: Error, CustomStringConvertible, Equatable {
  /// A leg's run list was empty — there is nothing to compare, and a fabricated
  /// brief over no data would be a lie (mirrors ``DifferentialRecord/compare``
  /// returning `nil` for the same reason).
  case emptyLeg
  /// `--bos` (or the transcript's `"bos"` field) was neither `"autoDetect"`,
  /// `"none"`, nor a parseable integer token id.
  case invalidBOS(String)

  public var description: String {
    switch self {
    case .emptyLeg:
      return "triage requires at least one run on each leg — a leg's run list was empty"
    case .invalidBOS(let raw):
      return "invalid BOS value '\(raw)' — expected 'autoDetect', 'none', or an integer token id"
    }
  }
}
