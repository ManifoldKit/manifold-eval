import Foundation

struct RegressionGateLiveConfiguration: Equatable, Sendable {
  static let baselineModelEnvironmentKey = "REGRESSION_GATE_BASELINE_MODEL"
  static let reDrivenModelEnvironmentKey = "REGRESSION_GATE_REDRIVEN_MODEL"
  static let stableModelEnvironmentKey = "REGRESSION_GATE_STABLE_MODEL"

  // Preserve the historical fixture defaults for existing operators. Current
  // installations should pass their exact `/api/tags` names explicitly.
  static let historicalBaselineModel = "llama3.1-8b:latest"
  static let historicalReDrivenModel = "gemma3-4b:latest"

  let baselineModel: String
  let reDrivenModel: String
  let stableModel: String

  init(environment: [String: String]) throws {
    baselineModel = try Self.model(
      key: Self.baselineModelEnvironmentKey,
      fallback: Self.historicalBaselineModel,
      environment: environment)
    reDrivenModel = try Self.model(
      key: Self.reDrivenModelEnvironmentKey,
      fallback: Self.historicalReDrivenModel,
      environment: environment)
    stableModel = try Self.model(
      key: Self.stableModelEnvironmentKey,
      fallback: Self.historicalReDrivenModel,
      environment: environment)
  }

  private static func model(
    key: String,
    fallback: String,
    environment: [String: String]
  ) throws -> String {
    guard let configured = environment[key] else { return fallback }
    guard !configured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw RegressionGateLiveConfigurationError.emptyModelOverride(key)
    }
    return configured
  }
}

enum RegressionGateLiveConfigurationError: Error, Equatable, LocalizedError {
  case emptyModelOverride(String)
  case invalidOllamaURL(String)

  var errorDescription: String? {
    switch self {
    case .emptyModelOverride(let key):
      return "\(key) is empty; set it to an exact model name from Ollama /api/tags"
    case .invalidOllamaURL(let raw):
      return "invalid OLLAMA_URL: \(raw)"
    }
  }
}

struct OllamaModelEvidence: Equatable, Sendable {
  let name: String
  let digest: String
  let quantizationLevel: String?
}

enum OllamaModelPreflightError: Error, Equatable, LocalizedError {
  case nonHTTPResponse
  case httpStatus(Int)
  case invalidJSON(String)
  case missingModels(required: [String], available: [String])

  var errorDescription: String? {
    switch self {
    case .nonHTTPResponse:
      return "Ollama /api/tags returned a non-HTTP response"
    case .httpStatus(let status):
      return "Ollama /api/tags returned HTTP \(status)"
    case .invalidJSON(let detail):
      return "Ollama /api/tags returned invalid JSON: \(detail)"
    case .missingModels(let required, let available):
      let pulls = required.map { "ollama pull \($0)" }.joined(separator: "; ")
      return "missing required Ollama model(s): \(required.joined(separator: ", ")). "
        + "No regression scores were measured. Pull the exact tags (\(pulls)) or set "
        + "\(RegressionGateLiveConfiguration.baselineModelEnvironmentKey)/"
        + "\(RegressionGateLiveConfiguration.reDrivenModelEnvironmentKey)/"
        + "\(RegressionGateLiveConfiguration.stableModelEnvironmentKey). "
        + "Available tags: \(available.isEmpty ? "<none>" : available.joined(separator: ", "))"
    }
  }
}

enum OllamaModelPreflight {
  private struct TagsResponse: Decodable {
    struct Model: Decodable {
      struct Details: Decodable {
        let quantizationLevel: String?

        private enum CodingKeys: String, CodingKey {
          case quantizationLevel = "quantization_level"
        }
      }

      let name: String
      let digest: String
      let details: Details?
    }

    let models: [Model]
  }

  static func fetch(
    requiredModels: [String],
    baseURL: URL,
    session: URLSession = .shared
  ) async throws -> [OllamaModelEvidence] {
    let (data, response) = try await session.data(
      from: baseURL.appendingPathComponent("api/tags"))
    return try evaluate(requiredModels: requiredModels, data: data, response: response)
  }

  static func evaluate(
    requiredModels: [String],
    data: Data,
    response: URLResponse
  ) throws -> [OllamaModelEvidence] {
    guard let http = response as? HTTPURLResponse else {
      throw OllamaModelPreflightError.nonHTTPResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw OllamaModelPreflightError.httpStatus(http.statusCode)
    }

    let payload: TagsResponse
    do {
      payload = try JSONDecoder().decode(TagsResponse.self, from: data)
    } catch {
      throw OllamaModelPreflightError.invalidJSON(String(describing: error))
    }

    let byName = Dictionary(
      payload.models.map {
        (
          $0.name,
          OllamaModelEvidence(
            name: $0.name,
            digest: $0.digest,
            quantizationLevel: $0.details?.quantizationLevel)
        )
      },
      uniquingKeysWith: { first, _ in first })
    let uniqueRequired = requiredModels.reduce(into: [String]()) { result, name in
      if !result.contains(name) { result.append(name) }
    }
    let missing = uniqueRequired.filter { byName[$0] == nil }
    guard missing.isEmpty else {
      throw OllamaModelPreflightError.missingModels(
        required: missing,
        available: byName.keys.sorted())
    }
    return uniqueRequired.compactMap { byName[$0] }
  }
}
