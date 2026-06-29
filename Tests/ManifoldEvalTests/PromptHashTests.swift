import XCTest
@testable import ManifoldEval

final class PromptHashTests: XCTestCase {

    /// Known SHA-256 vectors — pins the digest so a hashing change can't slip
    /// through (the same-bytes control's integrity depends on this being stable
    /// and cross-machine reproducible).
    func testKnownVectors() {
        XCTAssertEqual(
            PromptHash.sha256Hex(of: ""),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            PromptHash.sha256Hex(of: "abc"),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testHashIsLowercaseHex64() {
        let hash = PromptHash.sha256Hex(of: "the quick brown fox")
        XCTAssertEqual(hash.count, 64)
        XCTAssertTrue(hash.allSatisfy { "0123456789abcdef".contains($0) })
    }

    func testDistinctStringsHashDistinctly() {
        XCTAssertNotEqual(PromptHash.sha256Hex(of: "a"), PromptHash.sha256Hex(of: "b"))
    }
}
