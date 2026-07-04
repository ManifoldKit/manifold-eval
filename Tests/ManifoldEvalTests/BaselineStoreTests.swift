import XCTest
@testable import ManifoldEval
import ManifoldTools

/// Unit tests for ``BaselineStore``, ``BaselineCollector``, and
/// ``BaselineRotGuard``. Pure logic over synthetic ``ConformanceRecord``s and
/// in-memory stores — no I/O beyond a scratch temp-directory round-trip, no
/// model, no network.
final class BaselineStoreTests: XCTestCase {

    // MARK: - Fixture helpers

    private func record(
        backend: String = "ollama",
        model: String = "mistral-7b-instruct-v0.3",
        quant: String = "Q4_K_M",
        renderer: String = "ollama-server",
        scenario: String = "weather-lookup",
        status: CellStatus = .measured,
        verdict: ConformanceScorer.Verdict? = .pass,
        f1: Double? = 1.0,
        transcriptRef: String = "ollama/weather-lookup.jsonl",
        coreCommit: String = "4461529f"
    ) -> ConformanceRecord {
        ConformanceRecord(
            backend: backend,
            model: model,
            quant: quant,
            renderer: renderer,
            scenario: scenario,
            decoyLevel: 0,
            repeatIndex: 0,
            status: status,
            verdict: verdict,
            toolSelection: f1.map { Scores(precision: $0, recall: $0, f1: $0) },
            failureClass: nil,
            transcriptRef: transcriptRef,
            coreCommit: coreCommit,
            toolingVersions: ["ollama": "0.30.11"]
        )
    }

    private func key(
        model: String = "mistral-7b-instruct-v0.3",
        quant: String = "Q4_K_M",
        backend: String = "ollama",
        renderer: String = "ollama-server"
    ) -> CellKey {
        CellKey(model: model, quant: quant, backend: backend, renderer: renderer)
    }

