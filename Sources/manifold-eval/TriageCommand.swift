import Foundation
import ManifoldEval

/// The `triage` subcommand: read a flagged cell's raw transcript (a
/// ``TriageTranscript`` JSON file — two legs' repeat batches of `RawRun`s, the
/// same shape `diff` collects internally) and emit a structured pre-triage brief.
///
/// This is an ASSISTANT, not a gate: it proposes a classification, a confidence
/// read, and the exact differing bytes, but the recorded verdict stays
/// `nil`/unset unless the caller passes `--decide`. See ``TriageBrief/render()``
/// for the exact wording that keeps this a proposal (ORIGINS #7).
enum TriageCommand {

    /// Parsed argv, extracted from ``run`` so the flag grammar is unit-testable
    /// without touching the filesystem.
    struct ParsedArguments {
        var transcriptPath: String?
        var decide: HumanDecision?
        var bosOverride: String?
        var cohort: Cohort?
        var outPath: String?
    }

    static func parseArguments(_ args: [String], die: (String, Int32) -> Never) -> ParsedArguments {
        var parsed = ParsedArguments()

        func value(_ index: inout Int, _ flag: String) -> String {
            index += 1
            guard index < args.count else { die("\(flag) requires a value", 2) }
            return args[index]
        }

        var index = 0
        while index < args.count {
            let token = args[index]
            switch token {
            case "--transcript": parsed.transcriptPath = value(&index, token)
            case "--decide":
                let raw = value(&index, token)
                guard let decision = HumanDecision(rawValue: raw) else {
                    die("--decide must be genuine|benign, got '\(raw)'", 2)
                }
                parsed.decide = decision
            case "--bos": parsed.bosOverride = value(&index, token)
            case "--cohort":
                let raw = value(&index, token)
                guard let c = Cohort(rawValue: raw) else {
                    die("--cohort must be sameWeights|sameFamily|cloud, got '\(raw)'", 2)
                }
                parsed.cohort = c
            case "--out": parsed.outPath = value(&index, token)
            default:
                die("unknown flag '\(token)'", 2)
            }
            index += 1
        }
        return parsed
    }

    static func run(
        _ args: [String],
        die: (String, Int32) -> Never,
        warn: (String) -> Void
    ) {
        let parsed = parseArguments(args, die: die)
        guard let transcriptPath = parsed.transcriptPath else {
            die("triage requires --transcript <path.json>", 2)
        }

        let data: Data
        do {
            data = try Data(contentsOf: URL(fileURLWithPath: transcriptPath))
        } catch {
            die("cannot read --transcript '\(transcriptPath)': \(error)", 1)
        }

        let transcript: TriageTranscript
        do {
            transcript = try JSONDecoder().decode(TriageTranscript.self, from: data)
        } catch {
            die("cannot decode '\(transcriptPath)' as a triage transcript: \(error)", 1)
        }

        // A `--bos` flag on the CLI overrides whatever the transcript itself
        // recorded, matching `diff`'s "explicit flag wins" precedent.
        let bosSource = parsed.bosOverride ?? transcript.bos
        let bos: BOSNormalization
        do {
            bos = try TriageTranscript.resolveBOS(bosSource)
        } catch {
            die("\(error)", 2)
        }

        let brief: TriageBrief
        do {
            brief = try TriageBrief.build(
                legA: transcript.legA,
                legB: transcript.legB,
                bos: bos,
                cohortOverride: parsed.cohort,
                humanDecision: parsed.decide
            )
        } catch {
            die("\(error)", 1)
        }

        let rendered = brief.render()
        if let outPath = parsed.outPath {
            do {
                try rendered.write(toFile: outPath, atomically: true, encoding: .utf8)
            } catch {
                die("writing \(outPath): \(error)", 1)
            }
            warn("wrote \(outPath)")
        } else {
            print(rendered)
        }
    }
}
