import XCTest

/// Guards `docs/AUTOMATION-STATUS.md` against the workflow files it describes.
///
/// WHY THIS EXISTS: four separate hand-written status claims (README's roadmap,
/// `AGENTS.md`, `docs/EVAL-IMPROVEMENT-LOOP.md`, and `core-bump.yml`'s own header
/// comment) had drifted out of sync with reality and with each other — two of them
/// asserted the *opposite* of what the run history showed, and one survived an
/// earlier correction because it was bundled into a sentence whose other half was
/// still true. Prose status claims have no owner and no expiry, so they rot in
/// silence.
///
/// This is the repo's own thesis turned on itself: a claim about behavior is
/// *irreducibly empirical* and must be **measured, not declared** (ORIGINS #1,
/// "assess, don't declare"). Everything derivable from the workflow files is
/// derived here and diffed against what the doc asserts. What is *not* derivable
/// — PAT liveness, upstream reusable-workflow behavior, human cadence commitments
/// — deliberately stays out of this test and is recorded in the doc as a dated
/// observation instead, so its age is visible rather than implied.
///
/// Hermetic: reads files from the source tree only. No network, no `gh`, no
/// models — safe for hosted CI and the weekly rot-guard.
final class AutomationClaimsTests: XCTestCase {

  // MARK: - Repo layout

