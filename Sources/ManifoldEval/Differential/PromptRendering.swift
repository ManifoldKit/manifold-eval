import Foundation
import ManifoldModelCatalog
import ManifoldInference

/// Renders chat messages to a single prompt STRING via ManifoldKit's public
/// template seam — the canonical "render once, inject everywhere" path (plan §13b
/// component 3).
///
/// We deliberately use the *public* `ChatTemplate.format` rather than the internal
/// `JinjaPromptRenderer`: `ChatTemplate.format` is documented as byte-identical to
/// the production renderer and is a stable, non-throwing public API at the pinned
/// core version. The GGUF's embedded `tokenizer.chat_template` is read via the
/// equally-public `ModelInfo(ggufURL:).chatTemplateRaw`. So there is one renderer
/// of record for the differential — no second template engine gets a vote.
public enum PromptRendering {

    /// A `{role, content}` message as supplied in a `--messages-file` JSON array.
    public struct ChatMessage: Decodable, Sendable, Equatable {
        public let role: String
        public let content: String
    }

    /// Render `messages` to a prompt string using the chat template embedded in
    /// the GGUF at `ggufURL`.
    ///
    /// - Throws: ``DifferentialError/templateUnavailable(ggufPath:)`` when the GGUF
    ///   carries no embedded template (rendering is impossible — the caller must
    ///   fall back to `--prompt-file`, never a hardcoded template guess).
    public static func render(messages: [ChatMessage], ggufURL: URL) throws -> String {
        guard let info = ModelInfo(ggufURL: ggufURL), let templateRaw = info.chatTemplateRaw else {
            throw DifferentialError.templateUnavailable(ggufPath: ggufURL.path)
        }
        let template = ChatTemplate(embeddedJinja: templateRaw)
        let structured = messages.map { StructuredMessage(role: $0.role, content: $0.content) }
        // Tools omitted: P2.1 proves determinism + same-bytes parity on plain chat.
        // A tool-bearing prompt is a P3 lane concern.
        let rendered = template.format(structured, systemPrompt: nil, tools: [])
        return rendered.text
    }

    /// Decode a `--messages-file` (`[{ "role": ..., "content": ... }]`) into messages.
    public static func decodeMessages(at url: URL) throws -> [ChatMessage] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw DifferentialError.promptSourceUnreadable(path: url.path, reason: "\(error)")
        }
        do {
            return try JSONDecoder().decode([ChatMessage].self, from: data)
        } catch {
            throw DifferentialError.messagesUndecodable(path: url.path, reason: "\(error)")
        }
    }
}
