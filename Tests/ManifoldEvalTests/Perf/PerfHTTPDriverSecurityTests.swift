import Foundation
import XCTest

@testable import ManifoldEval

private final class SecurityCaptureProtocol: URLProtocol {
  private static let lock = NSLock()
  nonisolated(unsafe) private static var requestCountStorage = 0
  static var requestCount: Int { lock.withLock { requestCountStorage } }
  static func reset() { lock.withLock { requestCountStorage = 0 } }
  private static func recordRequest() {
    lock.withLock { requestCountStorage += 1 }
  }

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    Self.recordRequest()
    client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
  }
  override func stopLoading() {}
}

final class PerfHTTPDriverSecurityTests: XCTestCase {
  func testEndpointPolicyAllowsHTTPSAndExactLoopbackHTTP() throws {
    for endpoint in [
      "https://models.example.com", "http://localhost:11434", "http://LOCALHOST.:11434",
      "http://127.0.0.1:8000", "http://127.42.0.9:8000", "http://[::1]:8000",
    ] {
      XCTAssertNoThrow(try PerfEndpointPolicy.validatedBaseURL(endpoint), endpoint)
    }
  }

  func testEndpointPolicyRejectsRemoteHTTPAndLoopbackLookalikes() {
    for endpoint in [
      "http://203.0.113.7:8080", "http://localhost.example.com", "http://127.0.0.1.example.com",
      "http://128.0.0.1", "http://[::2]", "ftp://localhost/model",
    ] {
      XCTAssertThrowsError(try PerfEndpointPolicy.validatedBaseURL(endpoint), endpoint)
    }
  }

  func testRemoteHTTPIsRejectedBeforeSessionOrSyntheticCredentialIsUsed() async throws {
    SecurityCaptureProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SecurityCaptureProtocol.self]
    let driver = PerfHTTPDriver(session: URLSession(configuration: configuration))
    let oldValue = ProcessInfo.processInfo.environment["MK_PERF_SECURITY_TEST_KEY"]
    setenv("MK_PERF_SECURITY_TEST_KEY", "synthetic-secret", 1)
    defer {
      if let oldValue {
        setenv("MK_PERF_SECURITY_TEST_KEY", oldValue, 1)
      } else {
        unsetenv("MK_PERF_SECURITY_TEST_KEY")
      }
    }
    let generation = try BenchSpec.GenerationProtocol(
      prompt: "synthetic prompt", temperature: 0, maxTokens: 1, warmupRuns: 0, timedRuns: 1)

    for transport in [BenchSpec.Transport.httpOpenAI, .httpOllama] {
      let lane = BenchSpec.Lane(
        name: "blocked", transport: transport, endpoint: "http://203.0.113.7:8080",
        model: "synthetic", quant: "none", apiKeyEnv: "MK_PERF_SECURITY_TEST_KEY")
      do {
        _ = try await driver.run(lane: lane, protocolConfig: generation)
        XCTFail("remote plaintext HTTP should be rejected for \(transport.rawValue)")
      } catch let error as PerfDriverError {
        guard case .invalidEndpoint = error else { return XCTFail("unexpected error: \(error)") }
      }
    }
    XCTAssertEqual(SecurityCaptureProtocol.requestCount, 0)
  }

  func testInvalidOllamaProvenanceEndpointDoesNotReachSession() async {
    SecurityCaptureProtocol.reset()
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [SecurityCaptureProtocol.self]
    let driver = PerfHTTPDriver(session: URLSession(configuration: configuration))
    let lane = BenchSpec.Lane(
      name: "blocked", transport: .httpOllama, endpoint: "http://203.0.113.7:8080",
      model: "synthetic", quant: "none")

    let provenance = await driver.fetchProvenance(lane: lane)

    XCTAssertNil(provenance.engineVersion)
    XCTAssertNil(provenance.modelDigest)
    XCTAssertEqual(SecurityCaptureProtocol.requestCount, 0)
  }

  func testRedirectGuardRejectsDowngradeAndStripsCrossOriginCredentials() throws {
    var downgrade = URLRequest(url: URL(string: "http://api.example.com/next")!)
    downgrade.setValue("Bearer synthetic-secret", forHTTPHeaderField: "Authorization")
    XCTAssertNil(
      PerfRedirectGuard.redirectedRequest(
        originalURL: URL(string: "https://api.example.com/start"),
        currentURL: URL(string: "https://api.example.com/start"),
        request: downgrade)
    )

    var crossOrigin = URLRequest(url: URL(string: "https://other.example.com/next")!)
    crossOrigin.setValue("Bearer synthetic-secret", forHTTPHeaderField: "Authorization")
    crossOrigin.setValue("session=synthetic", forHTTPHeaderField: "Cookie")
    crossOrigin.setValue("Basic synthetic", forHTTPHeaderField: "Proxy-Authorization")
    crossOrigin.setValue("synthetic", forHTTPHeaderField: "X-API-Key")
    let sanitized = try XCTUnwrap(
      PerfRedirectGuard.redirectedRequest(
        originalURL: URL(string: "https://api.example.com/start"),
        currentURL: URL(string: "https://api.example.com/start"),
        request: crossOrigin)
    )
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Cookie"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "Proxy-Authorization"))
    XCTAssertNil(sanitized.value(forHTTPHeaderField: "X-API-Key"))

    var sameOrigin = URLRequest(url: URL(string: "https://api.example.com:443/next")!)
    sameOrigin.setValue("Bearer synthetic-secret", forHTTPHeaderField: "Authorization")
    let retained = try XCTUnwrap(
      PerfRedirectGuard.redirectedRequest(
        originalURL: URL(string: "https://api.example.com/start"),
        currentURL: URL(string: "https://api.example.com/start"),
        request: sameOrigin)
    )
    XCTAssertEqual(
      retained.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-secret")
  }

  func testRedirectGuardRejectsPerHopDowngradeInMultiHopChain() throws {
    let original = URLRequest(url: URL(string: "http://127.0.0.1:8000/start")!)
    let task = URLSession.shared.dataTask(with: original)
    let currentResponse = try XCTUnwrap(
      HTTPURLResponse(
        url: URL(string: "https://models.example.com/intermediate")!,
        statusCode: 302,
        httpVersion: "HTTP/1.1",
        headerFields: ["Location": "http://127.0.0.1:8000/final"]
      )
    )
    var next = URLRequest(url: URL(string: "http://127.0.0.1:8000/final")!)
    next.setValue("Bearer synthetic-secret", forHTTPHeaderField: "Authorization")
    let callback = expectation(description: "redirect callback")
    var acceptedRequest: URLRequest?

    PerfRedirectGuard().urlSession(
      .shared,
      task: task,
      willPerformHTTPRedirection: currentResponse,
      newRequest: next
    ) { request in
      acceptedRequest = request
      callback.fulfill()
    }

    wait(for: [callback], timeout: 1)
    XCTAssertNil(acceptedRequest)
  }
}
