import Foundation

/// One case from the IFEval dataset: a prompt plus a list of verifiable
/// instruction constraints.
///
/// The `kwargs` array is parallel to `instructionIDs`: `kwargs[i]` contains
/// the parameters for `instructionIDs[i]`. An instruction with no parameters
/// (e.g. `punctuation:no_comma`) has an empty dictionary.
public struct IFEvalCase: Sendable, Equatable {
    /// The original dataset key (e.g. `1000`).
    public let key: String
    /// The prompt text as given to the model.
    public let prompt: String
    /// Instruction constraint identifiers, e.g. `["keywords:existence", "length_constraints:number_words"]`.
    public let instructionIDs: [String]
    /// Parameters for each instruction (parallel to `instructionIDs`).
    public let kwargs: [[String: IFEvalKwarg]]

    public init(
        key: String,
        prompt: String,
        instructionIDs: [String],
        kwargs: [[String: IFEvalKwarg]]
    ) {
        self.key = key
        self.prompt = prompt
        self.instructionIDs = instructionIDs
        self.kwargs = kwargs
    }
}

// MARK: - Codable

extension IFEvalCase: Codable {
    private enum CodingKeys: String, CodingKey {
        case key
        case prompt
        case instructionIDs = "instruction_id_list"
        case kwargs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // The dataset uses integer keys; decode as Int and convert to String.
        if let intKey = try? container.decode(Int.self, forKey: .key) {
            key = String(intKey)
        } else {
            key = try container.decode(String.self, forKey: .key)
        }
        prompt = try container.decode(String.self, forKey: .prompt)
        instructionIDs = try container.decode([String].self, forKey: .instructionIDs)
        kwargs = try container.decode([[String: IFEvalKwarg]].self, forKey: .kwargs)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(prompt, forKey: .prompt)
        try container.encode(instructionIDs, forKey: .instructionIDs)
        try container.encode(kwargs, forKey: .kwargs)
    }
}
