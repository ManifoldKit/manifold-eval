import Foundation
import XCTest

/// Exercises the shipping Bash helper with real immutable Git objects and a local gh fake.
/// No command in this suite contacts GitHub or mutates the source checkout.
final class ReleaseNotesSyncTests: XCTestCase {
  private var root: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
  }

  private let notes = "## [1.2.3](https://example.test/compare/v1.2.2...v1.2.3) (2026-10-18)\n\n### Fixes\n\n* Preserve **curated** notes.\n"

  private struct Result {
    let status: Int32
    let output: String
  }

  private func run(_ executable: String, _ arguments: [String], in directory: URL,
                   environment: [String: String] = [:]) throws -> Result {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = directory
    var env = ProcessInfo.processInfo.environment
    env.merge(environment) { _, new in new }
    // Fixture commits must never inherit signing, hooks, or an operator's Git directory.
    for key in Array(env.keys) where key.hasPrefix("GIT_") {
      env.removeValue(forKey: key)
    }
    env["GIT_CONFIG_NOSYSTEM"] = "1"
    env["GIT_CONFIG_GLOBAL"] = "/dev/null"
    process.environment = env
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let deadline = Date().addingTimeInterval(10)
    while process.isRunning && Date() < deadline {
      Thread.sleep(forTimeInterval: 0.01)
    }
    if process.isRunning {
      process.terminate()
      throw NSError(domain: "ReleaseNotesSyncTests", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Subprocess exceeded 10 seconds: \(arguments)"])
    }
    process.waitUntilExit()
    return Result(status: process.terminationStatus,
                  output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
  }

  private final class Fixture {
    let directory: URL
    let sha: String
    let environment: [String: String]
    let script: String
    let runner: (String, [String], URL, [String: String]) throws -> Result

    init(directory: URL, sha: String, environment: [String: String], script: String,
         runner: @escaping (String, [String], URL, [String: String]) throws -> Result) {
      self.directory = directory
      self.sha = sha
      self.environment = environment
      self.script = script
      self.runner = runner
    }

    deinit {
      do { try FileManager.default.removeItem(at: directory) }
      catch { XCTFail("Failed to remove test fixture \(directory.path): \(error)") }
    }

    func invoke(_ extra: [String] = [], overrides: [String: String] = [:],
                arguments: [String]? = nil) throws -> Result {
      var env = environment
      env.merge(overrides) { _, new in new }
      return try runner("/bin/bash", [script] + (arguments ?? [
        "--repo", "ManifoldKit/manifold-eval", "--tag", "v1.2.3", "--sha", sha
      ]) + extra, directory, env)
    }

    func text(_ name: String) throws -> String {
      try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
    }
  }

  private func fixture(changelog: String? = nil, body: String = "Generated notes\n") throws -> Fixture {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("release-notes-sync-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    func write(_ name: String, _ text: String) throws {
      try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }
    try write("CHANGELOG.md", changelog ?? "# Changelog\n\n\(notes)\n## [1.2.2] (2026-10-17)\n\nOlder notes must stay out.\n")
    for args in [
      ["init", "--quiet"], ["config", "user.name", "Release Notes Fixture"],
      ["config", "user.email", "fixture@example.test"], ["config", "commit.gpgsign", "false"],
      ["config", "core.hooksPath", "/dev/null"], ["add", "CHANGELOG.md"],
      ["commit", "--quiet", "-m", "test: immutable release fixture"]
    ] {
      let result = try run("/usr/bin/git", args, in: directory)
      guard result.status == 0 else { throw NSError(domain: "FixtureGit", code: Int(result.status), userInfo: [NSLocalizedDescriptionKey: result.output]) }
    }
    let revision = try run("/usr/bin/git", ["rev-parse", "HEAD"], in: directory)
    let sha = revision.output.trimmingCharacters(in: .whitespacesAndNewlines)
    try write("body", body)
    try write("calls", "")
    try write("writes", "")
    let fake = try String(contentsOf: root.appendingPathComponent("Tests/ManifoldEvalTests/Fixtures/ReleaseNotesSync/gh"), encoding: .utf8)
    try write("gh", fake)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.appendingPathComponent("gh").path)
    return Fixture(directory: directory, sha: sha, environment: [
      "PATH": directory.path + ":/usr/bin:/bin", "FIXTURE_DIR": directory.path,
      "FIXTURE_SHA": sha, "GH_TOKEN": "fixture-only"
    ], script: root.appendingPathComponent("scripts/sync-release-notes.sh").path,
      runner: { executable, args, dir, env in try self.run(executable, args, in: dir, environment: env) })
  }

  private func assertFailure(_ result: Result, _ fixture: Fixture,
                             file: StaticString = #filePath, line: UInt = #line) throws {
    XCTAssertNotEqual(result.status, 0, result.output, file: file, line: line)
    XCTAssertEqual(try fixture.text("writes"), "", "Validation must precede writes", file: file, line: line)
  }

  func testFixtureRunnerCannotRedirectGitWritesToAnotherRepository() throws {
    let local = try fixture()
    let foreign = try fixture()
    let foreignConfig = try foreign.text(".git/config")
    let foreignRefs = try run("/usr/bin/git", ["show-ref", "--head"], in: foreign.directory)
    XCTAssertEqual(foreignRefs.status, 0, foreignRefs.output)
    let overrides = [
      "GIT_COMMON_DIR": foreign.directory.appendingPathComponent(".git").path,
      "GIT_DIR": foreign.directory.appendingPathComponent(".git").path,
      "GIT_WORK_TREE": foreign.directory.path,
      "GIT_INDEX_FILE": foreign.directory.appendingPathComponent(".git/index").path,
      "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "fixture.injected",
      "GIT_CONFIG_VALUE_0": "foreign", "GIT_CONFIG_PARAMETERS": "invalid inherited config"
    ]
    // The first case isolates the exact GIT_COMMON_DIR regression; the second
    // also proves config injection and alternate index/worktree settings are purged.
    for (index, environment) in [["GIT_COMMON_DIR": foreign.directory.appendingPathComponent(".git").path], overrides].enumerated() {
      let value = "local-\(index)"
      let write = try run("/usr/bin/git", ["config", "--local", "fixture.isolated", value],
                          in: local.directory, environment: environment)
      XCTAssertEqual(write.status, 0, write.output)
      let read = try run("/usr/bin/git", ["config", "--local", "--get", "fixture.isolated"],
                         in: local.directory)
      XCTAssertEqual(read.status, 0, read.output)
      XCTAssertEqual(read.output, value + "\n")
      XCTAssertEqual(try foreign.text(".git/config"), foreignConfig)
      let afterRefs = try run("/usr/bin/git", ["show-ref", "--head"], in: foreign.directory)
      XCTAssertEqual(afterRefs.status, 0, afterRefs.output)
      XCTAssertEqual(afterRefs.output, foreignRefs.output)
    }
  }

  func testPublishesExactSectionFromImmutableCommitAndVerifiesReadback() throws {
    let f = try fixture()
    try "# Dirty working copy\n\n## [1.2.3]\n\nWrong mutable notes\n".write(
      to: f.directory.appendingPathComponent("CHANGELOG.md"), atomically: true, encoding: .utf8)
    let result = try f.invoke()
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertEqual(try f.text("body"), notes)
    XCTAssertEqual(try f.text("writes"), "edit\n")
    XCTAssertEqual(try f.text("calls").components(separatedBy: "--json body").count - 1, 2)
    XCTAssertTrue(try f.text("calls").contains("--notes-file"))
  }

  func testAlreadyMatchingAndCheckModeNeverWrite() throws {
    for extra in [[], ["--check"]] {
      let f = try fixture(body: notes)
      let result = try f.invoke(extra)
      XCTAssertEqual(result.status, 0, result.output)
      XCTAssertEqual(try f.text("writes"), "")
    }
    let mismatch = try fixture()
    try assertFailure(mismatch.invoke(["--check"]), mismatch)
  }

  func testMissingEmptyAndDuplicateSectionsFailBeforeWriting() throws {
    for changelog in [
      "# Changelog\n## [1.2.30]\n\nNeighbor only\n",
      "## [1.2.3]\n\n  \n## [1.2.2]\n\nEarlier\n",
      notes + "\n## [1.2.3]\n\nDuplicate\n"
    ] {
      let f = try fixture(changelog: changelog)
      try assertFailure(f.invoke(), f)
    }
  }

  func testFencedHeadingsDoNotStartOrEndReleaseSections() throws {
    for marker in ["```", "~~~", "````"] {
      let nestedFence = marker == "````" ? "```\n## [1.2.3]\nStill in the outer fence\n```\n" : ""
      let expected = notes + "\n\(marker)markdown\n## [1.2.3]\nExample heading\n" + nestedFence + "## [1.2.2]\n\(marker)\n"
      let changelog = "# Changelog\n\(marker)\n## [1.2.3]\nBogus\n\(marker)\n\n"
        + expected + "\n## [1.2.2]\n\nEarlier\n"
      let f = try fixture(changelog: changelog)
      let result = try f.invoke()
      XCTAssertEqual(result.status, 0, result.output)
      XCTAssertEqual(try f.text("body"), expected)
    }
  }

  func testPrefixNeighborsAreExcluded() throws {
    let f = try fixture(changelog: "## [1.2.30]\n\nNewer neighbor\n\n" + notes
      + "\n## [1.2.3-rc.1]\n\nPrerelease neighbor\n")
    let result = try f.invoke()
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertEqual(try f.text("body"), notes)
  }

  func testInvalidArgumentsFailWithoutCallingGitHub() throws {
    let f = try fixture()
    let valid = ["--repo", "ManifoldKit/manifold-eval", "--tag", "v1.2.3", "--sha", f.sha]
    let cases = [[], ["--repo"], valid + ["--unknown"],
      ["--repo", "bad/repo/extra", "--tag", "v1.2.3", "--sha", f.sha],
      ["--repo", "owner/repo", "--tag", "1.2.3", "--sha", f.sha],
      ["--repo", "owner/repo", "--tag", "v1.2", "--sha", f.sha],
      ["--repo", "owner/repo", "--tag", "v1.2.3", "--sha", "abcdef"]]
    for args in cases { try assertFailure(f.invoke(arguments: args), f) }
    XCTAssertEqual(try f.text("calls"), "")
  }

  func testTagResolutionRequiresExactCommitAndSupportsAnnotatedTags() throws {
    let f = try fixture()
    try assertFailure(f.invoke(overrides: ["TAG_SHA": String(repeating: "a", count: 40)]), f)
    try assertFailure(f.invoke(overrides: ["TAG_TYPE": "tree"]), f)
    try assertFailure(f.invoke(overrides: ["TAG_SHA": "invalid"]), f)
    try assertFailure(f.invoke(overrides: ["ANNOTATED": "cycle"]), f)
    let annotated = try fixture()
    let result = try annotated.invoke(overrides: ["ANNOTATED": "yes"])
    XCTAssertEqual(result.status, 0, result.output)
    XCTAssertTrue(try annotated.text("calls").contains("/git/tags/"))
  }

  func testMissingImmutableChangelogFailsBeforeWriting() throws {
    let f = try fixture()
    try assertFailure(f.invoke(overrides: ["TAG_SHA": String(repeating: "b", count: 40)], arguments: ["--repo", "owner/repo", "--tag", "v1.2.3",
      "--sha", String(repeating: "b", count: 40)]), f)
  }

  func testApiReadFailuresAndInvalidReleaseMetadataFailClosed() throws {
    for overrides in [["FAIL_API": "1"], ["FAIL_METADATA": "1"], ["FAIL_BODY": "1"],
      ["RELEASE_METADATA": "v1.2.3 true"], ["RELEASE_METADATA": "v9.9.9 false"]] {
      let f = try fixture()
      try assertFailure(f.invoke(overrides: overrides), f)
    }
  }

  func testUpdateFailureNoopPartialAndFailedReadbackCannotReportSuccess() throws {
    for mode in ["fail", "noop", "partial", "readback-fail"] {
      let f = try fixture()
      let result = try f.invoke(overrides: ["UPDATE_MODE": mode])
      XCTAssertNotEqual(result.status, 0, "\(mode): \(result.output)")
      XCTAssertEqual(try f.text("writes"), "edit\n")
      XCTAssertFalse(result.output.contains("Verified "))
    }
  }

  func testWorkflowWiresCreatedReleaseToImmutableCheckoutAndBlockingSync() throws {
    let yaml = try String(contentsOf: root.appendingPathComponent(".github/workflows/release-please.yml"), encoding: .utf8)
    XCTAssertEqual(workflowIssues(yaml), [])
    let inert = try String(contentsOf: root.appendingPathComponent("Tests/ManifoldEvalTests/Fixtures/ReleaseNotesSync/inert-workflow.yml"), encoding: .utf8)
    XCTAssertFalse(workflowIssues(inert).isEmpty, "The original inert reusable workflow must fail this guard")
    // Sabotage the same production text: each failure mode must remain observable.
    for pair in [
      ("release_created: ${{ steps.release-please.outputs.release_created }}", "release_created: false"),
      ("uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7", "run: echo disabled"),
      ("id: release-please", "id: wrong-step"),
      ("config-file: release-please-config.json", "config-file: missing.json"),
      ("if: ${{ needs.release-please.outputs.release_created == 'true' }}", "if: false"),
      ("ref: ${{ needs.release-please.outputs.sha }}", "ref: main"),
      ("run: bash scripts/sync-release-notes.sh", "run: echo disabled"),
      ("      contents: write", "      contents: read")
    ] {
      XCTAssertTrue(yaml.contains(pair.0), "Sabotage anchor missing: \(pair.0)")
      XCTAssertFalse(workflowIssues(yaml.replacingOccurrences(of: pair.0, with: pair.1)).isEmpty,
                     "Guard failed to catch sabotage: \(pair.0)")
    }
    // Mutate each job independently: a sync-only check cannot see publication
    // cancelled before release-please exports the values that start the sync.
    let jobs = yaml.components(separatedBy: "\n  sync-release-notes:\n")
    XCTAssertEqual(jobs.count, 2, "Expected separate detector and sync jobs")
    if jobs.count == 2 {
      for index in [0, 1] {
        XCTAssertTrue(jobs[index].contains("cancel-in-progress: false"))
        var changed = jobs
        changed[index] = changed[index].replacingOccurrences(
          of: "cancel-in-progress: false", with: "cancel-in-progress: true")
        let expectedIssue = index == 0 ? "detector may be cancelled" : "sync may be cancelled"
        XCTAssertTrue(workflowIssues(changed.joined(separator: "\n  sync-release-notes:\n")).contains(expectedIssue),
                      "Guard failed to catch cancellation in job \(index)")
      }
    }
    XCTAssertFalse(workflowIssues(yaml + "\n    continue-on-error: true\n").isEmpty)
    XCTAssertFalse(workflowIssues(yaml + "\n        if: false\n").isEmpty)
    XCTAssertFalse(workflowIssues(yaml.replacingOccurrences(of: "--sha \"$RELEASE_SHA\"", with: "--sha \"$RELEASE_SHA\" --check")).isEmpty)
  }

  private func workflowIssues(_ yaml: String) -> [String] {
    let live = yaml.split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }.joined(separator: "\n")
    var issues: [String] = []
    for required in [
      "uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7",
      "id: release-please", "config-file: release-please-config.json",
      "manifest-file: .release-please-manifest.json"
    ] {
      if !live.contains(required) { issues.append("missing detector \(required)") }
    }
    for output in ["release_created", "tag_name", "sha"] {
      if !live.contains("\(output): ${{ steps.release-please.outputs.\(output) }}") { issues.append("missing \(output) output") }
    }
    guard let range = live.range(of: "\n  sync-release-notes:\n") else { return issues + ["missing sync job"] }
    let detector = String(live[..<range.lowerBound])
    if !detector.contains("concurrency:\n      group: release-please\n      cancel-in-progress: false")
      || detector.contains("cancel-in-progress: true") {
      issues.append("detector may be cancelled")
    }
    let sync = String(live[range.upperBound...])
    for required in [
      "needs: release-please", "if: ${{ needs.release-please.outputs.release_created == 'true' }}",
      "uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
      "ref: ${{ needs.release-please.outputs.sha }}", "contents: write", "cancel-in-progress: false",
      "TAG_NAME: ${{ needs.release-please.outputs.tag_name }}", "RELEASE_SHA: ${{ needs.release-please.outputs.sha }}",
      "GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}", "GH_REPO: ${{ github.repository }}",
      "run: bash scripts/sync-release-notes.sh --repo \"$GH_REPO\" --tag \"$TAG_NAME\" --sha \"$RELEASE_SHA\""
    ] {
      if !sync.contains(required) { issues.append("missing \(required)") }
    }
    let conditions = sync.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("if:") }
    if conditions != ["if: ${{ needs.release-please.outputs.release_created == 'true' }}"] {
      issues.append("unexpected sync gating")
    }
    let scriptCalls = sync.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { $0.hasPrefix("run:") }
    if scriptCalls != ["run: bash scripts/sync-release-notes.sh --repo \"$GH_REPO\" --tag \"$TAG_NAME\" --sha \"$RELEASE_SHA\""] {
      issues.append("unexpected sync invocation")
    }
    if sync.contains("continue-on-error:") { issues.append("sync may ignore failure") }
    if sync.contains("cancel-in-progress: true") { issues.append("sync may be cancelled") }
    return issues
  }
}
