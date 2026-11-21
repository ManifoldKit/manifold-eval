import Foundation
import XCTest

@testable import ManifoldEval

final class RegressionGateLiveSupportTests: XCTestCase {
  private func fixtureData() throws -> Data {
    let url = try XCTUnwrap(
      Bundle.module.url(
        forResource: "ollama-tags-regression-gate",
        withExtension: "json",
        subdirectory: "Fixtures"))
    return try Data(contentsOf: url)
  }

  private func response(status: Int = 200) throws -> HTTPURLResponse {
    try XCTUnwrap(
      HTTPURLResponse(
        url: URL(string: "http://localhost:11434/api/tags")!,
        statusCode: status,
        httpVersion: "HTTP/1.1",
        headerFields: ["Content-Type": "application/json"])
    )
  }

  func testConfigurationPreservesHistoricalDefaultsAndIgnoresCrossQuantVariables() throws {
    let configuration = try RegressionGateLiveConfiguration(
      environment: [
        "REGRESS_BASELINE_MODEL": "must-not-leak-into-proxy",
        "REGRESS_REDRIVEN_MODEL": "must-not-leak-into-proxy",
      ])

    XCTAssertEqual(configuration.baselineModel, "llama3.1-8b:latest")
    XCTAssertEqual(configuration.reDrivenModel, "gemma3-4b:latest")
    XCTAssertEqual(configuration.stableModel, "gemma3-4b:latest")
  }

  func testConfigurationUsesIndependentExactModelOverrides() throws {
    let configuration = try RegressionGateLiveConfiguration(
      environment: [
        "REGRESSION_GATE_BASELINE_MODEL": "llama3.1:8b",
        "REGRESSION_GATE_REDRIVEN_MODEL": "gemma3:4b",
        "REGRESSION_GATE_STABLE_MODEL": "stable:exact",
      ])

    XCTAssertEqual(configuration.baselineModel, "llama3.1:8b")
    XCTAssertEqual(configuration.reDrivenModel, "gemma3:4b")
    XCTAssertEqual(configuration.stableModel, "stable:exact")
  }

  func testConfigurationRejectsEmptyOverride() {
    XCTAssertThrowsError(
      try RegressionGateLiveConfiguration(
        environment: ["REGRESSION_GATE_BASELINE_MODEL": "  "])) { error in
      XCTAssertEqual(
        error as? RegressionGateLiveConfigurationError,
        .emptyModelOverride("REGRESSION_GATE_BASELINE_MODEL"))
    }
  }

  func testPreflightRecordsExactNameDigestAndQuantization() throws {
    let evidence = try OllamaModelPreflight.evaluate(
      requiredModels: ["llama3.1:8b", "gemma3:4b", "gemma3:4b"],
      data: fixtureData(),
      response: response())

    XCTAssertEqual(
      evidence,
      [
        .init(name: "llama3.1:8b", digest: "sha256:llama31", quantizationLevel: "Q4_K_M"),
        .init(name: "gemma3:4b", digest: "sha256:gemma3", quantizationLevel: "Q4_K_M"),
      ])
  }

  func testPreflightDoesNotSubstituteSimilarInstalledAlias() throws {
    XCTAssertThrowsError(
      try OllamaModelPreflight.evaluate(
        requiredModels: ["llama3.1-8b:latest"],
        data: fixtureData(),
        response: response())
    ) { error in
      guard let preflightError = error as? OllamaModelPreflightError,
        case .missingModels(let required, let available) = preflightError
      else { return XCTFail("unexpected error: \(error)") }
      XCTAssertEqual(required, ["llama3.1-8b:latest"])
      XCTAssertEqual(available, ["gemma3:4b", "llama3.1:8b"])
      XCTAssertTrue(error.localizedDescription.contains("No regression scores were measured"))
    }
  }

  func testPreflightRejectsNonSuccessHTTPBeforeDecoding() throws {
    XCTAssertThrowsError(
      try OllamaModelPreflight.evaluate(
        requiredModels: ["llama3.1:8b"],
        data: fixtureData(),
        response: response(status: 503))
    ) { error in
      XCTAssertEqual(error as? OllamaModelPreflightError, .httpStatus(503))
    }
  }

  func testPreflightRejectsMalformedJSON() throws {
    XCTAssertThrowsError(
      try OllamaModelPreflight.evaluate(
        requiredModels: ["llama3.1:8b"],
        data: Data("{not-json".utf8),
        response: response())
    ) { error in
      guard let preflightError = error as? OllamaModelPreflightError,
        case .invalidJSON = preflightError
      else {
        return XCTFail("unexpected error: \(error)")
      }
    }
  }
}
