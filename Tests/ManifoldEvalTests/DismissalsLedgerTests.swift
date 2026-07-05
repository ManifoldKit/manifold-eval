import XCTest
@testable import ManifoldEval

final class DismissalsLedgerTests: XCTestCase {

    private let cell = "mistral-7b-instruct-v0.3|Q4_K_M|ollama|ollama-server"

    private func signature(for text: String) -> String {
        DivergenceSignature.compute(divergenceClass: "genuineDivergence", differingText: text)
    }

    // MARK: - Suppression

    func testLiveDismissalSuppresses() {
        var ledger = DismissalsLedger()
        let finding = DismissedFinding(cell: cell, signature: signature(for: "extra trailing token"))
        let now = Date()
        ledger.record(finding, reason: "confirmed by-design: renderer whitespace", recordedAt: now, ttl: 3600)

        let surfaced = ledger.suppress([finding], asOf: now.addingTimeInterval(60))
        XCTAssertTrue(surfaced.isEmpty, "a live dismissal must suppress the finding")
    }

    func testExpiredDismissalResurfaces() {
        var ledger = DismissalsLedger()
        let finding = DismissedFinding(cell: cell, signature: signature(for: "extra trailing token"))
        let now = Date()
        ledger.record(finding, reason: "confirmed by-design", recordedAt: now, ttl: 60)

        // Well past expiry.
        let surfaced = ledger.suppress([finding], asOf: now.addingTimeInterval(120))
        XCTAssertEqual(surfaced, [finding], "an expired dismissal must resurface the cell — expiry forces a re-look")
    }

    func testChangedSignatureDoesNotSuppress() {
        var ledger = DismissalsLedger()
        let dismissed = DismissedFinding(cell: cell, signature: signature(for: "original divergence bytes"))
        let now = Date()
        ledger.record(dismissed, reason: "confirmed by-design", recordedAt: now, ttl: 3600)

        // Same cell, but the divergence now differs in content -> new signature.
        let changed = DismissedFinding(cell: cell, signature: signature(for: "a completely different divergence"))
        let surfaced = ledger.suppress([changed], asOf: now.addingTimeInterval(60))
        XCTAssertEqual(surfaced, [changed], "a changed divergence-signature is new signal and must not be suppressed")
    }

    func testUndismissedFindingSurfaces() {
        let ledger = DismissalsLedger()
        let finding = DismissedFinding(cell: cell, signature: signature(for: "never dismissed"))
        XCTAssertEqual(ledger.suppress([finding], asOf: Date()), [finding])
    }

    // MARK: - Prune

    func testPruneRemovesOnlyExpiredEntries() {
        var ledger = DismissalsLedger()
        let now = Date()
        let live = DismissedFinding(cell: cell, signature: signature(for: "live one"))
        let expired = DismissedFinding(cell: cell, signature: signature(for: "expired one"))
        ledger.record(live, reason: "still valid", recordedAt: now, ttl: 3600)
        ledger.record(expired, reason: "stale", recordedAt: now, ttl: 10)

        let asOfLater = now.addingTimeInterval(60)
        let removed = ledger.prune(asOf: asOfLater)

        XCTAssertEqual(removed.map(\.finding), [expired])
        XCTAssertEqual(ledger.count, 1)
        XCTAssertEqual(ledger.entries.first?.finding, live)
    }

    func testPruneAtExactExpiryBoundaryTreatsAsExpired() {
        var ledger = DismissalsLedger()
        let now = Date()
        let finding = DismissedFinding(cell: cell, signature: signature(for: "boundary"))
        ledger.record(finding, reason: "r", recordedAt: now, ttl: 100)

        let expiresAt = ledger.entries[0].expiresAt
        XCTAssertFalse(ledger.entries[0].isLive(asOf: expiresAt), "expiry boundary itself must read as expired, not live")
    }

    // MARK: - Round trip

