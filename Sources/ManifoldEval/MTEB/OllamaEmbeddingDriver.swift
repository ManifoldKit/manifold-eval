import Foundation
import ManifoldInference

/// An ``EmbeddingBackend`` that computes embeddings through a local Ollama
/// server's `/api/embed` endpoint.
///
/// Intended for the MTEB STS lane and similar eval harnesses that need real
/// embeddings from a locally-running Ollama instance. The default model is
/// `nomic-embed-text`, which is the standard developer-local embedding model
/// for this project (present on the local host per the project environment docs).
///
/// Ollama owns the weights — `loadModel(from:)` is a deliberate no-op because
/// there is no local file to load. The backend reports itself loaded as soon as
/// it is constructed (Ollama will auto-pull the model on first use if not cached).
///
/// ## Thread Safety
///
/// Declared `@unchecked Sendable` with an `NSLock` guarding the one mutable
/// field (`_dimensions`), following the pattern of `ManifoldTestSupport`'s
/// `OllamaEmbeddingBackend`. All other fields are immutable after init.
public final class OllamaEmbeddingDriver: EmbeddingBackend, @unchecked Sendable {

    /// Default embedding model — present on the project's local Ollama host.
    public static let defaultModel = "nomic-embed-text"

    /// Default Ollama base URL (`http://localhost:11434`). Constructed via
    /// URLComponents — the scheme, host, and port are all statically known ASCII
    /// values, so `components.url` is structurally guaranteed to be non-nil.
    public static let defaultBaseURL: URL = {
        var c = URLComponents()
        c.scheme = "http"
        c.host = "localhost"
        c.port = 11434
        guard let url = c.url else {
            // Unreachable: URLComponents.url is non-nil for any valid scheme +
            // ASCII hostname + numeric port combination. Surface loudly if the
            // standard library ever violates this.
            preconditionFailure("OllamaEmbeddingDriver: could not construct default base URL")
        }
        return url
    }()

    private let baseURL: URL
    private let modelName: String
    private let session: URLSession

    private let lock = NSLock()
    // Discovered lazily from the first successful embed call; nomic-embed-text
    // returns 768-dim vectors and is the assumed default until the first call.
    private var _dimensions: Int = 768

    /// `true` always: Ollama manages the weights; there is no local file state.
    public var isModelLoaded: Bool { true }

    public var dimensions: Int {
        lock.withLock { _dimensions }
    }

    /// - Parameters:
    ///   - baseURL: Base URL of the Ollama server (default: ``defaultBaseURL``).
    ///   - modelName: Ollama model tag (default: ``defaultModel``).
    ///   - session: URLSession to use for requests (default: `.shared`).
    public init(
        baseURL: URL = OllamaEmbeddingDriver.defaultBaseURL,
        modelName: String = OllamaEmbeddingDriver.defaultModel,
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.modelName = modelName
        self.session = session
    }

    /// No-op: Ollama hosts the weights; there is no local file to load.
    public func loadModel(from url: URL) async throws {}

    /// No-op: Ollama manages model lifecycle.
    public func unloadModel() {}

    /// Embeds `texts` via Ollama's `/api/embed` endpoint.
    ///
    /// Sends all texts in one request (batch). The response is expected to carry
    /// one vector per input in the same order — an `EmbeddingBackend` postcondition
    /// that Ollama's `/api/embed` upholds for the `input` array form.
    ///
    /// - Throws: ``EmbeddingError/encodingFailed(underlying:)`` on network, HTTP, or
    ///   decode failures; ``EmbeddingError/dimensionMismatch(expected:actual:)`` when
    ///   Ollama returns a different number of vectors than inputs.
    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        var request = URLRequest(url: baseURL.appendingPathComponent("api/embed"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let payload = EmbedRequest(model: modelName, input: texts)
        do {
            request.httpBody = try JSONEncoder().encode(payload)
        } catch {
            throw EmbeddingError.encodingFailed(underlying: error)
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw EmbeddingError.encodingFailed(underlying: error)
        }

        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
            throw EmbeddingError.encodingFailed(
                underlying: NSError(
                    domain: "OllamaEmbeddingDriver",
                    code: statusCode,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "Ollama /api/embed returned HTTP \(statusCode): \(body)"
                    ]
                )
            )
        }

        let decoded: EmbedResponse
        do {
            decoded = try JSONDecoder().decode(EmbedResponse.self, from: data)
        } catch {
            throw EmbeddingError.encodingFailed(underlying: error)
        }

        // Verify the postcondition: one vector per input, in order.
        guard decoded.embeddings.count == texts.count else {
            throw EmbeddingError.dimensionMismatch(
                expected: texts.count,
                actual: decoded.embeddings.count
            )
        }

        // Lazily update dimensions from the first vector of each response.
        if let first = decoded.embeddings.first, !first.isEmpty {
            lock.withLock { _dimensions = first.count }
        }

        return decoded.embeddings
    }

    // MARK: - Wire types

    private struct EmbedRequest: Encodable {
        let model: String
        let input: [String]
    }

    private struct EmbedResponse: Decodable {
        let embeddings: [[Float]]
    }
}
