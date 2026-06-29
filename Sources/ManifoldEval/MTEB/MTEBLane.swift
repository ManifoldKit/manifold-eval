import Foundation
import ManifoldInference

/// MTEB Semantic Textual Similarity (STS) evaluation lane.
///
/// ## What this measures
///
/// For each sentence pair in the dataset, the lane embeds both sentences, computes
/// their cosine similarity, and then reports the Spearman and Pearson correlations
/// between those predicted similarities and the human-annotated gold scores. This
/// is the canonical MTEB-STS metric: it tests whether a model's embedding space
/// *ranks* near-synonyms higher than unrelated pairs, regardless of the absolute
/// cosine scale.
///
/// ## Dataset status (scaffolded)
///
/// The built-in ``builtinFixture`` is a 15-pair scaffold derived from the
/// STS-Benchmark style, crafted to cover the full similarity range (0–5). It is
/// suitable for correctness tests and quick smoke runs. A full STS-B/MTEB dataset
/// (e.g. `mteb/stsbenchmark-sts` from HuggingFace) is NOT bundled. To run against
/// the full dataset, download the JSON, decode it as `[STSPair]`, and pass it to
/// ``run(pairs:embedder:modelName:)``. Use ``loadPairs(from:)`` to load from disk;
/// it returns `nil` gracefully when the file is absent so a missing dataset does
/// not abort a local gate.
///
/// ## Example
///
/// ```swift
/// let driver = OllamaEmbeddingDriver()
/// let result = try await MTEBLane.run(
///     pairs: MTEBLane.builtinFixture,
///     embedder: driver,
///     modelName: OllamaEmbeddingDriver.defaultModel
/// )
/// print("Spearman:", result.spearmanCorrelation)
/// ```
public enum MTEBLane {

    // MARK: - Built-in scaffold fixture

    /// 15-pair STS scaffold covering the full 0–5 similarity range.
    ///
    /// Pairs are ordered from highest to lowest gold similarity for readability.
    /// Sentence content was chosen so that competent sentence-embedding models
    /// (e.g. nomic-embed-text) produce cosines well-correlated with the gold
    /// ordering — making the fixture suitable for a quick sanity check that a
    /// given embedder produces a sensible ranking.
    ///
    /// NOTE: this is a SCAFFOLDED fixture, not an official MTEB-STS subset.
    /// Correlation figures produced on this fixture are not comparable to
    /// official MTEB leaderboard results.
    public static let builtinFixture: [STSPair] = [
        STSPair(
            sentence1: "A dog is running in the field.",
            sentence2: "A dog is running in the meadow.",
            goldScore: 4.8
        ),
        STSPair(
            sentence1: "A cat is sleeping on the sofa.",
            sentence2: "A cat is napping on the couch.",
            goldScore: 4.6
        ),
        STSPair(
            sentence1: "The baby is crying loudly.",
            sentence2: "The infant is weeping.",
            goldScore: 4.4
        ),
        STSPair(
            sentence1: "A young child is riding a horse.",
            sentence2: "A child is riding a horse.",
            goldScore: 4.2
        ),
        STSPair(
            sentence1: "The man is playing guitar.",
            sentence2: "A man is playing a guitar.",
            goldScore: 4.0
        ),
        STSPair(
            sentence1: "The teacher explained the concept.",
            sentence2: "The professor lectured the students.",
            goldScore: 3.5
        ),
        STSPair(
            sentence1: "Children are playing in the park.",
            sentence2: "Kids are playing outside.",
            goldScore: 3.4
        ),
        STSPair(
            sentence1: "It is raining heavily outside.",
            sentence2: "The streets are flooded with water.",
            goldScore: 3.0
        ),
        STSPair(
            sentence1: "A boy kicked the ball.",
            sentence2: "A child threw the ball.",
            goldScore: 2.8
        ),
        STSPair(
            sentence1: "A woman is cooking dinner.",
            sentence2: "A woman is baking a cake.",
            goldScore: 2.5
        ),
        STSPair(
            sentence1: "The train arrived at the station.",
            sentence2: "A bus stopped at the terminal.",
            goldScore: 2.0
        ),
        STSPair(
            sentence1: "She is reading a novel.",
            sentence2: "He is writing a letter.",
            goldScore: 1.5
        ),
        STSPair(
            sentence1: "The car is parked outside.",
            sentence2: "The bicycle is chained to a post.",
            goldScore: 1.2
        ),
        STSPair(
            sentence1: "The astronaut walked on the moon.",
            sentence2: "Scientists discovered a new planet.",
            goldScore: 0.8
        ),
        STSPair(
            sentence1: "The fire truck raced to the scene.",
            sentence2: "A butterfly landed on a flower.",
            goldScore: 0.2
        ),
    ]