  /// Repo root, walked up from this file: `Tests/ManifoldEvalTests/<self>.swift`.
  private func repoRoot() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()  // ManifoldEvalTests
      .deletingLastPathComponent()  // Tests
      .deletingLastPathComponent()  // <repo root>
    // Guard against a future layout change silently turning every assertion
    // below into a vacuous pass.
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("Package.swift").path)
    else {
      throw XCTSkip(
        "Could not locate repo root from #filePath (\(root.path)) — source tree unavailable")
    }
    return root
  }

  private func read(_ relativePath: String) throws -> String {
    let url = try repoRoot().appendingPathComponent(relativePath)
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      XCTFail("Expected file missing: \(relativePath)")
      return ""
    }
    return text
  }

  private func statusDoc() throws -> String { try read("docs/AUTOMATION-STATUS.md") }

  // MARK: - Derivations from the workflow files

  /// The cron expression from `rot-guard.yml`'s `schedule:` trigger.
  private func rotGuardCron() throws -> String {
    let yaml = try read(".github/workflows/rot-guard.yml")
    guard let cron = firstCapture(in: yaml, pattern: #"-\s*cron:\s*"([^"]+)""#) else {
      XCTFail(
        "rot-guard.yml has no `- cron: \"...\"` line — it is no longer scheduled. "
          + "If that is intentional, update docs/AUTOMATION-STATUS.md and this test.")
      return ""
    }
    return cron
  }

  /// The conventional-commit type `core-bump.yml` uses for its bump commit.
  private func coreBumpCommitType() throws -> String {
    let yaml = try read(".github/workflows/core-bump.yml")
    guard let type = firstCapture(in: yaml, pattern: #"git commit -m "([a-z]+):"#) else {
      XCTFail("core-bump.yml has no `git commit -m \"<type>: ...\"` line to derive from")
      return ""
    }
    return type
  }

  /// Every GitHub trigger this test knows how to see. A workflow using one
  /// outside this set would be invisible to the comparison below, so the list
  /// is asserted against the workflow files rather than trusted — see
  /// `testTriggerVocabularyCoversEveryWorkflow`.
  private static let knownTriggers: Set<String> = [
    "push", "pull_request", "schedule", "workflow_dispatch", "repository_dispatch",
  ]

  /// Every workflow whose status this repo documents.
  private static let workflowFiles = [
    "ci.yml", "rot-guard.yml", "core-bump.yml", "release-please.yml",
  ]

  /// Top-level trigger keys present in a workflow's `on:` block.
  private func triggers(inWorkflow file: String) throws -> Set<String> {
    let yaml = try read(".github/workflows/\(file)")
    // Top-level `on:` keys sit at exactly two spaces of indentation.
    return Set(Self.knownTriggers.filter { yaml.contains("\n  \($0):") })
  }

  /// Every key actually declared in a workflow's `on:` block, whether or not
  /// this test knows what it means.
  private func declaredTriggerKeys(inWorkflow file: String) throws -> Set<String> {
    let lines = try read(".github/workflows/\(file)").split(
      separator: "\n", omittingEmptySubsequences: false)
    guard let onIndex = lines.firstIndex(where: { $0 == "on:" }) else {
      XCTFail("\(file) has no top-level `on:` block — parser assumption broken")
      return []
    }

    var keys: Set<String> = []
    for line in lines[(onIndex + 1)...] {
      if line.isEmpty { continue }
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("#") { continue }
      // A line starting at column 0 ends the `on:` block.
      if !line.hasPrefix(" ") { break }
      // Only the block's own keys — two spaces, then `name:`.
      guard line.hasPrefix("  "), !line.hasPrefix("   "),
        let colon = trimmed.firstIndex(of: ":"), !trimmed.hasPrefix("-")
      else { continue }
      keys.insert(String(trimmed[trimmed.startIndex..<colon]))
    }
    return keys
  }

  // MARK: - The guarded claims

  func testStatusDocStatesRotGuardsActualCron() throws {
    let cron = try rotGuardCron()
    XCTAssertFalse(cron.isEmpty)
    XCTAssertTrue(
      try statusDoc().contains(cron),
      """
      rot-guard.yml is scheduled at "\(cron)" but docs/AUTOMATION-STATUS.md does not mention \
      that cron expression. Update the derived-facts table to match the workflow.
      """
    )
  }

  func testStatusDocStatesCoreBumpsActualCommitType() throws {
    let type = try coreBumpCommitType()
    XCTAssertFalse(type.isEmpty)
    // Anchored to the exact sentence, not a bare "`\(type):`" substring: the
    // doc legitimately mentions `feat:` / `fix:` elsewhere (describing what
    // *does* cut a release), so a loose `contains` passed vacuously when this
    // mutation was tried — the assertion was green for a workflow committing
    // `fix:`. Mutation-tested; keep it anchored.
    XCTAssertTrue(
      try statusDoc().contains("Core-bump commits `\(type):`"),
      """
      core-bump.yml commits "\(type):" but docs/AUTOMATION-STATUS.md does not say \
      "Core-bump commits `\(type):`". This exact claim was wrong in AGENTS.md for weeks \
      (it said `fix:` after the workflow had moved to `chore:`), which is why it is guarded.
      """
    )
  }

  /// A trigger this test doesn't recognise would be invisible to the comparison
  /// in `testStatusDocListsActualTriggers` — the doc could omit it and stay
  /// green. So the vocabulary is itself checked against the workflows.
  func testTriggerVocabularyCoversEveryWorkflow() throws {
    for file in Self.workflowFiles {
      let declared = try declaredTriggerKeys(inWorkflow: file)
      XCTAssertFalse(
        declared.isEmpty, "No `on:` keys parsed from \(file) — parser assumption broken")
      let unknown = declared.subtracting(Self.knownTriggers)
      XCTAssertTrue(
        unknown.isEmpty,
        """
        \(file) declares trigger(s) \(unknown.sorted()) that AutomationClaimsTests does not \
        know about, so they are not guarded. Add them to `knownTriggers` and to the \
        AUTOMATION-STATUS row for \(file).
        """
      )
    }
  }

  /// Each workflow's real trigger set must appear in the doc's row for it.
  func testStatusDocListsActualTriggers() throws {
    let doc = try statusDoc()
    for file in Self.workflowFiles {
      let actual = try triggers(inWorkflow: file)
      XCTAssertFalse(actual.isEmpty, "No triggers derived from \(file) — parser or file changed")

      guard let row = doc.split(separator: "\n").first(where: { $0.contains("`\(file)`") }) else {
        XCTFail("docs/AUTOMATION-STATUS.md has no derived-facts row for `\(file)`")
        continue
      }
      // Set *equality*, deliberately, in both directions. Asserting only
      // `actual ⊆ documented` would let a workflow quietly lose a trigger
      // while the doc kept advertising it — which is precisely the drift
      // class this test exists to catch (a doc claiming something untrue),
      // just pointing the other way.
      let documented = Self.knownTriggers.filter { row.contains($0) }

      XCTAssertEqual(
        documented, actual,
        """
        \(file)'s triggers and its AUTOMATION-STATUS row disagree.
          in the workflow, not the doc: \(actual.subtracting(documented).sorted())
          in the doc, not the workflow: \(documented.subtracting(actual).sorted())
          row: \(row)
        """
      )
    }
  }

  /// `pull_request` must never carry a path filter.
  ///
  /// `build-test / build-and-test` is a **required** check on main. A workflow
  /// skipped by path filtering does not report a required check as passing — it
  /// never reports at all, so the check stays pending and the PR is blocked
  /// permanently. (A job skipped by an `if:` expression *does* satisfy a
  /// required check, but that escape hatch is unavailable here: the context
  /// comes from a reusable workflow, so skipping the caller job means the
  /// nested `build-and-test` never exists and the context is never produced.)
  ///
  /// Not hypothetical: release-please PRs touch exactly the filtered files, so
  /// 0.1.1, 0.1.2 and 0.1.3 all merged with zero checks via admin bypass, and
  /// 0.1.4 (#54) is open and BLOCKED. Filtering on `push` is fine and stays; a
  /// changelog/manifest-only merge cannot break the build.
  ///
  /// This guard asserts the filter is absent — it does NOT assert that CI
  /// actually runs on release PRs, which depends on run creation for a
  /// bot-authored PR and is unverified. See `docs/AUTOMATION-STATUS.md`.
  func testPullRequestTriggerHasNoPathFilter() throws {
    let yaml = try read(".github/workflows/ci.yml")
    guard let block = triggerBlock("pull_request", in: yaml) else {
      XCTFail("ci.yml has no `pull_request:` trigger block to inspect")
      return
    }
    XCTAssertFalse(
      block.contains("paths-ignore") || block.contains("paths:"),
      """
      ci.yml's `pull_request:` trigger has a path filter. That makes any PR touching only \
      filtered files — every release-please PR — permanently BLOCKED, because a workflow \
      skipped by path filtering never reports the required `build-test / build-and-test` \
      check. Filter on `push` instead, where nothing depends on the check reporting.
        pull_request block:
      \(block)
      """
    )
  }

  /// The body of one top-level trigger inside a workflow's `on:` block: every
  /// line from `  <name>:` up to the next sibling key.
  ///
  /// Comments and blank lines are *skipped, not terminators*. An earlier
  /// version broke at the first line lacking a three-space indent, which meant
  /// a column-0 comment — the house style everywhere else in `ci.yml` — silently
  /// truncated the block and let a live `paths-ignore` below it go unseen. Three
  /// shapes passed green with the filter active (column-0 comment, two-space
  /// comment, whitespace-only line). Re-adding the filter in the file's own
  /// style would have defeated the guard entirely.
  private func triggerBlock(_ name: String, in yaml: String) -> String? {
    let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false)
    guard let start = lines.firstIndex(of: Substring("  \(name):")) else { return nil }
    var body: [String] = []
    for line in lines[(start + 1)...] {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // Blank or comment: skip entirely — neither a block boundary nor
      // content. Treating them as boundaries was the original hole (a
      // column-0 comment truncated the block); *including* them would swap
      // it for a false alarm, since a comment merely mentioning
      // `paths-ignore` would trip the caller's substring check.
      if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
      // Known limit: a TAB-indented child reads as indent 0 and ends the
      // block early. Not worth handling — YAML forbids tab indentation, so
      // such a file is an invalid workflow that never runs, the required
      // check never reports, and the PR blocks. Fail-loud one layer down.
      // A real key at this trigger's own indentation (or shallower) is the
      // next sibling, so the block ends here.
      let indent = line.prefix(while: { $0 == " " }).count
      if indent <= 2 { break }
      body.append(String(line))
    }
    return body.joined(separator: "\n")
  }

  // MARK: - The single-source-of-truth convention

  /// The docs that used to carry their own status prose must now link here.
  func testStatusClaimantsLinkToTheCanonicalDoc() throws {
    for path in ["README.md", "AGENTS.md", "docs/EVAL-IMPROVEMENT-LOOP.md"] {
      XCTAssertTrue(
        try read(path).contains("AUTOMATION-STATUS.md"),
        "\(path) should link to docs/AUTOMATION-STATUS.md rather than restating automation status"
      )
    }
  }

  /// Nothing outside the canonical doc may hard-code a schedule. Restating a
  /// cadence is exactly how the four claims drifted apart in the first place.
  func testNoOtherDocHardCodesACronExpression() throws {
    for path in ["README.md", "AGENTS.md", "docs/EVAL-IMPROVEMENT-LOOP.md", "docs/CONCEPTS.md"] {
      let text = try read(path)
      XCTAssertNil(
        firstCapture(in: text, pattern: #"([0-9*]+ [0-9*]+ \* \* [0-9*]+)"#),
        """
        \(path) hard-codes a cron expression. Schedules belong only in \
        docs/AUTOMATION-STATUS.md — link to it instead.
        """
      )
    }
  }

  // MARK: - Helpers

  private func firstCapture(in text: String, pattern: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
      match.numberOfRanges > 1,
      let range = Range(match.range(at: 1), in: text)
    else { return nil }
    return String(text[range])
  }
}
