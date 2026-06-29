import Foundation
import CryptoKit

/// SHA-256 of the exact prompt STRING bytes — the same-bytes control's anchor.
///
/// CryptoKit (a macOS system framework, available at the v15 floor) is used rather
/// than pulling swift-crypto as a direct dependency: the hash is computed over
/// UTF-8 bytes, so the digest is stable across machines for the same string.
public enum PromptHash {
    /// Lowercase hex SHA-256 of `string`'s UTF-8 bytes.
    public static func sha256Hex(of string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