    // MARK: - Lane runner

    /// Run the STS lane: embed each pair, compute cosine, report correlation vs gold.
    ///
    /// The embedder's ``EmbeddingBackend/embed(_:)`` is called with 2-element batches
    /// (one per pair). Callers that want to amortise batch cost over many pairs may
    /// wrap or replace the embedder with one that pre-batches inputs.
    ///
    /// > Note: this lane is currently a library + test-driven surface — it is
    /// > exercised by `MTEBLaneOllamaLiveTests` (gated on `RUN_OLLAMA_EMBED=1`), not
    /// > yet by a `manifold-eval` CLI subcommand. A `manifold-eval mteb` runner is a
    /// > fast follow-up; the lane logic and correlation math are complete and tested.
    ///
    /// - Parameters:
    ///   - pairs: Sentence pairs to evaluate. Must not be empty.
    ///   - embedder: Any ``EmbeddingBackend`` instance. Must be loaded before this call.
    ///   - modelName: A human-readable label written into the result (e.g. the Ollama
    ///     model tag). Does not affect computation.
    /// - Throws: ``MTEBLaneError/noPairs`` when `pairs` is empty; propagates any error
    ///   thrown by the embedder; ``MTEBLaneError/embeddingCountMismatch(_:_:_:)`` if
    ///   the backend violates its postcondition.
    /// - Returns: Spearman + Pearson correlations, raw cosines, and pair count.
    public static func run(
        pairs: [STSPair],
        embedder: any EmbeddingBackend,
        modelName: String
    ) async throws -> MTEBLaneResult {
        guard !pairs.isEmpty else { throw MTEBLaneError.noPairs }

        var cosines: [Double] = []
        cosines.reserveCapacity(pairs.count)

        for (index, pair) in pairs.enumerated() {
            let vectors = try await embedder.embed([pair.sentence1, pair.sentence2])
            guard vectors.count == 2 else {
                throw MTEBLaneError.embeddingCountMismatch(
                    pairIndex: index,
                    expected: 2,
                    got: vectors.count
                )
            }
            let sim = CorrelationMath.cosine(vectors[0], vectors[1])
            if sim.isNaN {
                throw MTEBLaneError.unembeddablePair(pairIndex: index)
            }
            cosines.append(sim)
        }

        let goldScores = pairs.map(\.goldScore)
        return MTEBLaneResult(
            modelName: modelName,
            pairCount: pairs.count,
            spearmanCorrelation: CorrelationMath.spearman(cosines, goldScores),
            pearsonCorrelation: CorrelationMath.pearson(cosines, goldScores),
            cosines: cosines
        )
    }

    // MARK: - Full-dataset loader (gated on file presence)

    /// Load ``STSPair`` records from a JSON file on disk.
    ///
    /// Returns `nil` when the file does not exist — allowing callers to gate
    /// full-dataset runs gracefully without aborting. Only throws when the file
    /// exists but is unreadable or malformed.
    ///
    /// Expected JSON format: `[{"sentence1": ..., "sentence2": ..., "goldScore": ...}]`
    public static func loadPairs(from url: URL) throws -> [STSPair]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw MTEBLaneError.datasetDecodeFailed(
                path: url.path,
                reason: "could not read file: \(error)"
            )
        }
        do {
            return try JSONDecoder().decode([STSPair].self, from: data)
        } catch {
            throw MTEBLaneError.datasetDecodeFailed(
                path: url.path,
                reason: "JSON decode failed: \(error)"
            )
        }
    }
}