    func testLedgerJSONRoundTripsStably() throws {
        var ledger = DismissalsLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.record(
            DismissedFinding(cell: "b|q|backend|renderer", signature: signature(for: "z")),
            reason: "z-reason",
            recordedAt: now,
            ttl: 3600
        )
        ledger.record(
            DismissedFinding(cell: "a|q|backend|renderer", signature: signature(for: "a")),
            reason: "a-reason",
            recordedAt: now,
            ttl: 7200
        )

        // Round-trip through the ledger's own save/load (a temp file) rather than a
        // hand-rolled decoder, so the test exercises the exact encode/decode
        // strategy the ledger uses — not a second, possibly-mismatched one.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dismissals-roundtrip-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ledger.save(to: url)
        let firstData = try Data(contentsOf: url)
        let reloaded = try DismissalsLedger.load(from: url)
        try reloaded.save(to: url)
        let secondData = try Data(contentsOf: url)

        XCTAssertEqual(firstData, secondData, "re-encoding an unchanged ledger must produce byte-identical JSON")
        XCTAssertEqual(reloaded.entries, ledger.entries)
    }

    func testLoadSaveRoundTripsThroughDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
        let url = tempDir.appendingPathComponent("dismissals-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        var ledger = DismissalsLedger()
        // Storage round-trips at millisecond precision (see makeISO8601Formatter),
        // so pin `now` to a millisecond boundary — real Date() sub-millisecond
        // jitter is not a value the ledger promises to preserve.
        let now = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 * 1000).rounded() / 1000)
        let finding = DismissedFinding(cell: cell, signature: signature(for: "disk round trip"))
        ledger.record(finding, reason: "reason", recordedAt: now, ttl: 3600)

        try ledger.save(to: url)
        let loaded = try DismissalsLedger.load(from: url)

        XCTAssertEqual(loaded.entries, ledger.entries)
    }

    /// Regression guard for the fractional-seconds codec fix: `testLedgerJSONRoundTripsStably`
    /// above pins `now` to an exact whole-second epoch (`1_800_000_000`), and
    /// `testLoadSaveRoundTripsThroughDisk` pre-rounds to a millisecond boundary —
    /// neither carries genuine sub-millisecond jitter, so neither would fail if the
    /// codec regressed to whole-second `.iso8601` truncation (both inputs already
    /// sit on a boundary the truncation wouldn't disturb, or disturb detectably).
    /// This test uses a raw, unrounded `Date()` — real sub-millisecond jitter
    /// included — and asserts the round trip is stable to millisecond precision
    /// (the codec's documented promise; ISO8601DateFormatter's fractional-seconds
    /// option itself only carries 3 digits, so exact equality isn't the right bar).
    /// A whole-second-truncating codec would drop up to ~1s here, far outside the
    /// asserted tolerance, so this fails on a revert and passes with the fix.
    func testGenuineSubMillisecondJitterSurvivesRoundTripAtMillisecondPrecision() throws {
        var ledger = DismissalsLedger()
        let now = Date()
        let finding = DismissedFinding(cell: cell, signature: signature(for: "sub-millisecond jitter"))
        ledger.record(finding, reason: "reason", recordedAt: now, ttl: 3600)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dismissals-submillis-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ledger.save(to: url)
        let reloaded = try DismissalsLedger.load(from: url)

        guard let reloadedEntry = reloaded.entries.first(where: { $0.finding == finding }) else {
            return XCTFail("expected the recorded finding to round-trip")
        }
        XCTAssertEqual(
            reloadedEntry.recordedAt.timeIntervalSince1970,
            now.timeIntervalSince1970,
            accuracy: 0.002,
            "recordedAt must survive the round trip to millisecond precision — a whole-second "
                + "`.iso8601` codec would drop up to ~1s here, far outside this tolerance"
        )
    }

    func testLoadMissingFileYieldsEmptyLedger() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID().uuidString).json")
        let ledger = try DismissalsLedger.load(from: url)
        XCTAssertEqual(ledger.count, 0)
    }

    // MARK: - Signature

    func testSignatureChangesWithDivergenceClassOrBytes() {
        let a = DivergenceSignature.compute(divergenceClass: "genuineDivergence", differingText: "x")
        let b = DivergenceSignature.compute(divergenceClass: "degenerateRepetitionLengthMismatch", differingText: "x")
        let c = DivergenceSignature.compute(divergenceClass: "genuineDivergence", differingText: "y")
        XCTAssertNotEqual(a, b, "different divergence class must yield a different signature")
        XCTAssertNotEqual(a, c, "different differing bytes must yield a different signature")
    }

    func testSignatureIsDeterministic() {
        let a = DivergenceSignature.compute(divergenceClass: "genuineDivergence", differingText: "same bytes")
        let b = DivergenceSignature.compute(divergenceClass: "genuineDivergence", differingText: "same bytes")
        XCTAssertEqual(a, b)
    }
}
