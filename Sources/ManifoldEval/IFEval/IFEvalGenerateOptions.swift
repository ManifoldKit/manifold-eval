import Foundation

/// Parsed, validated arguments for `manifold-eval ifeval-generate`.
///
/// Parsing lives here (not in the `manifold-eval` executable) so it's testable
/// with `@testable import ManifoldEval` and no CLI process spawn — the same
/// reason `BFCLCategory.parseList` lives in the library rather than inline in
/// `BFCLGenerateCommand`.
public struct IFEvalGenerateOptions: Sendable, Equatable {
    public var ollamaModel: String
    public var corpusPath: String
    public var outPath: String
    public var ollamaURLString: String
    public var maxTokens: Int
    public var concurrency: Int
    public var timeoutSeconds: Double

    public init(
        ollamaModel: String,
        corpusPath: String,
        outPath: String,
        ollamaURLString: String = "http://localhost:11434",
        maxTokens: Int = 512,
        concurrency: Int = 6,
        timeoutSeconds: Double = 120
    ) {
        self.ollamaModel = ollamaModel
        self.corpusPath = corpusPath
        self.outPath = outPath
        self.ollamaURLString = ollamaURLString
        self.maxTokens = maxTokens
        self.concurrency = concurrency
        self.timeoutSeconds = timeoutSeconds
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case missingValue(flag: String)
        case unknownFlag(String)
        case unexpectedArgument(String)
        case missingRequired(flag: String)
        case invalidInt(flag: String, value: String)
        case invalidDouble(flag: String, value: String)

        public var description: String {
            switch self {
            case .missingValue(let flag): return "\(flag) requires a value"
            case .unknownFlag(let flag): return "unknown flag '\(flag)'"
            case .unexpectedArgument(let arg): return "unexpected argument '\(arg)' — expected a flag"
            case .missingRequired(let flag): return "ifeval-generate requires \(flag)"
            case .invalidInt(let flag, let value): return "\(flag) requires a positive integer, got '\(value)'"
            case .invalidDouble(let flag, let value): return "\(flag) requires a positive number, got '\(value)'"
            }
        }
    }

    /// Parses `manifold-eval ifeval-generate` arguments (subcommand token
    /// already stripped). Defaults match the overnight ad-hoc generator that
    /// produced the verified-correct qwen2.5-0.5b/541-case/22.9% number:
    /// `--max-tokens 512`, `--concurrency 6`. Those two are load-bearing —
    /// changing them changes what a "verified" run means.
    public static func parse(_ args: [String]) throws -> IFEvalGenerateOptions {
        var ollamaModel: String?
        var corpusPath: String?
        var outPath: String?
        var ollamaURLString = "http://localhost:11434"
        var maxTokens = 512
        var concurrency = 6
        var timeoutSeconds: Double = 120

        func value(_ index: inout Int, _ flag: String) throws -> String {
            index += 1
            guard index < args.count else { throw ParseError.missingValue(flag: flag) }
            return args[index]
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--ollama-model", "--model":
                ollamaModel = try value(&index, token)
            case "--corpus":
                corpusPath = try value(&index, token)
            case "--out":
                outPath = try value(&index, token)
            case "--ollama-url":
                ollamaURLString = try value(&index, token)
            case "--max-tokens":
                let raw = try value(&index, token)
                guard let n = Int(raw), n > 0 else { throw ParseError.invalidInt(flag: token, value: raw) }
                maxTokens = n
            case "--concurrency":
                let raw = try value(&index, token)
                guard let n = Int(raw), n > 0 else { throw ParseError.invalidInt(flag: token, value: raw) }
                concurrency = n
            case "--timeout":
                let raw = try value(&index, token)
                guard let d = Double(raw), d > 0 else { throw ParseError.invalidDouble(flag: token, value: raw) }
                timeoutSeconds = d
            default:
                if token.hasPrefix("--") { throw ParseError.unknownFlag(token) }
                throw ParseError.unexpectedArgument(token)
            }
            index += 1
        }

        guard let ollamaModel else { throw ParseError.missingRequired(flag: "--ollama-model <tag>") }
        guard let corpusPath else { throw ParseError.missingRequired(flag: "--corpus <path>") }
        guard let outPath else { throw ParseError.missingRequired(flag: "--out <responses.jsonl>") }

        return IFEvalGenerateOptions(
            ollamaModel: ollamaModel,
            corpusPath: corpusPath,
            outPath: outPath,
            ollamaURLString: ollamaURLString,
            maxTokens: maxTokens,
            concurrency: concurrency,
            timeoutSeconds: timeoutSeconds
        )
    }
}
