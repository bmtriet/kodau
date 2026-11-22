import Testing
import Foundation
@testable import KodauCore

/// Guards the offline diacritic engine against accuracy regressions.
///
/// The evaluation lives in `KodauCore` (`DiacriticBenchmark`) so the `KodauBench` runner and this test score
/// exactly the same way. Refresh the recorded numbers with:
///
///     make bench ARGS="--update-baseline"
@Suite("Diacritic benchmark regression")
struct DiacriticBenchmarkTests {

    /// Allowed drop before the suite fails, in percentage points.
    private static let tolerancePercentagePoints = 0.5

    private static let corpusDirectory = DiacriticBenchmark.defaultCorpusDirectory

    @Test("Corpus loads and every line keeps a matching word count")
    func corpusIsWellFormed() throws {
        let urls = try DiacriticBenchmark.corpusFileURLs(in: Self.corpusDirectory)
        #expect(!urls.isEmpty, "expected at least one *.jsonl corpus file")

        for url in urls {
            let lines = try DiacriticBenchmark.loadCorpus(at: url)
            #expect(!lines.isEmpty, "\(url.lastPathComponent) is empty")
            for (index, line) in lines.enumerated() {
                let rawWords = TextSegmenter.wordTokens(from: line.raw)
                let expectedWords = TextSegmenter.wordTokens(from: line.expected)
                #expect(
                    rawWords.count == expectedWords.count,
                    "\(url.lastPathComponent):\(index + 1) word count \(rawWords.count) vs \(expectedWords.count)"
                )
            }
        }
    }

    @Test("Word accuracy does not drop more than 0.5 points below the recorded baseline")
    func wordAccuracyStaysAboveBaseline() throws {
        guard let baseline = DiacriticBenchmark.loadBaseline(in: Self.corpusDirectory) else {
            Issue.record("Tests/Corpus/baseline.json is missing — run `make bench ARGS=\"--update-baseline\"`")
            return
        }

        let report = try DiacriticBenchmark.run(directory: Self.corpusDirectory)
        let floor = baseline.wordAccuracy - Self.tolerancePercentagePoints / 100.0

        // Print the score so a failing run explains itself in CI output.
        let summary = "\(report.correctWords)/\(report.totalWords) words "
            + String(format: "(%.2f%% vs baseline %.2f%%)", report.wordAccuracy * 100, baseline.wordAccuracy * 100)

        #expect(
            report.wordAccuracy >= floor,
            "word accuracy regressed below the \(String(format: "%.2f%%", floor * 100)) floor: \(summary)"
        )
    }
}
