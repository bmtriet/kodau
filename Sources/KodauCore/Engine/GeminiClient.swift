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
                parts: [GeminiPart(text: Self.systemPrompt)]
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
        let sanitizedText = try Self.sanitizeAndValidate(original: text, restored: parsed.text)
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

    private static let systemPrompt = """
    You are a deterministic Vietnamese diacritic restoration engine for a macOS keyboard.
    Rules:
    1. Restore accurate Vietnamese diacritics ONLY to Vietnamese words typed without diacritics.
    2. Keep English words, technical terms, code identifiers, URLs, emails, numbers, punctuation, emojis, and original capitalization completely untouched.
    3. Support natural Vietnamese-English code-switching (e.g. "hom nay minh fix bug va review PR cho team" -> "hôm nay mình fix bug và review PR cho team").
    4. If the input is pure English, return it unchanged.
    5. Preserve the EXACT word count, word order, whitespace, and punctuation. NEVER translate, explain, rephrase, add, or drop words.
    6. For Vietnamese oa/oe/uy open syllables, ALWAYS put the tone mark on the first vowel: hòa, tòa, xóa, khỏe, thủy (òa, óe, úy — NOT hoà, toà, khoẻ, thuý).
    7. Output ONLY a JSON object with this exact schema:
    {"text":"<restored text>","alternatives":[{"wordIndex":0,"base":"<ascii lowercase base>","candidates":["<selected>","<alt2>"]}]}
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

    private static func sanitizeAndValidate(original: String, restored: String) throws -> String {
        let trimmedRestored = restored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRestored.isEmpty else {
            throw GeminiError.emptyResponse
        }

        // Guard against runaway explanation or huge length inflation
        if trimmedRestored.count > original.count * 2 + 24 {
            throw GeminiError.decodingError("Model response length deviated too far from original input")
        }

        // Preserve exact leading and trailing whitespace from the original input
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

        // Reject drastically altered word count
        let maxAllowedDiff = max(1, origWords.count / 5)
        if abs(origWords.count - newWords.count) > maxAllowedDiff {
            throw GeminiError.decodingError("Model changed word count from \(origWords.count) to \(newWords.count)")
        }

        // If exact word count matches, rebuild using original whitespace/punctuation and verify every token's ASCII base
        if origWords.count == newWords.count {
            var mismatchedBaseCount = 0
            var verifiedWords: [String] = []
            verifiedWords.reserveCapacity(origWords.count)

            for idx in origWords.indices {
                let origWord = origWords[idx].raw
                let candidateWord = newWords[idx]
                let origBase = VNIEngine.stripDiacritics(origWord).lowercased()
                let candBase = VNIEngine.stripDiacritics(candidateWord).lowercased()

                if origBase == candBase {
                    // Valid diacritic-only transformation; preserve user's casing pattern
                    verifiedWords.append(VietnamesePhonology.preserveCasing(from: origWord, to: candidateWord))
                } else {
                    // Model altered the base spelling (e.g. translated an English word or broke a URL/code token) -> keep original!
                    mismatchedBaseCount += 1
                    verifiedWords.append(origWord)
                }
            }

            // If more than 40% of words were hallucinated/translated, reject the whole response so we fall back to LocalEngine
            if Double(mismatchedBaseCount) / Double(origWords.count) > 0.40 {
                throw GeminiError.decodingError("Model altered too many base words (\(mismatchedBaseCount)/\(origWords.count))")
            }

            var rebuilt = ""
            rebuilt.reserveCapacity(trimmedRestored.count + leadingWS.count + trailingWS.count)
            rebuilt.append(leadingWS)
            for seg in origSegments {
                if seg.isWord {
                    rebuilt.append(verifiedWords[seg.wordIndex])
                } else {
                    rebuilt.append(seg.raw)
                }
            }
            rebuilt.append(trailingWS)
            return rebuilt
        }

        // Slight word-count mismatch within tolerance: verify stripped similarity
        let origNorm = VNIEngine.stripDiacritics(coreOriginal).lowercased()
        let newNorm = VNIEngine.stripDiacritics(trimmedRestored).lowercased()
        if abs(origNorm.count - newNorm.count) > max(4, origNorm.count / 4) {
            throw GeminiError.decodingError("Model text diverged from original stripped text")
        }
        return leadingWS + trimmedRestored + trailingWS
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
