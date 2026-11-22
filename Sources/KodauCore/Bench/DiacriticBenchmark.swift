import Foundation

/// One line of a diacritic-restoration corpus: raw không-dấu input, the correct Vietnamese sentence, and the
/// words typed before this clause (optional, used as cross-clause context).
public struct BenchmarkLine: Codable, Equatable, Sendable {
    public let raw: String
    public let expected: String
    public let context: String

    public init(raw: String, expected: String, context: String = "") {
        self.raw = raw
        self.expected = expected
        self.context = context
    }

    private enum CodingKeys: String, CodingKey {
        case raw
        case expected
        case context
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.raw = try c.decode(String.self, forKey: .raw)
        self.expected = try c.decode(String.self, forKey: .expected)
        self.context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
    }
}

/// Word-level outcome of one corpus line.
public struct BenchmarkLineResult: Equatable, Sendable {
    public let lineNumber: Int
    public let raw: String
    public let expected: String
    public let got: String
    public let context: String
    /// Per word: true when the expected and produced words match exactly (case-sensitive).
    public let wordMatches: [Bool]

    public var wordCount: Int { wordMatches.count }
    public var correctWordCount: Int { wordMatches.filter { $0 }.count }
    public var isSentenceCorrect: Bool {
        !wordMatches.isEmpty && wordMatches.allSatisfy { $0 }
    }

    /// `raw | expected | got` with every mismatched word wrapped in brackets on both sides.
    public var formattedFailure: String {
        let expectedWords = TextSegmenter.wordTokens(from: expected)
        let gotWords = TextSegmenter.wordTokens(from: got)
        let markedExpected = Self.markedWords(expectedWords, matches: wordMatches)
        let markedGot = Self.markedWords(gotWords, matches: wordMatches)
        return "\(raw) | \(markedExpected) | \(markedGot)"
    }

    private static func markedWords(_ words: [String], matches: [Bool]) -> String {
        words.enumerated().map { index, word in
            let isWrong = index < matches.count ? !matches[index] : true
            return isWrong ? "[\(word)]" : word
        }.joined(separator: " ")
    }
}

/// Aggregate score for one corpus file.
public struct BenchmarkFileReport: Equatable, Sendable {
    public let name: String
    public let lineCount: Int
    public let correctWords: Int
    public let totalWords: Int
    public let correctSentences: Int
    public let results: [BenchmarkLineResult]

    public var wordAccuracy: Double {
        totalWords > 0 ? Double(correctWords) / Double(totalWords) : 0
    }

    public var sentenceAccuracy: Double {
        lineCount > 0 ? Double(correctSentences) / Double(lineCount) : 0
    }

    public var failures: [BenchmarkLineResult] {
        results.filter { !$0.isSentenceCorrect }
    }
}

/// Aggregate score across every loaded corpus file.
public struct BenchmarkReport: Equatable, Sendable {
    public let files: [BenchmarkFileReport]

    public var lineCount: Int { files.reduce(0) { $0 + $1.lineCount } }
    public var correctWords: Int { files.reduce(0) { $0 + $1.correctWords } }
    public var totalWords: Int { files.reduce(0) { $0 + $1.totalWords } }
    public var correctSentences: Int { files.reduce(0) { $0 + $1.correctSentences } }

    public var wordAccuracy: Double {
        totalWords > 0 ? Double(correctWords) / Double(totalWords) : 0
    }

    public var sentenceAccuracy: Double {
        lineCount > 0 ? Double(correctSentences) / Double(lineCount) : 0
    }

    public var failures: [BenchmarkLineResult] {
        files.flatMap(\.failures)
    }
}

/// Snapshot of the measured accuracy, written next to the corpus and used by the regression test.
public struct BenchmarkBaseline: Codable, Equatable, Sendable {
    public let wordAccuracy: Double
    public let sentenceAccuracy: Double
    public let totalWords: Int
    public let lineCount: Int

    public init(wordAccuracy: Double, sentenceAccuracy: Double, totalWords: Int, lineCount: Int) {
        self.wordAccuracy = wordAccuracy
        self.sentenceAccuracy = sentenceAccuracy
        self.totalWords = totalWords
        self.lineCount = lineCount
    }

    public init(report: BenchmarkReport) {
        self.init(
            wordAccuracy: report.wordAccuracy,
            sentenceAccuracy: report.sentenceAccuracy,
            totalWords: report.totalWords,
            lineCount: report.lineCount
        )
    }
}

