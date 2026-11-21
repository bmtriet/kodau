import Foundation

public enum GeminiError: Error, LocalizedError, Sendable {
    case missingAPIKey
    case invalidURL
    case httpError(statusCode: Int, message: String)
    case emptyResponse
    case networkError(String)
    case decodingError(String)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Chưa cấu hình Gemini API Key. Vui lòng nhập API Key trong Cài đặt."
        case .invalidURL:
            return "Tên model Gemini không hợp lệ."
        case .httpError(let statusCode, let message):
            if statusCode == 404 {
                return "Model không tìm thấy (HTTP 404): \(message). Hãy thử chuyển sang 'gemini-3.5-flash-lite', 'gemini-2.5-flash-lite', hoặc 'gemini-2.5-flash' trong Cài đặt."
            } else if statusCode == 401 || statusCode == 403 {
                return "API Key không hợp lệ hoặc không có quyền truy cập (HTTP \(statusCode)): \(message)"
            } else if statusCode == 429 {
                return "Đã vượt giới hạn gọi Gemini API (HTTP 429). Kodau sẽ tự dùng bộ não offline."
            }
            return "Lỗi Gemini API (HTTP \(statusCode)): \(message)"
        case .emptyResponse:
            return "Gemini API trả về kết quả rỗng."
        case .networkError(let message):
            return "Lỗi kết nối mạng tới Gemini API: \(message)"
        case .decodingError(let message):
            return "Không thể đọc phản hồi từ Gemini API: \(message)"
        }
    }
}

public struct GeminiTestResult: Sendable {
    public let success: Bool
    public let modelUsed: String
    public let latencyMs: Double
    public let sampleOutput: String
    public let errorMessage: String?
    public let tokenUsage: TokenUsage?

    public init(
        success: Bool,
        modelUsed: String,
        latencyMs: Double,
        sampleOutput: String,
        errorMessage: String?,
        tokenUsage: TokenUsage? = nil
    ) {
        self.success = success
        self.modelUsed = modelUsed
        self.latencyMs = latencyMs
        self.sampleOutput = sampleOutput
        self.errorMessage = errorMessage
        self.tokenUsage = tokenUsage
    }
}

/// What Gemini is allowed to change in the user's text.
public enum GeminiRestoreMode: String, Codable, Sendable {
    /// Add Vietnamese diacritics only. Every word keeps its exact letters, order, casing and punctuation.
    case diacriticsOnly
    /// Additionally fix clear spelling mistakes (Vietnamese and English), one word at a time, within a small
    /// edit distance. Never rephrases, never expands abbreviations, never changes word count.
    case fixTypos
}