    private func scratchPath() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("baseline-store-tests-\(UUID().uuidString)")
            .appendingPathComponent("BASELINE.json")
    }

    // MARK: - Round-trip

    func testRoundTripWriteThenReadIsStable() throws {
        let manifest = try BaselineCollector.build(from: [record()])
        let store = BaselineStore.empty.updated(with: manifest.observations, timestamp: Date(timeIntervalSince1970: 1_000))

        let path = scratchPath()
        try store.save(path: path)
        let reloaded = try BaselineStore.load(path: path)

        XCTAssertEqual(reloaded, store, "a store written then read back must round-trip exactly")

        // sabotage: mutating one field before comparing must break equality —
        // proves the equality check isn't vacuously true.
        // let mutated = BaselineStore(rows: reloaded.rows.map {
        //     BaselineRow(key: $0.key, entry: BaselineEntry(score: $0.entry.score + 1, bytesHash: $0.entry.bytesHash, divergenceClass: $0.entry.divergenceClass, timestamp: $0.entry.timestamp, coreCommit: $0.entry.coreCommit))
        // })
        // XCTAssertEqual(mutated, store)
    }

    func testReWriteOfSameContentIsByteIdentical() throws {
        let manifest = try BaselineCollector.build(from: [record()])
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let store = BaselineStore.empty.updated(with: manifest.observations, timestamp: timestamp)

        let pathA = scratchPath()
        let pathB = scratchPath()
        try store.save(path: pathA)
        try store.save(path: pathB)

        let dataA = try Data(contentsOf: pathA)
        let dataB = try Data(contentsOf: pathB)
        XCTAssertEqual(dataA, dataB, "re-writing identical logical content must diff cleanly (byte-identical)")
    }

    func testLoadMissingFileReturnsEmptyStore() throws {
        let path = scratchPath() // never written
        let store = try BaselineStore.load(path: path)
        XCTAssertEqual(store, .empty)
    }

    func testUpdatePreservesRowsOutsideCurrentRunScope() throws {
        let untouchedKey = key(model: "other-model")
        let seeded = BaselineStore(rows: [
            BaselineRow(
                key: untouchedKey,
                entry: BaselineEntry(score: 0.5, bytesHash: "abc", divergenceClass: "pass", timestamp: Date(timeIntervalSince1970: 1), coreCommit: "deadbeef")
            ),
        ])

        let manifest = try BaselineCollector.build(from: [record()])
        let updated = seeded.updated(with: manifest.observations, timestamp: Date(timeIntervalSince1970: 500))

        XCTAssertEqual(updated.byKey[untouchedKey]?.score, 0.5, "a cell outside this run's scope must survive an --update untouched")
        XCTAssertNotNil(updated.byKey[key()], "the current run's cell must be written")

        // sabotage: asserting the untouched row was ALSO overwritten should fail.
        // XCTAssertEqual(updated.byKey[untouchedKey]?.timestamp, Date(timeIntervalSince1970: 500))
    }

    // MARK: - Comparability guard

    func testMixedCoreCommitsInCurrentRunIsRejected() {
        XCTAssertThrowsError(try BaselineCollector.build(from: [
            record(coreCommit: "aaaa"),
            record(coreCommit: "bbbb"),
        ])) { error in
            guard case BaselineCollector.BuildError.mixedCoreCommits(let commits) = error else {
                return XCTFail("expected mixedCoreCommits, got \(error)")
            }
            XCTAssertEqual(commits, ["aaaa", "bbbb"])
        }
    }

    // MARK: - Movement detection

    func testScoreChangeBeyondThresholdIsDetected() throws {
        let baselineManifest = try BaselineCollector.build(from: [record(f1: 0.9)])
        let baseline = BaselineStore.empty.updated(with: baselineManifest.observations, timestamp: Date())

        let currentManifest = try BaselineCollector.build(from: [record(f1: 0.5)])
        let changes = BaselineRotGuard.detectMovements(current: currentManifest.observations, baseline: baseline, scoreThreshold: 0.05)

        XCTAssertEqual(changes.count, 1)
        guard case .scoreChanged(let previous, let current, let delta)? = changes.first?.movements.first(where: {
            if case .scoreChanged = $0 { return true } else { return false }
        }) else { return XCTFail("expected a scoreChanged movement") }
        XCTAssertEqual(previous, 0.9)
        XCTAssertEqual(current, 0.5)
        XCTAssertEqual(delta, -0.4, accuracy: 0.0001)

        // sabotage: an assertion of no-movement here should fail.
        // XCTAssertTrue(changes.isEmpty)
    }

    func testScoreChangeWithinThresholdIsSilent() throws {
        let baselineManifest = try BaselineCollector.build(from: [record(f1: 0.90)])
        let baseline = BaselineStore.empty.updated(with: baselineManifest.observations, timestamp: Date())

        let currentManifest = try BaselineCollector.build(from: [record(f1: 0.91)])
        let changes = BaselineRotGuard.detectMovements(current: currentManifest.observations, baseline: baseline, scoreThreshold: 0.05)

        XCTAssertTrue(changes.isEmpty, "a score delta within threshold must be silent")
    }

    func testDivergenceClassFlipIsDetected() throws {
        let baselineManifest = try BaselineCollector.build(from: [record(verdict: .pass, f1: nil)])
        let baseline = BaselineStore.empty.updated(with: baselineManifest.observations, timestamp: Date())

        // Same f1-derived score path (verdict-derived, since f1 is nil) but the
        // verdict itself flips fail — that's the "class flip" signal, independent
        // of the score threshold (score also moves here, which is expected and fine).
        let currentManifest = try BaselineCollector.build(from: [record(verdict: .fail, f1: nil)])
        let changes = BaselineRotGuard.detectMovements(current: currentManifest.observations, baseline: baseline, scoreThreshold: 0.05)

        XCTAssertEqual(changes.count, 1)
        let flip = changes[0].movements.first { if case .divergenceClassFlipped = $0 { return true } else { return false } }
        guard case .divergenceClassFlipped(let previous, let current)? = flip else {
            return XCTFail("expected a divergenceClassFlipped movement, got \(changes[0].movements)")
        }
        XCTAssertEqual(previous, "pass")
        XCTAssertEqual(current, "fail")
    }

    func testBytesHashChangeIsDetectedEvenWithoutScoreMovement() throws {
        let baselineManifest = try BaselineCollector.build(from: [record(transcriptRef: "ollama/run-a.jsonl")])
        let baseline = BaselineStore.empty.updated(with: baselineManifest.observations, timestamp: Date())

        // Same score/verdict, different transcript ref → same aggregate score,
        // different bytesHash — a byte-exact replay drift the score alone hides.
        let currentManifest = try BaselineCollector.build(from: [record(transcriptRef: "ollama/run-b.jsonl")])
        let changes = BaselineRotGuard.detectMovements(current: currentManifest.observations, baseline: baseline, scoreThreshold: 0.05)

        XCTAssertEqual(changes.count, 1)
        let hashChange = changes[0].movements.first { if case .bytesHashChanged = $0 { return true } else { return false } }
        XCTAssertNotNil(hashChange, "a transcriptRef change must surface as a bytesHash movement even though score/verdict are identical")

        let scoreChange = changes[0].movements.first { if case .scoreChanged = $0 { return true } else { return false } }
        XCTAssertNil(scoreChange, "score/verdict are unchanged — only the hash should move")
    }

    func testUnchangedCellIsSilent() throws {
        let manifest = try BaselineCollector.build(from: [record()])
        let baseline = BaselineStore.empty.updated(with: manifest.observations, timestamp: Date())

        // Re-derive from an identical input set — everything about the cell matches.
        let currentManifest = try BaselineCollector.build(from: [record()])
        let changes = BaselineRotGuard.detectMovements(current: currentManifest.observations, baseline: baseline, scoreThreshold: 0.05)

        XCTAssertTrue(changes.isEmpty, "an identical cell must never appear in the movement report")
    }

    // MARK: - Rot-guard: staleness

    func testRotGuardTripsOnStaleBaseline() {
        let old = Date(timeIntervalSince1970: 0)
        let baseline = BaselineStore(rows: [
            BaselineRow(key: key(), entry: BaselineEntry(score: 1.0, bytesHash: "abc", divergenceClass: "pass", timestamp: old, coreCommit: "4461529f")),
        ])

        let verdict = BaselineRotGuard.evaluate(
            manifestKeys: [key()], baseline: baseline, maxAge: 3600, now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertTrue(verdict.isStale)
        XCTAssertTrue(verdict.tripped)
        XCTAssertTrue(verdict.shrunkCells.isEmpty, "staleness alone must not also report a shrink")

        // sabotage: asserting NOT stale here should fail.
        // XCTAssertFalse(verdict.isStale)
    }

    func testRotGuardDoesNotTripWithinMaxAge() {
        let recent = Date(timeIntervalSince1970: 9_000)
        let baseline = BaselineStore(rows: [
            BaselineRow(key: key(), entry: BaselineEntry(score: 1.0, bytesHash: "abc", divergenceClass: "pass", timestamp: recent, coreCommit: "4461529f")),
        ])

        let verdict = BaselineRotGuard.evaluate(
            manifestKeys: [key()], baseline: baseline, maxAge: 3600, now: Date(timeIntervalSince1970: 10_000)
        )

        XCTAssertFalse(verdict.tripped)
    }

    func testEmptyBaselineIsNotStale() {
        let verdict = BaselineRotGuard.evaluate(manifestKeys: [], baseline: .empty, maxAge: 3600, now: Date())
        XCTAssertFalse(verdict.isStale, "an empty (never-written) baseline is the pre-first-update state, not rot")
        XCTAssertFalse(verdict.tripped)
    }

    // MARK: - Rot-guard: manifest shrink

    func testRotGuardTripsOnManifestShrink() {
        let vanished = key(model: "vanished-model")
        let baseline = BaselineStore(rows: [
            BaselineRow(key: vanished, entry: BaselineEntry(score: 1.0, bytesHash: "abc", divergenceClass: "pass", timestamp: Date(), coreCommit: "4461529f")),
        ])

        // The current run's manifest doesn't mention `vanished` at all.
        let verdict = BaselineRotGuard.evaluate(manifestKeys: [key()], baseline: baseline, maxAge: 999_999, now: Date())

        XCTAssertTrue(verdict.tripped)
        XCTAssertEqual(verdict.shrunkCells, [vanished])

        // sabotage: asserting no shrink here should fail.
        // XCTAssertTrue(verdict.shrunkCells.isEmpty)
    }

    func testNotMeasuredCellPresentInManifestDoesNotTripShrinkOrRegression() throws {
        // Seed a baseline where the cell previously scored well.
        let baselineManifest = try BaselineCollector.build(from: [record(f1: 1.0)])
        let baseline = BaselineStore.empty.updated(with: baselineManifest.observations, timestamp: Date())

        // This run: the SAME cell is present in the input (so it's in the
        // manifest) but every record for it is notMeasured — e.g. the backend
        // was offline this cycle.
        let currentRecords = [record(status: .notMeasured("backend offline"), verdict: nil, f1: nil)]
        let currentManifest = try BaselineCollector.build(from: currentRecords)

        XCTAssertTrue(currentManifest.observations.isEmpty, "a wholly-notMeasured cell must produce no observation")
        XCTAssertEqual(currentManifest.manifestKeys, [key()], "but it must still be present in the manifest")

        let rotVerdict = BaselineRotGuard.evaluate(
            manifestKeys: currentManifest.manifestKeys, baseline: baseline, maxAge: 999_999, now: Date()
        )
        XCTAssertTrue(rotVerdict.shrunkCells.isEmpty, "a notMeasured-but-present cell must never read as shrink")
        XCTAssertFalse(rotVerdict.tripped)

        let changes = BaselineRotGuard.detectMovements(current: currentManifest.observations, baseline: baseline, scoreThreshold: 0.05)
        XCTAssertTrue(changes.isEmpty, "a notMeasured cell has no observation to compare — it must never read as a regression")

        // sabotage: asserting the cell WAS reported as shrunk should fail.
        // XCTAssertEqual(rotVerdict.shrunkCells, [key()])
    }
}
