import Foundation

/// Pure statistical functions used by the MTEB STS lane.
///
/// All functions are referentially transparent and carry no side effects — safe
/// to call from any concurrency context without synchronisation.
public enum CorrelationMath {

    // MARK: - Cosine similarity

    /// Cosine similarity of two Float vectors.
    ///
    /// Returns `.nan` when either vector is empty, the lengths differ, or either
    /// vector has zero L2 norm (degenerate / unembeddable input). Callers must
    /// check `.isNaN` before trusting the result.
    public static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard !a.isEmpty, a.count == b.count else { return .nan }
        let dotAB = zip(a, b).reduce(Float(0)) { $0 + $1.0 * $1.1 }
        let normA = a.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        let normB = b.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        guard normA > 0, normB > 0 else { return .nan }
        // Final division in Double + clamp: Float (~7 digits) can push the ratio a
        // hair outside [-1, 1] on near-parallel vectors; cosine is defined on [-1, 1].
        let cos = Double(dotAB) / (Double(normA) * Double(normB))
        return min(1.0, max(-1.0, cos))
    }

    // MARK: - Pearson correlation

    /// Pearson product-moment correlation of two equal-length Double arrays.
    ///
    /// Returns `.nan` when arrays have fewer than 2 elements, differ in length, or
    /// have zero variance (constant array — correlation is undefined).
    public static func pearson(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count >= 2 else { return .nan }
        let n = Double(x.count)
        let mx = x.reduce(0.0, +) / n
        let my = y.reduce(0.0, +) / n
        let num = zip(x, y).reduce(0.0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        let varX = x.reduce(0.0) { $0 + ($1 - mx) * ($1 - mx) }
        let varY = y.reduce(0.0) { $0 + ($1 - my) * ($1 - my) }
        let den = (varX * varY).squareRoot()
        guard den > 0 else { return .nan }
        return num / den
    }

    // MARK: - Spearman rank correlation

    /// Spearman rank correlation of two equal-length Double arrays.
    ///
    /// Ties receive average ranks (standard practice). Returns `.nan` under the
    /// same conditions as ``pearson(_:_:)``.
    public static func spearman(_ x: [Double], _ y: [Double]) -> Double {
        guard x.count == y.count, x.count >= 2 else { return .nan }
        return pearson(ranks(x), ranks(y))
    }

    // MARK: - Internal

    /// Converts a Double array to 1-based average ranks. Tied values receive the
    /// mean of the ranks they would occupy.
    static func ranks(_ values: [Double]) -> [Double] {
        // Pair each value with its original position, then sort by value.
        let indexed = values.enumerated().map { ($1, $0) }.sorted { $0.0 < $1.0 }
        var result = [Double](repeating: 0, count: values.count)
        var i = 0
        while i < indexed.count {
            // Scan forward to find the end of a run of equal values.
            var j = i
            while j + 1 < indexed.count && indexed[j].0 == indexed[j + 1].0 {
                j += 1
            }
            // Average rank for all tied positions (1-based: positions i+1 … j+1).
            let avgRank = Double(i + j) / 2.0 + 1.0
            for k in i ... j {
                result[indexed[k].1] = avgRank
            }
            i = j + 1
        }
        return result
    }
}