/// Deterministic accuracy benchmark for the offline diacritic engine.
///
/// Every line runs through a fresh `SmartCoordinator` backed by an empty in-memory `LearningStore` and
/// `AppConfig(brainStrategy: .offlineOnly)`, so the score never depends on the user's brain, on the network,
/// or on the order of the corpus. `KodauBench` and `KodauCoreTests` share this exact evaluation.
public enum DiacriticBenchmark {

    /// Default corpus directory, resolved relative to this source file (`Tests/Corpus`).
    public static var defaultCorpusDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Bench
            .deletingLastPathComponent()   // KodauCore
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("Tests/Corpus", isDirectory: true)
    }

    /// Every `*.jsonl` file directly inside `directory`, sorted by name.
    public static func corpusFileURLs(in directory: URL) throws -> [URL] {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Parses one JSONL file. Blank lines are skipped; a malformed line throws with its number.
    public static func loadCorpus(at url: URL) throws -> [BenchmarkLine] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var lines: [BenchmarkLine] = []
        let decoder = JSONDecoder()
        for (index, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            do {
                lines.append(try decoder.decode(BenchmarkLine.self, from: Data(trimmed.utf8)))
            } catch {
                throw BenchmarkError.invalidLine(file: url.lastPathComponent, line: index + 1, underlying: error)
            }
        }
        return lines
    }

    /// Scores every line of one corpus file with a fresh offline-only coordinator per line.
    public static func evaluate(_ lines: [BenchmarkLine], name: String) throws -> BenchmarkFileReport {
        var results: [BenchmarkLineResult] = []
        results.reserveCapacity(lines.count)

        for (index, line) in lines.enumerated() {
            let store = try LearningStore(databaseURL: URL(fileURLWithPath: ":memory:"))
            let coordinator = SmartCoordinator(
                store: store,
                config: AppConfig(brainStrategy: .offlineOnly),
                geminiClient: GeminiClient()
            )
            let converted = coordinator.convertSync(line.raw, precedingContext: line.context).convertedText

            let expectedWords = TextSegmenter.wordTokens(from: line.expected)
            let gotWords = TextSegmenter.wordTokens(from: converted)
            let matches = expectedWords.indices.map { position -> Bool in
                guard position < gotWords.count else { return false }
                return gotWords[position] == expectedWords[position]
            }

            results.append(BenchmarkLineResult(
                lineNumber: index + 1,
                raw: line.raw,
                expected: line.expected,
                got: converted,
                context: line.context,
                wordMatches: matches
            ))
        }

        return BenchmarkFileReport(
            name: name,
            lineCount: results.count,
            correctWords: results.reduce(0) { $0 + $1.correctWordCount },
            totalWords: results.reduce(0) { $0 + $1.wordCount },
            correctSentences: results.filter(\.isSentenceCorrect).count,
            results: results
        )
    }

    /// Evaluates every `*.jsonl` in `directory` (sorted by file name).
    public static func run(directory: URL) throws -> BenchmarkReport {
        let urls = try corpusFileURLs(in: directory)
        guard !urls.isEmpty else { throw BenchmarkError.emptyCorpus(directory.path) }
        let files = try urls.map { url in
            try evaluate(try loadCorpus(at: url), name: url.lastPathComponent)
        }
        return BenchmarkReport(files: files)
    }

    /// Loads `baseline.json` from `directory`, or `nil` when it has not been generated yet.
    public static func loadBaseline(in directory: URL) -> BenchmarkBaseline? {
        let url = directory.appendingPathComponent(baselineFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(BenchmarkBaseline.self, from: data)
    }

    /// Writes `baseline.json` next to the corpus files.
    public static func writeBaseline(_ baseline: BenchmarkBaseline, in directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(baseline)
        try data.write(to: directory.appendingPathComponent(baselineFileName), options: .atomic)
    }

    public static let baselineFileName = "baseline.json"
}

public enum BenchmarkError: Error, LocalizedError, Sendable {
    case invalidLine(file: String, line: Int, underlying: Error)
    case emptyCorpus(String)

    public var errorDescription: String? {
        switch self {
        case .invalidLine(let file, let line, let underlying):
            return "\(file):\(line) is not valid corpus JSON (\(underlying))"
        case .emptyCorpus(let path):
            return "No *.jsonl corpus files found in \(path)"
        }
    }
}
