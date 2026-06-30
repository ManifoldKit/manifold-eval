import Foundation

/// Downloads the Gorilla BFCL v4 corpus from GitHub and caches locally.
///
/// Files are cached to avoid repeated network traffic across runs. The cache
/// mirrors the Gorilla repo structure under `cacheDir`:
///   `cacheDir/data/<stem>.json`          — question files
///   `cacheDir/data/possible_answer/<stem>.json` — answer files
///
/// A failed download throws ``FetchError`` so ``BFCLLane`` can mark the category
/// skipped rather than propagating a network failure to the caller.
public enum BFCLCorpusFetcher {

    static let gorillaBase =
        "https://raw.githubusercontent.com/ShishirPatil/gorilla/main" +
        "/berkeley-function-call-leaderboard/bfcl_eval/data"

    public enum FetchError: Error, CustomStringConvertible, Sendable {
        case badHTTPStatus(URL, code: Int)
        case cacheWriteFailed(URL, underlying: Error)

        public var description: String {
            switch self {
            case .badHTTPStatus(let url, let code):
                return "BFCLCorpusFetcher: HTTP \(code) for \(url)"
            case .cacheWriteFailed(let dest, let underlying):
                return "BFCLCorpusFetcher: cannot write cache \(dest.path): \(underlying)"
            }
        }
    }

    /// Downloads questions + answer files for `category` into `cacheDir`.
    ///
    /// Returns the local cached URLs. The answers URL is `nil` for irrelevance
    /// (the Gorilla corpus has no possible_answer file for that category).
    ///
    /// - Throws: ``FetchError`` when a download or cache write fails.
    public static func fetch(
        category: BFCLCategory,
        cacheDir: URL
    ) async throws -> (questions: URL, answers: URL?) {
        let dataDir = cacheDir.appendingPathComponent("data")
        let answersDir = dataDir.appendingPathComponent("possible_answer")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        if category.hasGroundTruth {
            try FileManager.default.createDirectory(at: answersDir, withIntermediateDirectories: true)
        }

        let questionsStem = category.gorillaQuestionsStem
        let questionsLocal = dataDir.appendingPathComponent("\(questionsStem).json")
        let questionsRemote = "\(gorillaBase)/\(questionsStem).json"
        try await downloadIfAbsent(from: questionsRemote, to: questionsLocal)

        let answersLocal: URL?
        if let answersStem = category.gorillaAnswersStem {
            let dest = answersDir.appendingPathComponent("\(answersStem).json")
            let remote = "\(gorillaBase)/possible_answer/\(answersStem).json"
            try await downloadIfAbsent(from: remote, to: dest)
            answersLocal = dest
        } else {
            answersLocal = nil
        }

        return (questionsLocal, answersLocal)
    }

    // MARK: - Private helpers

    private static func downloadIfAbsent(from remoteString: String, to dest: URL) async throws {
        guard !FileManager.default.fileExists(atPath: dest.path) else { return }

        guard let remote = URL(string: remoteString) else {
            // Malformed URL means a programming error in the stem constants above.
            // Use a placeholder that will produce a meaningful HTTP error.
            throw FetchError.badHTTPStatus(dest, code: -1)
        }

        let (data, response) = try await URLSession.shared.data(from: remote)

        guard let http = response as? HTTPURLResponse else {
            throw FetchError.badHTTPStatus(remote, code: -1)
        }
        if http.statusCode != 200 {
            throw FetchError.badHTTPStatus(remote, code: http.statusCode)
        }

        do {
            try data.write(to: dest, options: .atomic)
        } catch {
            throw FetchError.cacheWriteFailed(dest, underlying: error)
        }
    }
}
