/// The output of one MTEB STS lane run.
///
/// `spearmanCorrelation` / `pearsonCorrelation` are the standard MTEB-STS metrics:
/// they compare the *rank ordering* of model-predicted cosine similarities against
/// the rank ordering of human gold scores — a high rank correlation means the model
/// correctly separates near-synonyms from unrelated pairs without requiring its
/// cosine scale to match the 0–5 gold scale numerically.
public struct MTEBLaneResult: Sendable {
    /// Embedding model identifier (Ollama model name, or an arbitrary label).
    public let modelName: String
    /// Number of sentence pairs evaluated.
    public let pairCount: Int
    /// Spearman rank correlation between cosine similarities and gold scores.
    /// `.nan` when fewer than 2 valid pairs exist.
    public let spearmanCorrelation: Double
    /// Pearson correlation between cosine similarities and gold scores.
    /// `.nan` under the same conditions as ``spearmanCorrelation``.
    public let pearsonCorrelation: Double
    /// Cosine similarity for each pair, in input order. `.nan` entries indicate
    /// pairs where at least one sentence produced a zero-norm embedding.
    public let cosines: [Double]

    public init(
        modelName: String,
        pairCount: Int,
        spearmanCorrelation: Double,
        pearsonCorrelation: Double,
        cosines: [Double]
    ) {
        self.modelName = modelName
        self.pairCount = pairCount
        self.spearmanCorrelation = spearmanCorrelation
        self.pearsonCorrelation = pearsonCorrelation
        self.cosines = cosines
    }
}
