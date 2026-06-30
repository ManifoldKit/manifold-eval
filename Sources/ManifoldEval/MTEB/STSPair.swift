import Foundation

/// One sentence pair with a human-annotated semantic similarity gold score,
/// as used in MTEB's Semantic Textual Similarity (STS) benchmarks.
///
/// Gold scores follow the STS-Benchmark convention: 0 = completely dissimilar,
/// 5 = semantically equivalent. Consumers that need a 0–1 scale divide by 5.
public struct STSPair: Codable, Sendable, Equatable {
    public let sentence1: String
    public let sentence2: String
    /// Human-annotated similarity on a 0–5 scale (STS-Benchmark convention).
    public let goldScore: Double

    public init(sentence1: String, sentence2: String, goldScore: Double) {
        self.sentence1 = sentence1
        self.sentence2 = sentence2
        self.goldScore = goldScore
    }
}
