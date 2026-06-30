import Foundation

/// Downloads the MTEB STS-Benchmark test split from HuggingFace Datasets API
/// and caches locally as ``STSPair`` JSON.
///
/// ## Dataset
/// `mteb/stsbenchmark-sts` (test split, 1,379 pairs). Gold scores follow the
/// STS-B convention: 0 = completely dissimilar, 5 = semantically equivalent.
///
/// ## Cache format
/// The cache file is a JSON array of ``STSPair`` objects, directly loadable by
/// ``MTEBLane/loadPairs(from:)``:
/// ```json
/// [{"sentence1":"...","sentence2":"...","goldScore":2.5}, ...]
/// ```
///
/// ## Usage
/// ```swift
/// let cacheFile = URL(fileURLWithPath: "\(NSHomeDirectory())/.cache/manifold-eval/stsb_test.json")
/// let pairs = try await STSBCorpusFetcher.fetch(cacheFile: cacheFile)
/// ```
public enum STSBCorpusFetcher {

    static let rowsEndpoint = "https://datasets-server.huggingface.co/rows"
    static let datasetParam = "mteb%2Fstsbenchmark-sts"
    static let splitParam   = "test"
    static let pageSize     = 100

    public enum FetchError: Error, CustomStringConvertible, Sendable {
        case badHTTPStatus(URL, code: Int)
        case decodeFailed(reason: String)
        case cacheWriteFailed(URL, underlying: Error)
        case emptyDataset

        public var description: String {
            switch self {
            case .badHTTPStatus(let url, let code):
                return "STSBCorpusFetcher: HTTP \(code) for \(url)"
            case .decodeFailed(let reason):
                return "STSBCorpusFetcher: JSON decode failed — \(reason)"
            case .cacheWriteFailed(let dest, let underlying):
                return "STSBCorpusFetcher: cannot write cache \(dest.path): \(underlying)"
            case .emptyDataset:
                return "STSBCorpusFetcher: dataset returned 0 rows"
            }
        }
    }

    /// Loads ``STSPair`` data, downloading from HuggingFace and caching locally
    /// if the cache file does not yet exist.
    ///
    /// - Parameter cacheFile: Local path to store/load the JSON array.
    /// - Returns: All 1,379 test pairs (or however many the dataset currently has).
    /// - Throws: ``FetchError`` on network or parse failure; propagates any
    ///   error thrown by ``MTEBLane/loadPairs(from:)`` when reading a corrupted
    ///   (but present) cache file.
    public static func fetch(cacheFile: URL) async throws -> [STSPair] {
        // Fast path: load from cache without any network contact.
        if FileManager.default.fileExists(atPath: cacheFile.path) {
            let cached = try MTEBLane.loadPairs(from: cacheFile)
            if let cached, !cached.isEmpty {
                return cached
            }
            // File exists but is empty/corrupt — fall through to re-download.
        }

        // Download via paginated HuggingFace Datasets API.
        var pairs: [STSPair] = []
        var offset = 0
        var totalRows: Int? = nil

        repeat {
            var components = URLComponents(string: rowsEndpoint)
            components?.queryItems = [
                URLQueryItem(name: "dataset", value: "mteb/stsbenchmark-sts"),
                URLQueryItem(name: "config",  value: "default"),
                URLQueryItem(name: "split",   value: splitParam),
                URLQueryItem(name: "offset",  value: "\(offset)"),
                URLQueryItem(name: "length",  value: "\(pageSize)"),
            ]
            guard let pageURL = components?.url else {
                throw FetchError.decodeFailed(reason: "could not construct page URL at offset \(offset)")
            }

            let (data, response) = try await URLSession.shared.data(from: pageURL)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(statusCode) else {
                throw FetchError.badHTTPStatus(pageURL, code: statusCode)
            }

            let page: HFRowsPage
            do {
                page = try JSONDecoder().decode(HFRowsPage.self, from: data)
            } catch {
                throw FetchError.decodeFailed(reason: "\(error)")
            }

            if totalRows == nil {
                totalRows = page.numRowsTotal
            }

            pairs.append(contentsOf: page.rows.map { row in
                STSPair(
                    sentence1: row.row.sentence1,
                    sentence2: row.row.sentence2,
                    goldScore: row.row.score
                )
            })

            if page.rows.isEmpty { break }
            offset += pageSize
        } while pairs.count < (totalRows ?? Int.max)

        guard !pairs.isEmpty else { throw FetchError.emptyDataset }

        // Write cache.
        let cacheDir = cacheFile.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true
            )
        } catch {
            throw FetchError.cacheWriteFailed(cacheDir, underlying: error)
        }
        do {
            let encoded = try JSONEncoder().encode(pairs)
            try encoded.write(to: cacheFile, options: .atomic)
        } catch {
            throw FetchError.cacheWriteFailed(cacheFile, underlying: error)
        }

        return pairs
    }

    // MARK: - HuggingFace Datasets API wire types

    private struct HFRowsPage: Decodable {
        let rows: [HFRow]
        let numRowsTotal: Int

        enum CodingKeys: String, CodingKey {
            case rows
            case numRowsTotal = "num_rows_total"
        }
    }

    private struct HFRow: Decodable {
        let row: HFRowContent
    }

    private struct HFRowContent: Decodable {
        let sentence1: String
        let sentence2: String
        /// Gold similarity score on 0–5 scale.
        let score: Double
    }
}
