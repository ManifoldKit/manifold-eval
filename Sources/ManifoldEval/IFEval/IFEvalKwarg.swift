import Foundation

/// A typed value extracted from an IFEval instruction's `kwargs` dictionary.
///
/// IFEval kwargs are heterogeneous JSON objects whose values are strings,
/// integers, or arrays of strings. This enum preserves the actual type so
/// verifiers can pattern-match rather than re-cast.
public enum IFEvalKwarg: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case stringArray([String])
}

extension IFEvalKwarg: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intVal = try? container.decode(Int.self) {
            self = .int(intVal)
        } else if let doubleVal = try? container.decode(Double.self) {
            self = .double(doubleVal)
        } else if let strVal = try? container.decode(String.self) {
            self = .string(strVal)
        } else if let arrVal = try? container.decode([String].self) {
            self = .stringArray(arrVal)
        } else {
            throw DecodingError.typeMismatch(
                IFEvalKwarg.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "IFEvalKwarg: expected String, Int, Double, or [String]"
                )
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let s): try container.encode(s)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .stringArray(let a): try container.encode(a)
        }
    }
}

extension IFEvalKwarg {
    /// Convenience accessor: the string value if this is `.string(_)`, else nil.
    var stringValue: String? {
        guard case .string(let s) = self else { return nil }
        return s
    }

    /// Convenience accessor: the integer value if this is `.int(_)`, else nil.
    var intValue: Int? {
        guard case .int(let i) = self else { return nil }
        return i
    }

    /// Convenience accessor: the string-array value if this is `.stringArray(_)`, else nil.
    var stringArrayValue: [String]? {
        guard case .stringArray(let a) = self else { return nil }
        return a
    }
}
