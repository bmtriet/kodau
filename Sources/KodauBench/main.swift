import Foundation
import KodauCore

/// Deterministic accuracy benchmark for Kodau's offline diacritic engine.
///
/// Usage:
///   KodauBench                     # score every Tests/Corpus/*.jsonl
///   KodauBench <dir>               # score a custom corpus directory
///   KodauBench --json              # machine-readable output
///   KodauBench --update-baseline   # write Tests/Corpus/baseline.json
///   KodauBench --limit-failures 10 # cap the printed failing lines
struct BenchOptions {
    var directory: URL = DiacriticBenchmark.defaultCorpusDirectory
    var json = false
    var updateBaseline = false
    var limitFailures = Int.max
}

func parseOptions(_ arguments: [String]) -> (BenchOptions, [String])? {
    var options = BenchOptions()
    var problems: [String] = []
    var index = 0

    while index < arguments.count {
        let arg = arguments[index]
        switch arg {
        case "--json":
            options.json = true
        case "--update-baseline":
            options.updateBaseline = true
        case "--limit-failures":
            index += 1
            guard index < arguments.count, let value = Int(arguments[index]), value >= 0 else {
                problems.append("--limit-failures needs a non-negative integer")
                break
            }
            options.limitFailures = value
        case "-h", "--help":
            return nil
        default:
            if arg.hasPrefix("-") {
                problems.append("unknown option \(arg)")
            } else {
                options.directory = URL(fileURLWithPath: arg)
            }
        }
        index += 1
    }

    return (options, problems)
}

func percent(_ value: Double) -> String {
    String(format: "%.2f%%", value * 100)
}

func printHumanReport(_ report: BenchmarkReport, options: BenchOptions) {
    for file in report.files {
        print("\(file.name): \(percent(file.wordAccuracy)) word · \(percent(file.sentenceAccuracy)) sentence "
              + "(\(file.lineCount) lines, \(file.correctWords)/\(file.totalWords) words)")
    }
    if report.files.count > 1 {
        print("")
        print("TOTAL: \(percent(report.wordAccuracy)) word · \(percent(report.sentenceAccuracy)) sentence "
              + "(\(report.lineCount) lines, \(report.correctWords)/\(report.totalWords) words)")
    }

    let failures = report.failures
    print("")
    print("\(failures.count) failing line(s); wrong words marked with [brackets].")
    for failure in failures.prefix(options.limitFailures) {
        print(failure.formattedFailure)
    }
    if failures.count > options.limitFailures {
        print("… \(failures.count - options.limitFailures) more (use --limit-failures to show them)")
    }
}

func jsonPayload(_ report: BenchmarkReport, options: BenchOptions) -> [String: Any] {
    let failures = report.failures
    return [
        "wordAccuracy": report.wordAccuracy,
        "sentenceAccuracy": report.sentenceAccuracy,
        "lineCount": report.lineCount,
        "correctWords": report.correctWords,
        "totalWords": report.totalWords,
        "correctSentences": report.correctSentences,
        "files": report.files.map { file in
            [
                "name": file.name,
                "wordAccuracy": file.wordAccuracy,
                "sentenceAccuracy": file.sentenceAccuracy,
                "lineCount": file.lineCount,
                "correctWords": file.correctWords,
                "totalWords": file.totalWords
            ]
        },
        "failureCount": failures.count,
        "failures": failures.prefix(options.limitFailures).map { failure in
            [
                "raw": failure.raw,
                "expected": failure.expected,
                "got": failure.got,
                "context": failure.context
            ]
        }
    ]
}

let arguments = Array(CommandLine.arguments.dropFirst())

guard let (options, problems) = parseOptions(arguments) else {
    print("""
    KodauBench — offline diacritic accuracy benchmark

    Usage: KodauBench [corpus-dir] [--json] [--update-baseline] [--limit-failures N]

    Defaults to \(DiacriticBenchmark.defaultCorpusDirectory.path)
    """)
    exit(0)
}

if !problems.isEmpty {
    for problem in problems {
        FileHandle.standardError.write(Data("error: \(problem)\n".utf8))
    }
    exit(2)
}

do {
    let report = try DiacriticBenchmark.run(directory: options.directory)

    if options.updateBaseline {
        let baseline = BenchmarkBaseline(report: report)
        try DiacriticBenchmark.writeBaseline(baseline, in: options.directory)
        if !options.json {
            print("Wrote \(options.directory.appendingPathComponent(DiacriticBenchmark.baselineFileName).path)")
        }
    }

    if options.json {
        let payload = jsonPayload(report, options: options)
        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        print(String(decoding: data, as: UTF8.self))
    } else {
        printHumanReport(report, options: options)
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}
