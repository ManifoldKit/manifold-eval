import Foundation
import ManifoldEval

/// The `dismiss` and `dismissals` subcommands: record and inspect confirmed
/// by-design divergence dismissals.
///
/// Usage:
///
///     manifold-eval dismiss --cell <id> --signature <hex> --reason <text> --ttl <seconds>
///                            [--ledger <path>]
///     manifold-eval dismissals [--ledger <path>] [--prune]
///
/// `--cell`      Caller-defined stable cell identity (e.g. `"model|quant|backend|renderer"`).
/// `--signature` Divergence signature — see `DivergenceSignature.compute`.
/// `--reason`    Free-text human justification (required — an audit trail, not a bare suppression).
/// `--ttl`       Re-check expiry in seconds from now.
/// `--ledger`    Path to the ledger JSON file (default: `.manifold-eval-dismissals.json` in the CWD).
/// `--prune`     (dismissals only) Remove expired entries before listing, and persist the pruned ledger.
enum DismissalsCommand {

  static let defaultLedgerPath = ".manifold-eval-dismissals.json"

  static func runDismiss(
    _ args: [String],
    die: (String, Int32) -> Never,
    warn: (String) -> Void
  ) {
    var cell: String?
    var signature: String?
    var reason: String?
    var ttl: TimeInterval?
    var ledgerPath = defaultLedgerPath

    func value(_ index: inout Int, _ flag: String) -> String {
      index += 1
      guard index < args.count else { die("\(flag) requires a value", 2) }
      return args[index]
    }

    var index = 0
    while index < args.count {
      let token = args[index]
      switch token {
      case "--cell": cell = value(&index, token)
      case "--signature": signature = value(&index, token)
      case "--reason": reason = value(&index, token)
      case "--ttl":
        let raw = value(&index, token)
        guard let parsed = TimeInterval(raw), parsed > 0 else {
          die("--ttl requires a positive number of seconds, got '\(raw)'", 2)
        }
        ttl = parsed
      case "--ledger": ledgerPath = value(&index, token)
      default:
        if token.hasPrefix("--") { die("unknown flag '\(token)'", 2) }
        die("unexpected argument '\(token)' — expected a flag", 2)
      }
      index += 1
    }

    guard let cell else { die("dismiss requires --cell <id>", 2) }
    guard let signature else { die("dismiss requires --signature <hex>", 2) }
    guard let reason, !reason.isEmpty else {
      die("dismiss requires --reason <text> — a dismissal must always carry an audit trail", 2)
    }
    guard let ttl else { die("dismiss requires --ttl <seconds>", 2) }

    let url = URL(fileURLWithPath: ledgerPath)
    var ledger: DismissalsLedger
    do {
      ledger = try DismissalsLedger.load(from: url)
    } catch {
      die("\(error)", 1)
    }

    let now = Date()
    let finding = DismissedFinding(cell: cell, signature: signature)
    ledger.record(finding, reason: reason, recordedAt: now, ttl: ttl)

    do {
      try ledger.save(to: url)
    } catch {
      die("\(error)", 1)
    }

    let expiresAt = now.addingTimeInterval(ttl)
    print(
      "dismissed cell='\(cell)' signature='\(signature)' until \(ISO8601DateFormatter().string(from: expiresAt))"
    )
  }

  static func runDismissals(
    _ args: [String],
    die: (String, Int32) -> Never,
    warn: (String) -> Void
  ) {
    var ledgerPath = defaultLedgerPath
    var prune = false

    var index = 0
    while index < args.count {
      let token = args[index]
      switch token {
      case "--ledger":
        index += 1
        guard index < args.count else { die("--ledger requires a value", 2) }
        ledgerPath = args[index]
      case "--prune":
        prune = true
      default:
        die("unknown flag '\(token)'", 2)
      }
      index += 1
    }

    let url = URL(fileURLWithPath: ledgerPath)
    var ledger: DismissalsLedger
    do {
      ledger = try DismissalsLedger.load(from: url)
    } catch {
      die("\(error)", 1)
    }

    let now = Date()

    if prune {
      let removed = ledger.prune(asOf: now)
      do {
        try ledger.save(to: url)
      } catch {
        die("\(error)", 1)
      }
      for entry in removed {
        warn(
          "pruned cell='\(entry.finding.cell)' signature='\(entry.finding.signature)' (expired \(ISO8601DateFormatter().string(from: entry.expiresAt)))"
        )
      }
      print(
        "pruned \(removed.count) expired entr\(removed.count == 1 ? "y" : "ies"); \(ledger.count) remaining"
      )
      return
    }

    guard ledger.count > 0 else {
      print("no dismissals recorded in \(ledgerPath)")
      return
    }

    for entry in ledger.entries {
      let status = entry.isLive(asOf: now) ? "live" : "EXPIRED"
      print(
        "[\(status)] cell='\(entry.finding.cell)' signature='\(entry.finding.signature)' "
          + "reason='\(entry.reason)' expiresAt=\(ISO8601DateFormatter().string(from: entry.expiresAt))"
      )
    }
  }
}
