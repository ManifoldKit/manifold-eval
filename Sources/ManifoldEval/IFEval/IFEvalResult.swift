import Foundation

/// The verification result for one IFEval case: a per-instruction pass/fail
/// verdict plus the response that was evaluated.
public struct IFEvalResult: Sendable, Equatable {
    /// The dataset key identifying which case was evaluated.
    public let key: String
    /// The prompt used.
    public let prompt: String
    /// The model response that was evaluated.
    public let response: String
    /// Per-instruction verdicts, parallel to `IFEvalCase.instructionIDs`.
    public let instructionResults: [Bool]

    public init(
        key: String,
        prompt: String,
        response: String,
        instructionResults: [Bool]
    ) {
        self.key = key
        self.prompt = prompt
        self.response = response
        self.instructionResults = instructionResults
    }

    /// True when every instruction in this case passed.
    public var allPassed: Bool {
        instructionResults.allSatisfy { $0 }
    }
}

// MARK: -

/// Aggregate IFEval metrics across a batch of results.
///
/// Strict accuracy (the standard IFEval metric) counts a case as passed only
/// when **all** of its instructions pass. `perInstructionAccuracy` breaks down
/// pass rate per instruction ID across all cases that carried that instruction.
public struct IFEvalAggregateScore: Sendable, Equatable {
    /// Fraction of cases where every instruction passed (strict accuracy).
    public let strictAccuracy: Double
    /// Total number of cases evaluated.
    public let totalCases: Int
    /// Number of cases where all instructions passed.
    public let passedCases: Int
    /// Per-instruction-ID pass rate (cases carrying that instruction where it passed / total).
    public let perInstructionAccuracy: [String: Double]

    public init(
        strictAccuracy: Double,
        totalCases: Int,
        passedCases: Int,
        perInstructionAccuracy: [String: Double]
    ) {
        self.strictAccuracy = strictAccuracy
        self.totalCases = totalCases
        self.passedCases = passedCases
        self.perInstructionAccuracy = perInstructionAccuracy
    }
}
