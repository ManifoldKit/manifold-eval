/// Errors thrown by ``MTEBLane`` operations.
public enum MTEBLaneError: Error, CustomStringConvertible, Equatable {
    /// The input pair list was empty.
    case noPairs
    /// The embedder returned an unexpected number of vectors for a pair.
    case embeddingCountMismatch(pairIndex: Int, expected: Int, got: Int)
    /// A cosine could not be computed (e.g. zero-norm vector); reports the pair index.
    case unembeddablePair(pairIndex: Int)
    /// The dataset file at the given path was not decodable as [STSPair].
    case datasetDecodeFailed(path: String, reason: String)

    public var description: String {
        switch self {
        case .noPairs:
            return "MTEBLane: no pairs supplied — cannot compute correlation on an empty set"
        case .embeddingCountMismatch(let idx, let expected, let got):
            return "MTEBLane pair[\(idx)]: embedder returned \(got) vectors, expected \(expected)"
        case .unembeddablePair(let idx):
            return "MTEBLane pair[\(idx)]: zero-norm embedding — sentence is unembeddable"
        case .datasetDecodeFailed(let path, let reason):
            return "MTEBLane: cannot decode STS dataset at \(path): \(reason)"
        }
    }
}