/// Async Google Gemini REST API client for contextual Vietnamese diacritic restoration
/// and Vietnamese-English code-switching refinement.
public final class GeminiClient: Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    /// Calls `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent`
    /// using the `x-goog-api-key` header.
    public func restoreDiacritics(
        text: String,
        precedingContext: String = "",
        apiKey: String,
        model: String,
        mode: GeminiRestoreMode = .diacriticsOnly,
        timeoutSeconds: TimeInterval = 4.0
    ) async throws -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let elapsedMs: () -> Double = { (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0 }

        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty else {
            throw GeminiError.missingAPIKey
        }

        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ConversionResult(
                originalText: text,
                convertedText: text,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        let cleanModel = Self.normalizeModelName(model)
        guard !cleanModel.isEmpty,
              let encodedModel = cleanModel.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(encodedModel):generateContent") else {
            throw GeminiError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = max(1.0, timeoutSeconds)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(trimmedKey, forHTTPHeaderField: "x-goog-api-key")

        let requestBody = GeminiGenerateRequest(
            systemInstruction: GeminiContent(
                role: nil,
                parts: [GeminiPart(text: mode == .fixTypos ? Self.typoFixSystemPrompt : Self.systemPrompt)]
            ),
            contents: [
                GeminiContent(
                    role: "user",
                    parts: [GeminiPart(text: Self.buildUserPrompt(text: text, precedingContext: precedingContext))]
                )
            ],
            generationConfig: GeminiGenerationConfig(
                temperature: 0.1,
                maxOutputTokens: 512,
                responseMimeType: "application/json"
            )
        )

        do {
            request.httpBody = try JSONEncoder().encode(requestBody)
        } catch {
            throw GeminiError.decodingError("Failed to encode request: \(error.localizedDescription)")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GeminiError.networkError(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw GeminiError.networkError("Invalid HTTP response")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let apiMessage = Self.extractAPIErrorMessage(from: data) ?? "HTTP \(httpResponse.statusCode)"
            if httpResponse.statusCode == 404 {
                let hint = "Model '\(cleanModel)' was not found. Consider using 'gemini-3.5-flash-lite', 'gemini-2.5-flash-lite', or 'gemini-2.5-flash'."
                throw GeminiError.httpError(statusCode: 404, message: "\(apiMessage) (\(hint))")
            }
            throw GeminiError.httpError(statusCode: httpResponse.statusCode, message: apiMessage)
        }

        let decoded: GeminiGenerateResponse
        do {
            decoded = try JSONDecoder().decode(GeminiGenerateResponse.self, from: data)
        } catch {
            throw GeminiError.decodingError("Invalid Gemini JSON envelope: \(error.localizedDescription)")
        }

        let rawModelText = decoded.candidates?
            .first?
            .content?
            .parts?
            .compactMap(\.text)
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !rawModelText.isEmpty else {
            throw GeminiError.emptyResponse
        }

        let parsed = Self.parseModelOutput(rawModelText)
        let sanitizedText = try Self.sanitizeAndValidate(original: text, restored: parsed.text, mode: mode)
        let alternatives = Self.buildWordAlternatives(
            sanitizedText: sanitizedText,
            rawAlternatives: parsed.alternatives
        )
        let viRatio = Self.computeVietnameseRatio(sanitizedText)

        let tokenUsage: TokenUsage?
        if let meta = decoded.usageMetadata {
            let promptTokens = max(0, meta.promptTokenCount ?? 0)
            let candidateTokens = max(0, meta.candidatesTokenCount ?? 0)
            let thoughtTokens = max(0, meta.thoughtsTokenCount ?? 0)
            let effectiveOutput = candidateTokens + thoughtTokens
            let totalTokens = max(promptTokens + effectiveOutput, meta.totalTokenCount ?? (promptTokens + effectiveOutput))
            tokenUsage = TokenUsage(
                model: cleanModel,
                promptTokens: promptTokens,
                outputTokens: effectiveOutput,
                totalTokens: totalTokens
            )
        } else {
            tokenUsage = nil
        }

        return ConversionResult(
            originalText: text,
            convertedText: sanitizedText,
            confidence: 0.92,
            source: .geminiAPI,
            vietnameseRatio: viRatio,
            alternatives: alternatives,
            latencyMs: elapsedMs(),
            tokenUsage: tokenUsage
        )
    }

    /// Tests connectivity with the provided API key and model using a quick sample ("hom nay toi test Gemini API").
    public func testConnection(apiKey: String, model: String) async -> GeminiTestResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let sample = "hom nay toi test Gemini API"
        do {
            let result = try await restoreDiacritics(
                text: sample,
                precedingContext: "",
                apiKey: apiKey,
                model: model,
                timeoutSeconds: 8.0
            )
            return GeminiTestResult(
                success: true,
                modelUsed: Self.normalizeModelName(model),
                latencyMs: result.latencyMs,
                sampleOutput: result.convertedText,
                errorMessage: nil,
                tokenUsage: result.tokenUsage
            )
        } catch {
            let elapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0
            return GeminiTestResult(
                success: false,
                modelUsed: Self.normalizeModelName(model),
                latencyMs: elapsed,
                sampleOutput: "",
                errorMessage: error.localizedDescription,
                tokenUsage: nil
            )
        }
    }

    // MARK: - Prompting & Parsing

    /// Diacritics-only contract. The user's words are NOT ours to edit: the model may only add Vietnamese tone and
    /// vowel marks (and d -> đ). The validator below enforces this even if the model disobeys.
    private static let systemPrompt = """
    You are a Vietnamese DIACRITIC RESTORER inside a macOS keyboard. You are NOT an editor, spell checker, translator or writer.
    The user's text belongs to the user. Your ONLY permitted change: add Vietnamese tone/vowel marks to Vietnamese words typed without them (a->á/à/ả/ã/ạ/â/ă…, o->ô/ơ…, u->ư…, d->đ).

    Hard rules (violating any of them makes the output unusable):
    1. Output EXACTLY the same words, in the same order, with the same count. Removing every diacritic from your output must give back the input letter-for-letter.
    2. NEVER fix spelling or typos, even obvious ones ("dnag" stays "dnag", "teh" stays "teh").
    3. NEVER expand or change abbreviations, slang or teencode ("ko", "k", "dc", "j", "vs", "ok" stay exactly as typed).
    4. NEVER translate, rephrase, reorder, add, merge, split or drop words. NEVER change punctuation, spacing, emojis or capitalization.
    5. Keep English words, names, technical terms, code, URLs, emails and numbers untouched. If the input is pure English, return it unchanged.
    6. Natural Vietnamese-English code-switching is expected: "hom nay minh fix bug va review PR cho team" -> "hôm nay mình fix bug và review PR cho team".
    7. Tone placement for open oa/oe/uy syllables goes on the first vowel: hòa, tòa, xóa, khỏe, thủy.
    8. Use "Preceding context" only to disambiguate; never copy it into the output.

    Output ONLY this JSON object:
    {"text":"<input with diacritics added>","alternatives":[{"wordIndex":0,"base":"<ascii lowercase base>","candidates":["<selected>","<alt2>"]}]}
    Include "alternatives" only for genuinely ambiguous Vietnamese words (up to 5 words, up to 4 candidates each).
    """

    /// Opt-in typo fixing: still word-for-word, but a clearly misspelled word may be replaced by its intended
    /// spelling. The validator caps each change to a small edit distance and keeps the word count fixed.
    private static let typoFixSystemPrompt = """
    You are a Vietnamese DIACRITIC RESTORER with LIGHT TYPO CORRECTION inside a macOS keyboard. You are NOT an editor or writer.
    Allowed changes, nothing else:
    A. Add Vietnamese tone/vowel marks to Vietnamese words typed without them (d->đ included).
    B. Fix a word that is clearly MISSPELLED (Vietnamese or English) into the word the user obviously meant: swapped, missing, doubled or wrong neighbouring letters ("dnag"->"đang", "khogn"->"không", "teh"->"the", "recieve"->"receive"). One word in, one word out.

    Hard rules:
    1. Same number of words, same order. Never add, drop, merge, split, translate or reorder words.
    2. Only fix real misspellings. If a word is a valid word, a name, an abbreviation, slang or teencode ("ko", "k", "dc", "j", "vs", "ok"), leave its letters exactly as typed (only add diacritics).
    3. Never change grammar, word choice, style, punctuation, spacing, emojis or capitalization.
    4. Keep technical terms, code, URLs, emails and numbers untouched.
    5. Tone placement for open oa/oe/uy syllables goes on the first vowel: hòa, tòa, xóa, khỏe, thủy.
    6. Use "Preceding context" only to disambiguate; never copy it into the output.

    Output ONLY this JSON object:
    {"text":"<corrected text>","alternatives":[{"wordIndex":0,"base":"<ascii lowercase base>","candidates":["<selected>","<alt2>"]}]}
    Include "alternatives" only for genuinely ambiguous Vietnamese words (up to 5 words, up to 4 candidates each).
    """

    private static func buildUserPrompt(text: String, precedingContext: String) -> String {
        let trimmedContext = precedingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedContext.isEmpty {
            return "Input: \(text)"
        }
        return "Preceding context (do not include in output): \(trimmedContext)\nInput: \(text)"
    }

    private static func normalizeModelName(_ model: String) -> String {
        var clean = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.hasPrefix("models/") {
            clean = String(clean.dropFirst("models/".count))
        }
        return clean
    }

    private static func extractAPIErrorMessage(from data: Data) -> String? {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable {
                let message: String?
                let status: String?
            }
            let error: APIError?
        }
        if let decoded = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let msg = decoded.error?.message, !msg.isEmpty {
            return msg
        }
        if let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return String(raw.prefix(240))
        }
        return nil
    }

    private struct ParsedModelPayload {
        let text: String
        let alternatives: [RawAlternative]
    }

    private struct RawAlternative: Decodable {
        let wordIndex: Int
        let base: String?
        let candidates: [String]
    }

    private struct JSONRestorationOutput: Decodable {
        let text: String
        let alternatives: [RawAlternative]?
    }

    private static func parseModelOutput(_ raw: String) -> ParsedModelPayload {
        let unfenced = stripMarkdownFences(raw)

        // 1. Direct JSON decode
        if let data = unfenced.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(JSONRestorationOutput.self, from: data) {
            return ParsedModelPayload(text: decoded.text, alternatives: decoded.alternatives ?? [])
        }

        // 2. Extract embedded JSON object `{ ... }` if model added surrounding prose
        if let firstBrace = unfenced.firstIndex(of: "{"),
           let lastBrace = unfenced.lastIndex(of: "}"),
           firstBrace < lastBrace {
            let slice = String(unfenced[firstBrace...lastBrace])
            if let data = slice.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(JSONRestorationOutput.self, from: data) {
                return ParsedModelPayload(text: decoded.text, alternatives: decoded.alternatives ?? [])
            }
        }

        // 3. Graceful fallback to plain text (strip surrounding quotes if present)
        var fallback = unfenced.trimmingCharacters(in: .whitespacesAndNewlines)
        if fallback.hasPrefix("\""), fallback.hasSuffix("\""), fallback.count >= 2 {
            fallback = String(fallback.dropFirst().dropLast())
        }
        return ParsedModelPayload(text: fallback, alternatives: [])
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("```") else { return trimmed }

        var lines = trimmed.components(separatedBy: .newlines)
        if !lines.isEmpty && lines.first!.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeFirst()
        }
        if !lines.isEmpty && lines.last!.trimmingCharacters(in: .whitespaces) == "```" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Anti-Hallucination Safety Guard

    /// Enforces that Gemini never edits the user's words beyond what `mode` allows, regardless of what the model
    /// returns. The output is rebuilt from the ORIGINAL text's segments (spacing, punctuation, casing pattern), and
    /// each word is either the model's word (if allowed) or the user's original word.
    internal static func sanitizeAndValidate(
        original: String,
        restored: String,
        mode: GeminiRestoreMode = .diacriticsOnly
    ) throws -> String {
        let trimmedRestored = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRestored.isEmpty else {
            throw GeminiError.emptyResponse
        }

        // Guard against runaway explanation or huge length inflation
        if trimmedRestored.count > original.count * 2 + 24 {
            throw GeminiError.decodingError("Model response length deviated too far from original input")
        }

        let leadingWS = String(original.prefix(while: { $0.isWhitespace }))
        let afterLeading = original.dropFirst(leadingWS.count)
        let trailingWS = String(afterLeading.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let coreOriginal = String(afterLeading.dropLast(trailingWS.count))

        let origSegments = TextSegmenter.segment(coreOriginal)
        let origWords = origSegments.filter(\.isWord)
        let newWords = TextSegmenter.wordTokens(from: trimmedRestored)

        guard !origWords.isEmpty else {
            return original
        }

        // Word-for-word contract: any added, dropped, merged or split word means the model rewrote the text.
        // Reject the whole response so the caller falls back to the local engine (never guess an alignment).
        guard origWords.count == newWords.count else {
            throw GeminiError.decodingError("Model changed word count from \(origWords.count) to \(newWords.count)")
        }

        var rejectedWordCount = 0
        var verifiedWords: [String] = []
        verifiedWords.reserveCapacity(origWords.count)

        for idx in origWords.indices {
            let origWord = origWords[idx].raw
            let candidateWord = newWords[idx]

            if isAllowedWordChange(from: origWord, to: candidateWord, mode: mode) {
                verifiedWords.append(VietnamesePhonology.preserveCasing(from: origWord, to: candidateWord))
            } else {
                // Disallowed edit (spelling change, translation, expansion, broken code token...) -> keep the user's word.
                rejectedWordCount += 1
                verifiedWords.append(origWord)
            }
        }

        // If the model went off-script on many words, distrust the whole response.
        if Double(rejectedWordCount) / Double(origWords.count) > 0.40 {
            throw GeminiError.decodingError("Model altered too many base words (\(rejectedWordCount)/\(origWords.count))")
        }

        var rebuilt = leadingWS
        for seg in origSegments {
            rebuilt.append(seg.isWord ? verifiedWords[seg.wordIndex] : seg.raw)
        }
        rebuilt.append(trailingWS)
        return rebuilt
    }

    /// Whether replacing the user's `original` word with `candidate` is allowed in `mode`.
    internal static func isAllowedWordChange(from original: String, to candidate: String, mode: GeminiRestoreMode) -> Bool {
        let origBase = VNIEngine.stripDiacritics(original).lowercased()
        let candBase = VNIEngine.stripDiacritics(candidate).lowercased()

        // Diacritics-only change: always allowed in both modes.
        if origBase == candBase { return true }

        guard mode == .fixTypos else { return false }

        // Never "fix" code, URLs, numbers, emails, or words containing digits/symbols.
        if VietnamesePhonology.isCodeOrTechnicalToken(original) { return false }
        guard origBase.allSatisfy({ $0.isLetter }), candBase.allSatisfy({ $0.isLetter }) else { return false }
        // Very short tokens are usually abbreviations/teencode ("ko", "dc", "k") — leave them alone.
        guard origBase.count >= 3 else { return false }

        let distance = damerauLevenshtein(Array(origBase), Array(candBase))
        let maxDistance = origBase.count <= 4 ? 1 : 2
        return distance <= maxDistance
    }

    /// Optimal-string-alignment distance (adjacent transposition counts as 1, e.g. "teh" -> "the").
    internal static func damerauLevenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var d = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = i }
        for j in 0...b.count { d[0][j] = j }
        for i in 1...a.count {
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                d[i][j] = min(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + cost)
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] {
                    d[i][j] = min(d[i][j], d[i - 2][j - 2] + 1)
                }
            }
        }
        return d[a.count][b.count]
    }

    private static func buildWordAlternatives(
        sanitizedText: String,
        rawAlternatives: [RawAlternative]
    ) -> [WordAlternative] {
        guard !rawAlternatives.isEmpty else { return [] }
        let words = TextSegmenter.wordTokens(from: sanitizedText)
        guard !words.isEmpty else { return [] }

        var results: [WordAlternative] = []
        var seenIndices = Set<Int>()

        for item in rawAlternatives {
            guard item.wordIndex >= 0,
                  item.wordIndex < words.count,
                  seenIndices.insert(item.wordIndex).inserted else {
                continue
            }

            let selectedWord = words[item.wordIndex]
            let baseWord = (item.base?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                ? VNIEngine.stripDiacritics(item.base!).lowercased()
                : VNIEngine.stripDiacritics(selectedWord).lowercased()

            var candidates: [String] = [selectedWord]
            var seenCands: Set<String> = [selectedWord.lowercased()]

            for cand in item.candidates {
                let cleaned = cand.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { continue }
                // Only keep candidates that share the same ASCII base word
                if VNIEngine.stripDiacritics(cleaned).lowercased() != baseWord { continue }
                let cased = VietnamesePhonology.preserveCasing(from: selectedWord, to: cleaned)
                if seenCands.insert(cased.lowercased()).inserted {
                    candidates.append(cased)
                }
                if candidates.count >= 5 { break }
            }

            if candidates.count > 1 {
                results.append(
                    WordAlternative(
                        wordIndex: item.wordIndex,
                        baseWord: baseWord,
                        selected: selectedWord,
                        candidates: candidates
                    )
                )
            }
        }

        return results.sorted { $0.wordIndex < $1.wordIndex }
    }

    private static func computeVietnameseRatio(_ text: String) -> Double {
        let words = TextSegmenter.wordTokens(from: text)
        let alphaWords = words.filter { $0.contains(where: { $0.isLetter }) }
        guard !alphaWords.isEmpty else { return 0.0 }

        let viCount = alphaWords.filter { word in
            if VNIEngine.containsVietnameseDiacritics(word) { return true }
            let hint = VietnamesePhonology.classifyToken(word)
            return hint == .definiteVietnamese || hint == .likelyVietnamese
        }.count
        return Double(viCount) / Double(alphaWords.count)
    }

    // MARK: - Wire Models

    private struct GeminiGenerateRequest: Encodable {
        let systemInstruction: GeminiContent
        let contents: [GeminiContent]
        let generationConfig: GeminiGenerationConfig
    }

    private struct GeminiContent: Codable {
        let role: String?
        let parts: [GeminiPart]
    }

    private struct GeminiPart: Codable {
        let text: String?
    }

    private struct GeminiGenerationConfig: Encodable {
        let temperature: Double
        let maxOutputTokens: Int
        let responseMimeType: String
    }

    private struct GeminiGenerateResponse: Decodable {
        struct ResponseContent: Decodable {
            let role: String?
            let parts: [GeminiPart]?
        }
        struct Candidate: Decodable {
            let content: ResponseContent?
        }
        struct UsageMetadata: Decodable {
            let promptTokenCount: Int?
            let candidatesTokenCount: Int?
            let thoughtsTokenCount: Int?
            let totalTokenCount: Int?
        }
        let candidates: [Candidate]?
        let usageMetadata: UsageMetadata?
    }
}
