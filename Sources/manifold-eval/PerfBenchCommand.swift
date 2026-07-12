import Foundation
import ManifoldEval

/// The `perf-bench` subcommand: drives a ``BenchSpec`` JSON file's lanes over
/// HTTP (sequentially — never concurrently, see ``PerfRunner``), collates the
/// results, and renders `PERF-MATRIX.md`.
///
/// Usage:
///
///     manifold-eval perf-bench --spec <spec.json> [--out PERF-MATRIX.md] [--title T]
///
/// `--spec`  Path to a ``BenchSpec`` JSON fixture (model_family + protocol + lanes).
/// `--out`   Path to write the rendered Markdown to. Defaults to stdout.
/// `--title` Overrides the report's H1 heading.
enum PerfBenchCommand {

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) async {
        var specPath: String?
        var outPath: String?
        var title: String?

        func value(_ index: inout Int, _ flag: String) -> String {
            index += 1
            guard index < args.count else { die("\(flag) requires a value", 2) }
            return args[index]
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--spec":
                specPath = value(&index, token)
            case "--out":
                outPath = value(&index, token)
            case "--title":
                title = value(&index, token)
            default:
                die("unknown flag '\(token)'", 2)
            }
            index += 1
        }

        guard let specPath else { die("perf-bench requires --spec <spec.json>", 2) }
        let expandedSpecPath = (specPath as NSString).expandingTildeInPath

        let spec: BenchSpec
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: expandedSpecPath))
            spec = try JSONDecoder().decode(BenchSpec.self, from: data)
        } catch {
            die("perf-bench: cannot load spec '\(specPath)': \(error)", 1)
        }

        warn(
            "perf-bench: running '\(spec.modelFamily)' across \(spec.lanes.count) lane(s) "
            + "(\(spec.protocolConfig.warmupRuns) warmup + \(spec.protocolConfig.timedRuns) timed runs each, sequential)"
        )

        let results: [BenchResult]
        do {
            results = try await PerfRunner.runSpec(spec, onProgress: { warn($0) })
        } catch {
            die("perf-bench: \(error)", 1)
        }

        let collated: PerfCollationResult
        do {
            collated = try PerfCollator.collate(results)
        } catch {
            die("perf-bench: \(error)", 1)
        }

        for diagnostic in collated.diagnostics {
            warn("[\(diagnostic.severity.rawValue)] \(diagnostic.message)")
        }

        let markdown = PerfMatrixReport.render(collated, title: title ?? PerfMatrixReport.defaultTitle)

        if let outPath {
            let expandedOutPath = (outPath as NSString).expandingTildeInPath
            do {
                try markdown.write(toFile: expandedOutPath, atomically: true, encoding: .utf8)
            } catch {
                die("perf-bench: writing \(outPath): \(error)", 1)
            }
            print("wrote \(expandedOutPath)  (\(results.count) lane(s))")
        } else {
            print(markdown)
        }

        exit(collated.hasErrors ? 1 : 0)
    }
}
