import Foundation

/// Errors raised by the differential harness. Every failure is surfaced (never a
/// silent skip) so a missing leg can't read as "measured nothing" — the same
/// discipline the `Collator` enforces.
public enum DifferentialError: Error, CustomStringConvertible, Equatable {
    case invalidRepeats(Int)
    case ollamaRequestFailed(reason: String)
    case ollamaHTTPStatus(code: Int, body: String)
    case ollamaDecodeFailed(reason: String)
    case runnerLaunchFailed(command: String, reason: String)
    case runnerNonZeroExit(command: String, code: Int32, stderr: String)
    case runnerDecodeFailed(command: String, reason: String, stdout: String)
    case promptSourceUnreadable(path: String, reason: String)
    case templateUnavailable(ggufPath: String)
    case messagesUndecodable(path: String, reason: String)

    public var description: String {
        switch self {
        case .invalidRepeats(let n):
            return "repeats must be >= 1, got \(n)"
        case .ollamaRequestFailed(let reason):
            return "Ollama request failed: \(reason)"
        case .ollamaHTTPStatus(let code, let body):
            return "Ollama returned HTTP \(code): \(body)"
        case .ollamaDecodeFailed(let reason):
            return "cannot decode Ollama response: \(reason)"
        case .runnerLaunchFailed(let command, let reason):
            return "cannot launch llama runner '\(command)': \(reason)"
        case .runnerNonZeroExit(let command, let code, let stderr):
            return "llama runner '\(command)' exited \(code): \(stderr)"
        case .runnerDecodeFailed(let command, let reason, let stdout):
            return "cannot decode RawRun from llama runner '\(command)': \(reason)  (stdout: \(stdout))"
        case .promptSourceUnreadable(let path, let reason):
            return "cannot read prompt file \(path): \(reason)"
        case .templateUnavailable(let ggufPath):
            return "no embedded chat_template in GGUF \(ggufPath) — cannot render --messages-file; use --prompt-file"
        case .messagesUndecodable(let path, let reason):
            return "cannot decode \(path) as a [{role,content}] array: \(reason)"
        }
    }
}
