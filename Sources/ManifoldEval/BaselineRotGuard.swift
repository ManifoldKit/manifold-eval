import Foundation

/// Why a cell's baseline entry differs from its current observation. A cell can
/// report more than one kind at once (e.g. score moved AND the hash changed).
public enum CellMovementKind: Sendable, Equatable {
  /// The aggregate score moved by more than the configured threshold.
  case scoreChanged(previous: Double, current: Double, delta: Double)
  /// The cell's coarse outcome classification flipped (e.g. `pass` → `fail`,
  /// or `identical` → `genuineDivergence` for a differential-sourced baseline).
  case divergenceClassFlipped(previous: String?, current: String?)
  /// The underlying transcript content hash changed — a byte-exact replay
  /// drifted even if the aggregate score landed the same.
  case bytesHashChanged(previous: String, current: String)
  /// The cell has no prior baseline row — first time it's been observed. Not a
  /// regression signal, but surfaced so a new cell's first score is visible.
  case newCell(current: Double)
}

/// A cell whose current observation moved relative to its baseline. Unchanged
/// cells never appear here — the whole point is "surface only movements."
public struct CellChange: Sendable, Equatable {
  public let key: CellKey
  public let movements: [CellMovementKind]

  public init(key: CellKey, movements: [CellMovementKind]) {
    self.key = key
    self.movements = movements
  }
}

/// Whether — and why — the rot-guard tripped.
public struct RotGuardVerdict: Sendable, Equatable {
  /// Cell keys present in the baseline but absent from the current run's
  /// **manifest** entirely (not merely `notMeasured` this run — see
  /// ``RunManifest``). This, and only this, counts as shrink.
  public let shrunkCells: [CellKey]

  /// Whether the newest baseline row is older than the configured max age,
  /// relative to the `now` the check was run at. `false` for an empty baseline
  /// — there is nothing to be stale yet (that is the first-run state, not rot).
  public let isStale: Bool

  public let newestBaselineTimestamp: Date?
  public let maxAge: TimeInterval

  public var tripped: Bool { isStale || !shrunkCells.isEmpty }

  public init(
    shrunkCells: [CellKey], isStale: Bool, newestBaselineTimestamp: Date?, maxAge: TimeInterval
  ) {
    self.shrunkCells = shrunkCells.sorted()
    self.isStale = isStale
    self.newestBaselineTimestamp = newestBaselineTimestamp
    self.maxAge = maxAge
  }
}

/// Compares a run's per-cell observations against a persisted ``BaselineStore``
/// and evaluates the rot-guard. Pure and total — no I/O — so it's exhaustively
/// unit-testable against synthetic stores/manifests.
public enum BaselineRotGuard {

  /// Detects per-cell movement: a cell only appears in the result when at least
  /// one of score/divergenceClass/bytesHash actually moved (or it's new).
  /// Cells with no baseline row AND no current observation aren't compared at
  /// all — there is nothing on either side.
  ///
  /// - Parameters:
  ///   - scoreThreshold: minimum absolute score delta that counts as movement
  ///     (guards against float noise reporting a movement on an unchanged cell).
  public static func detectMovements(
    current: [CellKey: CellObservation],
    baseline: BaselineStore,
    scoreThreshold: Double
  ) -> [CellChange] {
    let baselineByKey = baseline.byKey
    var changes: [CellChange] = []

    for (key, observation) in current {
      guard let previous = baselineByKey[key] else {
        changes.append(CellChange(key: key, movements: [.newCell(current: observation.score)]))
        continue
      }

      var movements: [CellMovementKind] = []
      let delta = observation.score - previous.score
      if abs(delta) > scoreThreshold {
        movements.append(
          .scoreChanged(previous: previous.score, current: observation.score, delta: delta))
      }
      if previous.divergenceClass != observation.divergenceClass {
        movements.append(
          .divergenceClassFlipped(
            previous: previous.divergenceClass, current: observation.divergenceClass))
      }
      if previous.bytesHash != observation.bytesHash {
        movements.append(
          .bytesHashChanged(previous: previous.bytesHash, current: observation.bytesHash))
      }

      if !movements.isEmpty {
        changes.append(CellChange(key: key, movements: movements))
      }
    }

    return changes.sorted { $0.key < $1.key }
  }

  /// Evaluates the rot-guard: staleness of the baseline as a whole, plus a
  /// manifest-shrink check against the CURRENT run's full manifest (not just
  /// its scored observations) — a cell that regressed to `notMeasured` this run
  /// is still in the manifest and must never read as shrink.
  public static func evaluate(
    manifestKeys: Set<CellKey>,
    baseline: BaselineStore,
    maxAge: TimeInterval,
    now: Date
  ) -> RotGuardVerdict {
    let baselineKeys = Set(baseline.rows.map(\.key))
    let shrunk = baselineKeys.subtracting(manifestKeys)

    let newest = baseline.newestTimestamp
    let isStale: Bool
    if let newest {
      isStale = now.timeIntervalSince(newest) > maxAge
    } else {
      // No rows ever recorded yet — this is the pre-first-`--update` state,
      // not rot. A store with rows whose newest is merely old IS rot.
      isStale = false
    }

    return RotGuardVerdict(
      shrunkCells: Array(shrunk), isStale: isStale, newestBaselineTimestamp: newest, maxAge: maxAge
    )
  }
}
