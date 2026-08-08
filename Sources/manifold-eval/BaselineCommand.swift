import Foundation
import ManifoldEval
import ManifoldTools

/// The `baseline` subcommand: a `collate`-adjacent lane that makes "did the cell
/// move?" mechanical instead of a human re-reading `MATRIX.md` (ManifoldKit issue
/// #22 / this repo's rot-guard follow-up to PR #19).
///
/// Two modes over the same `[ConformanceRecord]` JSON input `collate` consumes:
///
///   manifold-eval baseline <record.json>... --baseline-path PATH --update
///       Writes the current run's per-cell observations into the baseline store
///       (creating it if absent). Cells outside this run's scope are left alone.
///
///   manifold-eval baseline <record.json>... --baseline-path PATH
///       Diffs the current run against the stored baseline, prints ONLY the
///       cells that moved, and evaluates the rot-guard (stale baseline / a
///       shrunk cell manifest). See exit codes below.
enum BaselineCommand {

  /// Exit codes:
  ///   0 = update succeeded, OR compare found no movement and no rot
  ///   1 = compare found movement (a human should judge it), OR a data error
  ///       (mixed core commits in the current run; unreadable/undecodable
  ///       input or baseline file)
  ///   2 = usage error (bad flags, missing required args, no baseline file to
  ///       compare against when not --update)
  ///   5 = rot-guard tripped (stale baseline or a shrunk cell manifest) — takes
  ///       priority over a plain movement exit so CI can't miss it under a
  ///       generic "1"
  static func run(
    _ args: [String],
    die: (String, Int32) -> Never,
    warn: (String) -> Void
  ) {
    var files: [URL] = []
    var baselinePathString: String?
    var update = false
    var scoreThreshold = 0.05
    var maxAgeHours = 168.0  // 7 days — the loop's documented weekly cadence
    var outPath: String?

    var index = 0
    while index < args.count {
      let token = args[index]
      switch token {
      case "--baseline-path":
        index += 1
        guard index < args.count else { die("--baseline-path requires a path", 2) }
        baselinePathString = args[index]
      case "--update":
        update = true
      case "--score-threshold":
        index += 1
        guard index < args.count, let d = Double(args[index]) else {
          die("--score-threshold requires a number", 2)
        }
        scoreThreshold = d
      case "--max-age-hours":
        index += 1
        guard index < args.count, let d = Double(args[index]) else {
          die("--max-age-hours requires a number", 2)
        }
        maxAgeHours = d
      case "--out":
        index += 1
        guard index < args.count else { die("--out requires a path", 2) }
        outPath = args[index]
      default:
        if token.hasPrefix("--") {
          die("unknown flag '\(token)'", 2)
        }
        files.append(URL(fileURLWithPath: token))
      }
      index += 1
    }

    guard !files.isEmpty else { die("baseline requires at least one record file", 2) }
    guard let baselinePathString else { die("baseline requires --baseline-path <path>", 2) }
    let baselinePath = URL(fileURLWithPath: baselinePathString)

    let collated: CollationResult
    do {
      collated = try Collator.collate(files: files)
    } catch {
      die("\(error)", 1)
    }
    for diagnostic in collated.diagnostics {
      warn("[\(diagnostic.severity.rawValue)] \(diagnostic.message)")
    }
    guard !collated.hasErrors else { die("collation produced an error-severity diagnostic", 1) }

    let manifest: RunManifest
    do {
      manifest = try BaselineCollector.build(from: collated.records)
    } catch {
      die("\(error)", 1)
    }

    let existingBaseline: BaselineStore
    do {
      existingBaseline = try BaselineStore.load(path: baselinePath)
    } catch {
      die("\(error)", 1)
    }

    if update {
      let updated = existingBaseline.updated(with: manifest.observations, timestamp: Date())
      do {
        try updated.save(path: baselinePath)
      } catch {
        die("\(error)", 1)
      }
      warn("wrote \(manifest.observations.count) cell(s) to \(baselinePath.path)")
      exit(0)
    }

    // --- Compare mode ---
    guard
      !existingBaseline.rows.isEmpty || FileManager.default.fileExists(atPath: baselinePath.path)
    else {
      die("no baseline found at \(baselinePath.path) — run with --update first", 2)
    }

    let changes = BaselineRotGuard.detectMovements(
      current: manifest.observations, baseline: existingBaseline, scoreThreshold: scoreThreshold
    )
    let rotVerdict = BaselineRotGuard.evaluate(
      manifestKeys: manifest.manifestKeys,
      baseline: existingBaseline,
      maxAge: maxAgeHours * 3600,
      now: Date()
    )

    let report = renderReport(changes: changes, rotVerdict: rotVerdict)
    if let outPath {
      do {
        try report.write(toFile: outPath, atomically: true, encoding: .utf8)
      } catch {
        die("writing \(outPath): \(error)", 1)
      }
      warn("wrote \(outPath)")
    } else {
      print(report)
    }

    if rotVerdict.tripped {
      exit(5)
    } else if !changes.isEmpty {
      exit(1)
    } else {
      exit(0)
    }
  }

  // MARK: - Report rendering

  private static func renderReport(changes: [CellChange], rotVerdict: RotGuardVerdict) -> String {
    var lines: [String] = ["# Baseline movement report", ""]

    if rotVerdict.tripped {
      lines.append("## Rot-guard: TRIPPED")
      lines.append("")
      if rotVerdict.isStale {
        let newest =
          rotVerdict.newestBaselineTimestamp.map { ISO8601DateFormatter().string(from: $0) }
          ?? "n/a"
        lines.append(
          "- baseline is stale: newest row is \(newest), max age is \(Int(rotVerdict.maxAge / 3600))h"
        )
      }
      if !rotVerdict.shrunkCells.isEmpty {
        lines.append(
          "- cell manifest shrank — \(rotVerdict.shrunkCells.count) cell(s) present in the baseline are absent from this run's manifest entirely:"
        )
        for key in rotVerdict.shrunkCells {
          lines.append("  - \(key.model) / \(key.quant) / \(key.backend) / \(key.renderer)")
        }
      }
      lines.append("")
    } else {
      lines.append("## Rot-guard: clear")
      lines.append("")
    }

    if changes.isEmpty {
      lines.append("No cell movement detected.")
    } else {
      lines.append("## Movements (\(changes.count) cell(s))")
      lines.append("")
      for change in changes {
        lines.append(
          "- **\(change.key.model) / \(change.key.quant) / \(change.key.backend) / \(change.key.renderer)**"
        )
        for movement in change.movements {
          lines.append("  - \(describe(movement))")
        }
      }
    }

    return lines.joined(separator: "\n")
  }

  private static func describe(_ movement: CellMovementKind) -> String {
    switch movement {
    case .scoreChanged(let previous, let current, let delta):
      return String(format: "score %.3f → %.3f (Δ%+.3f)", previous, current, delta)
    case .divergenceClassFlipped(let previous, let current):
      return "divergenceClass \(previous ?? "nil") → \(current ?? "nil")"
    case .bytesHashChanged(let previous, let current):
      return "bytesHash \(previous.prefix(12)) → \(current.prefix(12))"
    case .newCell(let current):
      return String(format: "new cell — score %.3f", current)
    }
  }
}
