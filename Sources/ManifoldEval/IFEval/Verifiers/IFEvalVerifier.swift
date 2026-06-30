/// A pure function that checks one IFEval instruction constraint.
///
/// Verifiers are stateless value types. A verifier receives the model response
/// and the instruction-specific keyword arguments (extracted from the IFEval
/// dataset JSON), and returns a Boolean verdict — no model calls, no I/O.
public protocol IFEvalVerifier: Sendable {
    /// The instruction ID this verifier handles, e.g. `"length_constraints:number_words"`.
    var instructionID: String { get }

    /// Returns true when `response` satisfies the constraint described by `kwargs`.
    ///
    /// A verifier must return false (not throw) when kwargs are missing or
    /// malformed — the dataset is the ground truth, not the verifier's type
    /// expectations.
    func verify(response: String, kwargs: [String: IFEvalKwarg]) -> Bool
}
