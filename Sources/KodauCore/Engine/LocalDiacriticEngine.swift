import Foundation

/// Preserves exact whitespace and punctuation around every word token so
/// punctuation, newlines, emojis, URLs, and code tokens are never mangled.
internal struct TextSegment: Sendable {
    let raw: String
    let isWord: Bool
    /// 0-based index among word segments, or -1 for non-word separators/punctuation.
    let wordIndex: Int
}

internal enum TextSegmenter {
    private static let edgePunctuation = CharacterSet(charactersIn: ".,!?;:()[]{}\"'`~@#%^&*+=<>|\\—–…")

    /// Splits text into alternating word and non-word segments whose concatenation
    /// equals the original `text` byte-for-byte.
    static func segment(_ text: String) -> [TextSegment] {
        guard !text.isEmpty else { return [] }

        var segments: [TextSegment] = []
        var wordCounter = 0

        let chars = Array(text)
        var i = 0
        let n = chars.count

        while i < n {
            // 1. Whitespace run
            if chars[i].isWhitespace {
                let start = i
                while i < n && chars[i].isWhitespace { i += 1 }
                segments.append(TextSegment(raw: String(chars[start..<i]), isWord: false, wordIndex: -1))
                continue
            }

            // 2. Non-whitespace chunk
            let chunkStart = i
            while i < n && !chars[i].isWhitespace { i += 1 }
            let chunk = String(chars[chunkStart..<i])

            // Peel leading punctuation
            let chunkChars = Array(chunk)
            var left = 0
            while left < chunkChars.count && isEdgePunctuation(chunkChars[left]) {
                left += 1
            }

            if left == chunkChars.count {
                // Pure punctuation / emoji / symbol run
                segments.append(TextSegment(raw: chunk, isWord: false, wordIndex: -1))
                continue
            }

            // Peel trailing punctuation
            var right = chunkChars.count - 1
            while right > left && isEdgePunctuation(chunkChars[right]) {
                right -= 1
            }

            if left > 0 {
                segments.append(TextSegment(raw: String(chunkChars[0..<left]), isWord: false, wordIndex: -1))
            }

            let core = String(chunkChars[left...right])

            // Keep URLs, emails, paths, code tokens, or numeric literals intact as a single word token
            if isAtomicToken(core) {
                segments.append(TextSegment(raw: core, isWord: true, wordIndex: wordCounter))
                wordCounter += 1
            } else {
                // Split internal punctuation (e.g., "hom,nay" or "ban/toi") while keeping contractions ("don't")
                let coreChars = Array(core)
                var j = 0
                while j < coreChars.count {
                    if coreChars[j].isLetter || coreChars[j].isNumber {
                        let wStart = j
                        while j < coreChars.count {
                            let ch = coreChars[j]
                            if ch.isLetter || ch.isNumber {
                                j += 1
                            } else if ch == "'"
                                && j > wStart
                                && j + 1 < coreChars.count
                                && coreChars[j - 1].isLetter
                                && coreChars[j + 1].isLetter {
                                j += 1
                            } else {
                                break
                            }
                        }
                        segments.append(TextSegment(raw: String(coreChars[wStart..<j]), isWord: true, wordIndex: wordCounter))
                        wordCounter += 1
                    } else {
                        let pStart = j
                        while j < coreChars.count && !(coreChars[j].isLetter || coreChars[j].isNumber) {
                            j += 1
                        }
                        segments.append(TextSegment(raw: String(coreChars[pStart..<j]), isWord: false, wordIndex: -1))
                    }
                }
            }

            if right + 1 < chunkChars.count {
                segments.append(TextSegment(raw: String(chunkChars[(right + 1)...]), isWord: false, wordIndex: -1))
            }
        }

        return segments
    }

    static func wordTokens(from text: String) -> [String] {
        segment(text).filter(\.isWord).map(\.raw)
    }

    private static func isEdgePunctuation(_ ch: Character) -> Bool {
        if ch.isLetter || ch.isNumber { return false }
        return ch.unicodeScalars.allSatisfy { edgePunctuation.contains($0) }
    }

    private static func isAtomicToken(_ token: String) -> Bool {
        if token.contains("://") || token.contains("@") || token.contains("_") || token.contains("\\") {
            return true
        }
        if VietnamesePhonology.isCodeOrTechnicalToken(token) {
            return true
        }
        // Keep dotted technical names / version numbers (e.g. "node.js", "v1.5", "3.14")
        if token.contains(".") || token.contains("/") {
            let parts = token.split(whereSeparator: { $0 == "." || $0 == "/" })
            if parts.count >= 2 && parts.allSatisfy({ !$0.isEmpty }) {
                return true
            }
        }
        return false
    }
}

/// Fast (<1ms) contextual offline Vietnamese diacritic restoration engine combining:
/// 1. Exact phrase memory recall from `LearningStore`
/// 2. Token + clause-level English / Vietnamese / Code-Switching detection
/// 3. Contextual Viterbi beam decoding over `SeedLexicon` + personal n-gram memory
public final class LocalDiacriticEngine: Sendable {
    public let store: LearningStore

    private static let beamWidth = 12
    private static let maxCandidatesPerWord = 8
    private static let maxAlternativesPerWord = 5

    public init(store: LearningStore) {
        self.store = store
    }

    /// Converts a word or clause completely offline in <1ms.
    public func convert(_ input: String, precedingContext: String = "") -> ConversionResult {
        let startTime = CFAbsoluteTimeGetCurrent()
        let elapsedMs: () -> Double = { (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0 }

        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ConversionResult(
                originalText: input,
                convertedText: input,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        let segments = TextSegmenter.segment(input)
        let wordSegments = segments.filter(\.isWord)
        guard !wordSegments.isEmpty else {
            return ConversionResult(
                originalText: input,
                convertedText: input,
                confidence: 1.0,
                source: .passthrough,
                vietnameseRatio: 0.0,
                alternatives: [],
                latencyMs: elapsedMs()
            )
        }

        // 1. Exact phrase memory recall (preserving leading/trailing whitespace & user casing)
        if let exactMatch = attemptPhraseRecall(input: input, segments: segments, wordSegments: wordSegments, elapsedMs: elapsedMs) {
            return exactMatch
        }

        // 2. Per-token + clause-level language classification (English vs Vietnamese vs Code-Switching)
        let contextWords = extractContextSurfaces(precedingContext)
        let tokenInfos = classifyClauseTokens(wordSegments: wordSegments, contextWords: contextWords)

        let alphabeticCount = tokenInfos.filter(\.isAlphabetic).count
        let vietnameseIndices = tokenInfos.indices.filter { tokenInfos[$0].treatAsVietnamese }
        let vietnameseRatio = alphabeticCount > 0
            ? Double(vietnameseIndices.count) / Double(alphabeticCount)
            : 0.0

        // Pure English / Code clause -> untouched!
        if vietnameseIndices.isEmpty {
            let singleWordAlternatives: [WordAlternative]
            if wordSegments.count == 1, let first = tokenInfos.first, first.hint == .ambiguous {
                singleWordAlternatives = buildSingleAmbiguousEnglishAlternatives(first)
            } else {
                singleWordAlternatives = []
            }
            return ConversionResult(
                originalText: input,
                convertedText: input,
                confidence: singleWordAlternatives.isEmpty ? 0.95 : 0.70,
                source: .localEnglish,
                vietnameseRatio: 0.0,
                alternatives: singleWordAlternatives,
                latencyMs: elapsedMs()
            )
        }

        // 3. Contextual Viterbi beam decoding over Vietnamese tokens (preserving English code-switching tokens)
        // No preceding text = start of sentence/clause: decode after the `<s>` pseudo-word so sentence-initial
        // corrections the user taught are recalled in that same position (context, not global replace).
        let decodeOutput = decodeWithViterbi(
            tokenInfos: tokenInfos,
            contextPrev2: contextWords.prev2,
            contextPrev1: contextWords.prev1 ?? LearningStore.sentenceStartToken
        )

        // 4. Reconstruct output preserving exact whitespace, punctuation, and user casing
        var reconstructed = ""
        reconstructed.reserveCapacity(input.count + 16)
        for seg in segments {
            if !seg.isWord {
                reconstructed.append(seg.raw)
            } else {
                let info = tokenInfos[seg.wordIndex]
                if !info.treatAsVietnamese || info.alreadyAccented {
                    reconstructed.append(seg.raw)
                } else {
                    let chosenSurface = decodeOutput.chosenSurfaces[seg.wordIndex]
                    reconstructed.append(VietnamesePhonology.preserveCasing(from: seg.raw, to: chosenSurface))
                }
            }
        }

        // 5. Build top-K alternatives for ambiguous Vietnamese words
        let alternatives = buildAlternatives(
            tokenInfos: tokenInfos,
            chosenSurfaces: decodeOutput.chosenSurfaces,
            contextPrev2: contextWords.prev2,
            contextPrev1: contextWords.prev1 ?? LearningStore.sentenceStartToken
        )

        // 6. Calibrated confidence score
        let confidence = computeCalibratedConfidence(
            tokenInfos: tokenInfos,
            stepDiagnostics: decodeOutput.stepDiagnostics
        )

        return ConversionResult(
            originalText: input,
            convertedText: reconstructed,
            confidence: confidence,
            source: .localViterbi,
            vietnameseRatio: vietnameseRatio,
            alternatives: alternatives,
            latencyMs: elapsedMs()
        )
    }

    // MARK: - Step 1: Exact Phrase Recall

    private func attemptPhraseRecall(
        input: String,
        segments: [TextSegment],
        wordSegments: [TextSegment],
        elapsedMs: () -> Double
    ) -> ConversionResult? {
        // Extract leading/trailing whitespace so phrase lookup works even with trailing space
        let leadingWS = String(input.prefix(while: { $0.isWhitespace }))
        let afterLeading = input.dropFirst(leadingWS.count)
        let trailingWS = String(afterLeading.reversed().prefix(while: { $0.isWhitespace }).reversed())
        let coreRaw = String(afterLeading.dropLast(trailingWS.count))
        guard !coreRaw.isEmpty else { return nil }

        // Check full trimmed clause first, then without trailing sentence punctuation
        var matchedTuple: (restored: String, userCorrected: Bool, useCount: Int)?
        var trailingPunct = ""
        var matchCore = coreRaw

        if let found = store.lookupPhrase(rawNoDiacritics: coreRaw) {
            matchedTuple = found
        } else {
            let punctSet = CharacterSet(charactersIn: ".,!?;:")
            let strippedCore = coreRaw.trimmingCharacters(in: punctSet)
            if !strippedCore.isEmpty, strippedCore.count < coreRaw.count,
               let found = store.lookupPhrase(rawNoDiacritics: strippedCore) {
                trailingPunct = String(coreRaw.dropFirst(strippedCore.count))
                matchCore = strippedCore
                matchedTuple = found
            }
        }

        guard let match = matchedTuple else { return nil }
        // Require >= 2 words for non-user-corrected phrase recall so single words still use full context
        guard wordSegments.count >= 2 || match.userCorrected else { return nil }

        // Never replay a stored phrase that changes the user's words (e.g. polluted by an old model rewrite):
        // the recalled text must be the input word-for-word, differing only in diacritics.
        let inputWords = TextSegmenter.wordTokens(from: matchCore)
        let recalledWords = TextSegmenter.wordTokens(from: match.restored)
        guard inputWords.count == recalledWords.count,
              zip(inputWords, recalledWords).allSatisfy({
                  VNIEngine.stripDiacritics($0).lowercased() == VNIEngine.stripDiacritics($1).lowercased()
              }) else {
            return nil
        }

        let casedRestored = applyPhraseCasing(fromOriginal: matchCore, toRestored: match.restored)
        let finalOutput = leadingWS + casedRestored + trailingPunct + trailingWS

        // Compute vietnamese ratio and lightweight alternatives for the recalled words
        let restoredWords = TextSegmenter.wordTokens(from: casedRestored)
        let alphaCount = restoredWords.filter { $0.contains(where: { $0.isLetter }) }.count
        let viCount = restoredWords.filter {
            VNIEngine.containsVietnameseDiacritics($0)
                || VietnamesePhonology.classifyToken($0) == .definiteVietnamese
                || VietnamesePhonology.classifyToken($0) == .likelyVietnamese
        }.count
        let viRatio = alphaCount > 0 ? Double(viCount) / Double(alphaCount) : 0.0

        var alternatives: [WordAlternative] = []
        if restoredWords.count == wordSegments.count {
            for idx in wordSegments.indices {
                let rawWord = wordSegments[idx].raw
                let selectedWord = restoredWords[idx]
                let base = VNIEngine.stripDiacritics(rawWord).lowercased()
                let cands = collectQuickAlternatives(base: base, rawWord: rawWord, selectedWord: selectedWord)
                if cands.count > 1 {
                    alternatives.append(
                        WordAlternative(
                            wordIndex: idx,
                            baseWord: base,
                            selected: selectedWord,
                            candidates: cands
                        )
                    )
                }
            }
        }

        return ConversionResult(
            originalText: input,
            convertedText: finalOutput,
            confidence: match.userCorrected ? 0.98 : 0.94,
            source: .localExact,
            vietnameseRatio: viRatio,
            alternatives: alternatives,
            latencyMs: elapsedMs()
        )
    }

    private func applyPhraseCasing(fromOriginal original: String, toRestored restored: String) -> String {
        let origSegments = TextSegmenter.segment(original)
        let restoredSegments = TextSegmenter.segment(restored)
        let origWords = origSegments.filter(\.isWord)
        let restoredWords = restoredSegments.filter(\.isWord)

        if origWords.count == restoredWords.count {
            var result = ""
            result.reserveCapacity(restored.count)
            for seg in origSegments {
                if !seg.isWord {
                    result.append(seg.raw)
                } else {
                    let target = restoredWords[seg.wordIndex].raw
                    result.append(VietnamesePhonology.preserveCasing(from: seg.raw, to: target))
                }
            }
            return result
        }

        return VietnamesePhonology.preserveCasing(from: original, to: restored)
    }

    private func collectQuickAlternatives(base: String, rawWord: String, selectedWord: String) -> [String] {
        var surfaces: [String] = [selectedWord]
        var seen: Set<String> = [selectedWord.lowercased()]

        let learned = store.unigramCandidates(for: base)
        for item in learned {
            let cased = VietnamesePhonology.preserveCasing(from: rawWord, to: item.surface)
            if seen.insert(cased.lowercased()).inserted {
                surfaces.append(cased)
            }
        }

        if let seed = SeedLexicon.vietnameseUnigrams[base] {
            for cand in seed.sorted(by: { $0.weight > $1.weight }) {
                let cased = VietnamesePhonology.preserveCasing(from: rawWord, to: cand.surface)
                if seen.insert(cased.lowercased()).inserted {
                    surfaces.append(cased)
                }
                if surfaces.count >= Self.maxAlternativesPerWord { break }
            }
        }

        return Array(surfaces.prefix(Self.maxAlternativesPerWord))
    }

    // MARK: - Step 2: Language Classification & Code-Switching

    private struct TokenInfo {
        let wordIndex: Int
        let raw: String
        let lower: String
        let base: String
        let isAlphabetic: Bool
        let alreadyAccented: Bool
        let hint: TokenLanguageHint
        let learnedUnigrams: [(surface: String, count: Int, userVerified: Bool, isEnglish: Bool)]
        var treatAsVietnamese: Bool
    }

    private func extractContextSurfaces(_ precedingContext: String) -> (prev2: String?, prev1: String?, endsWithVietnamese: Bool) {
        let words = TextSegmenter.wordTokens(from: precedingContext)
        guard !words.isEmpty else { return (nil, nil, false) }

        let last = words.last!
        let prev1 = last.lowercased()
        let prev2 = words.count >= 2 ? words[words.count - 2].lowercased() : nil

        let lastIsVi: Bool
        if VNIEngine.containsVietnameseDiacritics(last) {
            lastIsVi = true
        } else {
            let h = VietnamesePhonology.classifyToken(last)
            lastIsVi = (h == .definiteVietnamese || h == .likelyVietnamese)
        }
        return (prev2, prev1, lastIsVi)
    }

    private func classifyClauseTokens(
        wordSegments: [TextSegment],
        contextWords: (prev2: String?, prev1: String?, endsWithVietnamese: Bool)
    ) -> [TokenInfo] {
        var infos: [TokenInfo] = []
        infos.reserveCapacity(wordSegments.count)

        for seg in wordSegments {
            let raw = seg.raw
            let lower = raw.lowercased()
            let base = VNIEngine.stripDiacritics(lower).lowercased()
            let isAlpha = base.contains(where: { $0.isLetter }) && base.allSatisfy({ $0.isLetter || $0 == "'" })
            let alreadyAccented = VNIEngine.containsVietnameseDiacritics(raw)
            let learned = isAlpha ? store.unigramCandidates(for: base) : []

            let hint: TokenLanguageHint
            if alreadyAccented {
                hint = .definiteVietnamese
            } else if !isAlpha || VietnamesePhonology.isCodeOrTechnicalToken(raw) {
                hint = .definiteEnglishOrCode
            } else {
                hint = VietnamesePhonology.classifyToken(raw)
            }

            // Initial provisional assignment before neighbor & clause disambiguation
            var provisionalVi = false
            if alreadyAccented {
                provisionalVi = true
            } else if let verifiedOverride = topUserVerifiedOverride(learned) {
                // Respect explicit user-verified English or Vietnamese override!
                provisionalVi = !verifiedOverride.isEnglish
            } else {
                switch hint {
                case .definiteVietnamese, .likelyVietnamese:
                    provisionalVi = true
                case .definiteEnglishOrCode, .likelyEnglish, .ambiguous:
                    provisionalVi = false
                }
            }

            infos.append(
                TokenInfo(
                    wordIndex: seg.wordIndex,
                    raw: raw,
                    lower: lower,
                    base: base,
                    isAlphabetic: isAlpha,
                    alreadyAccented: alreadyAccented,
                    hint: hint,
                    learnedUnigrams: learned,
                    treatAsVietnamese: provisionalVi
                )
            )
        }

        // Clause-level strong signal counts
        var strongViSignals = contextWords.endsWithVietnamese ? 1 : 0
        var strongEnSignals = 0

        for info in infos where info.isAlphabetic {
            if info.alreadyAccented {
                strongViSignals += 2
                continue
            }
            if let override = topUserVerifiedOverride(info.learnedUnigrams) {
                if override.isEnglish { strongEnSignals += 2 } else { strongViSignals += 2 }
                continue
            }
            switch info.hint {
            case .definiteVietnamese:
                strongViSignals += 2
            case .likelyVietnamese:
                strongViSignals += 1
            case .definiteEnglishOrCode:
                strongEnSignals += 2
            case .likelyEnglish:
                strongEnSignals += 1
            case .ambiguous:
                break
            }
        }

        // Check Vietnamese bigram bridges across adjacent words (including ambiguous pairs like "ban co", "may ban")
        var hasViBigramAt = Array(repeating: false, count: infos.count)
        for i in 0..<infos.count {
            guard infos[i].isAlphabetic, infos[i].hint != .definiteEnglishOrCode else { continue }
            if i == 0, let prev1 = contextWords.prev1, hasVietnameseBigramEvidence(prevSurface: prev1, currBase: infos[i].base) {
                hasViBigramAt[i] = true
            }
            if i + 1 < infos.count, infos[i + 1].isAlphabetic, infos[i + 1].hint != .definiteEnglishOrCode {
                if hasVietnameseBigramBetweenBases(infos[i].base, infos[i + 1].base) {
                    hasViBigramAt[i] = true
                    hasViBigramAt[i + 1] = true
                }
            }
        }

        // Pure English guard:
        // If there are strong English signals, zero definite/likely Vietnamese words,
        // and no user-verified Vietnamese overrides, keep pure English untouched!
        let hasExplicitVi = infos.contains { info in
            if info.alreadyAccented { return true }
            if let ov = topUserVerifiedOverride(info.learnedUnigrams), !ov.isEnglish { return true }
            return info.hint == .definiteVietnamese || info.hint == .likelyVietnamese
        }

        if !hasExplicitVi && strongEnSignals > 0 && !contextWords.endsWithVietnamese {
            // Double check if almost all alphabetic words are English/ambiguous English words
            let allEnglishCompatible = infos.allSatisfy { info in
                if !info.isAlphabetic { return true }
                if let ov = topUserVerifiedOverride(info.learnedUnigrams) {
                    return ov.isEnglish
                }
                return info.hint == .definiteEnglishOrCode
                    || info.hint == .likelyEnglish
                    || info.hint == .ambiguous
            }
            if allEnglishCompatible {
                for i in infos.indices {
                    infos[i].treatAsVietnamese = false
                }
                return infos
            }
        }

        // Neighbor-aware disambiguation for `.ambiguous` tokens (e.g. `ban`, `can`, `do`, `may`, `no`, `to`, `co`, `go`, `so`, `van`)
        var decidedByTaughtContext = Array(repeating: false, count: infos.count)
        for i in infos.indices {
            guard infos[i].isAlphabetic, !infos[i].alreadyAccented else { continue }

            // 1. What the user taught for this word in THIS context (left or right neighbor) wins.
            if let taught = contextualTaughtDecision(at: i, infos: infos, contextWords: contextWords) {
                infos[i].treatAsVietnamese = taught
                decidedByTaughtContext[i] = true
                continue
            }

            // 2. Non-ambiguous words: a context-free user preference may still flip the phonology guess.
            if infos[i].hint != .ambiguous, let override = topUserVerifiedOverride(infos[i].learnedUnigrams) {
                infos[i].treatAsVietnamese = !override.isEnglish
                continue
            }

            guard infos[i].hint == .ambiguous else { continue }

            let leftIsVi: Bool
            if i > 0 {
                leftIsVi = infos[i - 1].treatAsVietnamese || infos[i - 1].hint == .definiteVietnamese || infos[i - 1].hint == .likelyVietnamese
            } else {
                leftIsVi = contextWords.endsWithVietnamese
            }

            let rightIsVi: Bool
            if i + 1 < infos.count {
                rightIsVi = infos[i + 1].treatAsVietnamese || infos[i + 1].hint == .definiteVietnamese || infos[i + 1].hint == .likelyVietnamese
            } else {
                rightIsVi = false
            }

            let leftIsEn = i > 0 && (infos[i - 1].hint == .definiteEnglishOrCode || infos[i - 1].hint == .likelyEnglish)
            let rightIsEn = (i + 1 < infos.count) && (infos[i + 1].hint == .definiteEnglishOrCode || infos[i + 1].hint == .likelyEnglish)

            if leftIsVi || rightIsVi {
                // Surrounded by or adjacent to Vietnamese tokens -> Vietnamese!
                infos[i].treatAsVietnamese = true
            } else if leftIsEn && rightIsEn {
                // Sandwiched between English tokens (e.g., "fix to deploy") -> keep English!
                infos[i].treatAsVietnamese = false
            } else if hasViBigramAt[i] && strongEnSignals == 0 {
                // Forms a known Vietnamese bigram with neighbor (e.g., "ban can", "co may")
                infos[i].treatAsVietnamese = true
            } else if let override = topUserVerifiedOverride(infos[i].learnedUnigrams) {
                // Context is neutral: fall back to the user's context-free preference as a tie-breaker only.
                infos[i].treatAsVietnamese = !override.isEnglish
            } else if strongViSignals > strongEnSignals {
                infos[i].treatAsVietnamese = true
            } else if strongEnSignals > strongViSignals {
                infos[i].treatAsVietnamese = false
            } else {
                // Single ambiguous word with no context: check learned bias or Vietnamese unigram presence
                if let topLearned = infos[i].learnedUnigrams.first {
                    infos[i].treatAsVietnamese = !topLearned.isEnglish
                } else if infos.count == 1 {
                    // Single isolated ambiguous English/Vietnamese word (e.g. "to", "can", "do", "no"):
                    // Keep English if it's a common English word without Vietnamese context
                    infos[i].treatAsVietnamese = !SeedLexicon.englishWords.contains(infos[i].base)
                } else {
                    infos[i].treatAsVietnamese = hasViBigramAt[i]
                }
            }
        }

        // Second pass for ambiguous tokens adjacent to newly resolved Vietnamese tokens
        for i in infos.indices where infos[i].hint == .ambiguous && !infos[i].treatAsVietnamese {
            if decidedByTaughtContext[i] { continue }
            let leftVi = i > 0 && infos[i - 1].treatAsVietnamese
            let rightVi = i + 1 < infos.count && infos[i + 1].treatAsVietnamese
            let leftEn = i > 0 && (infos[i - 1].hint == .definiteEnglishOrCode || infos[i - 1].hint == .likelyEnglish)
            let rightEn = (i + 1 < infos.count) && (infos[i + 1].hint == .definiteEnglishOrCode || infos[i + 1].hint == .likelyEnglish)
            if (leftVi || rightVi) && !(leftEn && rightEn) {
                infos[i].treatAsVietnamese = true
            }
        }

        return infos
    }

    /// The Vietnamese-vs-raw decision the user explicitly taught for token `i` in its current context:
    /// a user-verified learned bigram with the left neighbor (or `<s>` at sentence start), or a user-verified
    /// right-context entry with the next word. Returns `true` = Vietnamese, `false` = keep raw/English, `nil` = untaught.
    private func contextualTaughtDecision(
        at i: Int,
        infos: [TokenInfo],
        contextWords: (prev2: String?, prev1: String?, endsWithVietnamese: Bool)
    ) -> Bool? {
        let info = infos[i]
        guard info.isAlphabetic else { return nil }

        var leftSurfaces: [String] = []
        if i == 0 {
            leftSurfaces.append(contextWords.prev1 ?? LearningStore.sentenceStartToken)
        } else {
            let prev = infos[i - 1]
            leftSurfaces.append(prev.lower)
            leftSurfaces.append(contentsOf: prev.learnedUnigrams.prefix(2).map { $0.surface.lowercased() })
            if let seed = SeedLexicon.vietnameseUnigrams[prev.base] {
                leftSurfaces.append(contentsOf: seed.prefix(2).map { $0.surface.lowercased() })
            }
        }

        var seen = Set<String>()
        for left in leftSurfaces where seen.insert(left).inserted {
            if let hit = store.bigramCandidates(prevSurface: left, baseWord: info.base).first(where: { $0.userVerified }) {
                return isVietnameseChoice(hit.surface, base: info.base)
            }
        }

        if i + 1 < infos.count, infos[i + 1].isAlphabetic,
           let hit = store.nextBigramCandidates(baseWord: info.base, nextBase: infos[i + 1].base).first(where: { $0.userVerified }) {
            return isVietnameseChoice(hit.surface, base: info.base)
        }
        return nil
    }

    private func isVietnameseChoice(_ surface: String, base: String) -> Bool {
        if VNIEngine.containsVietnameseDiacritics(surface) { return true }
        // Plain form chosen: Vietnamese only if it is a real toneless Vietnamese syllable (e.g. `ban`, `cho`), not English.
        return surface == base
            && VietnamesePhonology.isValidVietnameseSyllable(base)
            && !SeedLexicon.englishWords.contains(base)
    }

    private func topUserVerifiedOverride(
        _ entries: [(surface: String, count: Int, userVerified: Bool, isEnglish: Bool)]
    ) -> (surface: String, count: Int, userVerified: Bool, isEnglish: Bool)? {
        entries.first(where: { $0.userVerified })
    }

    private func hasVietnameseBigramEvidence(prevSurface: String, currBase: String) -> Bool {
        if !store.bigramCandidates(prevSurface: prevSurface, baseWord: currBase).isEmpty {
            return true
        }
        guard let cands = SeedLexicon.vietnameseUnigrams[currBase] else { return false }
        for cand in cands.prefix(4) {
            if SeedLexicon.vietnameseBigrams["\(prevSurface) \(cand.surface)"] != nil {
                return true
            }
        }
        return false
    }

    private func hasVietnameseBigramBetweenBases(_ base1: String, _ base2: String) -> Bool {
        let cands1 = (SeedLexicon.vietnameseUnigrams[base1]?.prefix(4).map(\.surface) ?? [])
            + store.unigramCandidates(for: base1).prefix(2).map(\.surface)
        let cands2 = (SeedLexicon.vietnameseUnigrams[base2]?.prefix(4).map(\.surface) ?? [])
            + store.unigramCandidates(for: base2).prefix(2).map(\.surface)
        guard !cands1.isEmpty, !cands2.isEmpty else { return false }

        for s1 in cands1 {
            if !store.bigramCandidates(prevSurface: s1, baseWord: base2).isEmpty {
                return true
            }
            for s2 in cands2 {
                if SeedLexicon.vietnameseBigrams["\(s1) \(s2)"] != nil {
                    return true
                }
            }
        }
        return false
    }

    private func buildSingleAmbiguousEnglishAlternatives(_ info: TokenInfo) -> [WordAlternative] {
        var candidates: [String] = [info.raw]
        var seen: Set<String> = [info.raw.lowercased()]

        for item in info.learnedUnigrams {
            let cased = VietnamesePhonology.preserveCasing(from: info.raw, to: item.surface)
            if seen.insert(cased.lowercased()).inserted {
                candidates.append(cased)
            }
        }
        if let seed = SeedLexicon.vietnameseUnigrams[info.base] {
            for cand in seed.sorted(by: { $0.weight > $1.weight }) {
                let cased = VietnamesePhonology.preserveCasing(from: info.raw, to: cand.surface)
                if seen.insert(cased.lowercased()).inserted {
                    candidates.append(cased)
                }
                if candidates.count >= Self.maxAlternativesPerWord { break }
            }
        }
        guard candidates.count > 1 else { return [] }
        return [
            WordAlternative(
                wordIndex: info.wordIndex,
                baseWord: info.base,
                selected: info.raw,
                candidates: Array(candidates.prefix(Self.maxAlternativesPerWord))
            )
        ]
    }

    // MARK: - Step 3: Contextual Viterbi Beam Decoder

    private struct CandidateOption {
        let surface: String
        let unigramScore: Double
        let userVerified: Bool
        let fromSeed: Bool
        let fromStore: Bool
    }

    private struct StepDiagnostic {
        let hadUserVerified: Bool
        let hadContextMatch: Bool
        let isUnknown: Bool
        let candidateCount: Int
        let scoreMargin: Double
    }

    private struct BeamState {
        let prev2: String?
        let prev1: String?
        let score: Double
        let path: [String]
        let diagnostics: [StepDiagnostic]
    }

    private struct DecodeOutput {
        let chosenSurfaces: [String]
        let stepDiagnostics: [StepDiagnostic]
    }

    private func decodeWithViterbi(
        tokenInfos: [TokenInfo],
        contextPrev2: String?,
        contextPrev1: String?
    ) -> DecodeOutput {
        var beam: [BeamState] = [
            BeamState(prev2: contextPrev2, prev1: contextPrev1, score: 0.0, path: [], diagnostics: [])
        ]

        for (tokenIndex, info) in tokenInfos.enumerated() {
            // Right-hand context: ASCII base of the next word (its diacritics are not decided yet).
            let nextBase: String? = {
                let nextIndex = tokenIndex + 1
                guard nextIndex < tokenInfos.count, tokenInfos[nextIndex].isAlphabetic else { return nil }
                return tokenInfos[nextIndex].base
            }()

            if !info.treatAsVietnamese || info.alreadyAccented {
                let fixedSurface = info.lower
                let diag = StepDiagnostic(
                    hadUserVerified: false,
                    hadContextMatch: false,
                    isUnknown: false,
                    candidateCount: 1,
                    scoreMargin: 5.0
                )
                beam = beam.map { state in
                    BeamState(
                        prev2: state.prev1,
                        prev1: fixedSurface,
                        score: state.score,
                        path: state.path + [fixedSurface],
                        diagnostics: state.diagnostics + [diag]
                    )
                }
                continue
            }

            // Collect candidate surfaces for this Vietnamese token
            var baseCandidates = buildBaseCandidates(for: info)
            let isUnknown = baseCandidates.isEmpty || (baseCandidates.count == 1 && !baseCandidates[0].fromSeed && !baseCandidates[0].fromStore)

            // Also inspect learned bigrams/trigrams from active beam states so personal n-gram targets are always considered
            var candidateMap: [String: CandidateOption] = [:]
            for c in baseCandidates {
                candidateMap[c.surface] = c
            }

            var bigramCache: [String: [(surface: String, count: Int, userVerified: Bool)]] = [:]
            var trigramCache: [String: [(surface: String, count: Int, userVerified: Bool)]] = [:]

            for state in beam {
                if let p1 = state.prev1 {
                    if bigramCache[p1] == nil {
                        let bg = store.bigramCandidates(prevSurface: p1, baseWord: info.base)
                        bigramCache[p1] = bg
                        for item in bg where candidateMap[item.surface] == nil {
                            candidateMap[item.surface] = CandidateOption(
                                surface: item.surface,
                                unigramScore: -2.0 + log1p(Double(item.count)) * 0.8 + (item.userVerified ? 4.0 : 0.0),
                                userVerified: item.userVerified,
                                fromSeed: false,
                                fromStore: true
                            )
                        }
                    }
                    if let p2 = state.prev2 {
                        let triKey = "\(p2)\u{0000}\(p1)"
                        if trigramCache[triKey] == nil {
                            let tg = store.trigramCandidates(prev2: p2, prev1: p1, baseWord: info.base)
                            trigramCache[triKey] = tg
                            for item in tg where candidateMap[item.surface] == nil {
                                candidateMap[item.surface] = CandidateOption(
                                    surface: item.surface,
                                    unigramScore: -1.8 + log1p(Double(item.count)) * 0.9 + (item.userVerified ? 4.5 : 0.0),
                                    userVerified: item.userVerified,
                                    fromSeed: false,
                                    fromStore: true
                                )
                            }
                        }
                    }
                }
            }

            // Learned right-context surfaces (e.g. `ban` before `hang` -> `bán`) are always considered too.
            let nextContextHits: [(surface: String, count: Int, userVerified: Bool)] = nextBase.map {
                store.nextBigramCandidates(baseWord: info.base, nextBase: $0)
            } ?? []
            for item in nextContextHits where candidateMap[item.surface] == nil {
                candidateMap[item.surface] = CandidateOption(
                    surface: item.surface,
                    unigramScore: -2.0 + log1p(Double(item.count)) * 0.8 + (item.userVerified ? 4.0 : 0.0),
                    userVerified: item.userVerified,
                    fromSeed: false,
                    fromStore: true
                )
            }

            baseCandidates = candidateMap.values
                .sorted {
                    $0.unigramScore != $1.unigramScore
                        ? $0.unigramScore > $1.unigramScore
                        : $0.surface < $1.surface
                }
                .prefix(Self.maxCandidatesPerWord)
                .map { $0 }

            if baseCandidates.isEmpty {
                baseCandidates = [
                    CandidateOption(surface: info.base, unigramScore: -4.0, userVerified: false, fromSeed: false, fromStore: false)
                ]
            }

            // Expand beam states
            var nextStates: [BeamState] = []
            nextStates.reserveCapacity(beam.count * baseCandidates.count)

            // Track best score per (prev1, curr) pair to prune dominated paths cleanly
            var bestByPair: [String: BeamState] = [:]

            for state in beam {
                var scoredCandidates: [(cand: CandidateOption, stepScore: Double, hadContext: Bool, hadVerified: Bool)] = []
                scoredCandidates.reserveCapacity(baseCandidates.count)

                for cand in baseCandidates {
                    var stepScore = cand.unigramScore
                    var hadContext = false
                    var hadVerified = cand.userVerified

                    if let p1 = state.prev1 {
                        // Seed lexicon bigram
                        if let seedWeight = SeedLexicon.vietnameseBigrams["\(p1) \(cand.surface)"] {
                            stepScore += 2.0 + log1p(max(0.0, seedWeight) * 10.0) * 0.9
                            hadContext = true
                        }

                        // Personal learned bigram
                        if let learnedBigrams = bigramCache[p1],
                           let hit = learnedBigrams.first(where: { $0.surface == cand.surface }) {
                            stepScore += 2.5 + log1p(Double(hit.count)) * 1.6 + (hit.userVerified ? 6.0 : 0.0)
                            hadContext = true
                            if hit.userVerified { hadVerified = true }
                        }

                        // Personal learned trigram
                        if let p2 = state.prev2 {
                            let triKey = "\(p2)\u{0000}\(p1)"
                            if let learnedTrigrams = trigramCache[triKey],
                               let hit = learnedTrigrams.first(where: { $0.surface == cand.surface }) {
                                stepScore += 3.5 + log1p(Double(hit.count)) * 1.8 + (hit.userVerified ? 7.0 : 0.0)
                                hadContext = true
                                if hit.userVerified { hadVerified = true }
                            }
                        }
                    }

                    // Personal learned right-context (next word)
                    if let hit = nextContextHits.first(where: { $0.surface == cand.surface }) {
                        stepScore += 2.2 + log1p(Double(hit.count)) * 1.5 + (hit.userVerified ? 6.0 : 0.0)
                        hadContext = true
                        if hit.userVerified { hadVerified = true }
                    }

                    scoredCandidates.append((cand, stepScore, hadContext, hadVerified))
                }

                scoredCandidates.sort {
                    $0.stepScore != $1.stepScore ? $0.stepScore > $1.stepScore : $0.cand.surface < $1.cand.surface
                }
                let secondBestScore = scoredCandidates.count > 1 ? scoredCandidates[1].stepScore : (scoredCandidates[0].stepScore - 3.0)

                for (rankIdx, item) in scoredCandidates.enumerated() {
                    let margin = rankIdx == 0
                        ? max(0.0, item.stepScore - secondBestScore)
                        : 0.0
                    let diag = StepDiagnostic(
                        hadUserVerified: item.hadVerified,
                        hadContextMatch: item.hadContext,
                        isUnknown: isUnknown,
                        candidateCount: baseCandidates.count,
                        scoreMargin: margin
                    )
                    let totalScore = state.score + item.stepScore
                    let newState = BeamState(
                        prev2: state.prev1,
                        prev1: item.cand.surface,
                        score: totalScore,
                        path: state.path + [item.cand.surface],
                        diagnostics: state.diagnostics + [diag]
                    )

                    let pairKey = "\(state.prev1 ?? "")\u{0000}\(item.cand.surface)"
                    if let existing = bestByPair[pairKey] {
                        if newState.score > existing.score {
                            bestByPair[pairKey] = newState
                        }
                    } else {
                        bestByPair[pairKey] = newState
                    }
                }
            }

            // Equal scores must keep a stable order across processes: the beam is pruned here, so a
            // dictionary-iteration order would make the offline answer depend on the hash seed.
            nextStates = bestByPair.values
                .sorted {
                    if $0.score != $1.score { return $0.score > $1.score }
                    return $0.path.joined(separator: " ") < $1.path.joined(separator: " ")
                }
                .prefix(Self.beamWidth)
                .map { $0 }

            beam = nextStates.isEmpty ? beam : nextStates
        }

        guard let winner = beam.max(by: {
            $0.score != $1.score
                ? $0.score < $1.score
                : $0.path.joined(separator: " ") > $1.path.joined(separator: " ")
        }) else {
            return DecodeOutput(
                chosenSurfaces: tokenInfos.map(\.lower),
                stepDiagnostics: tokenInfos.map { _ in
                    StepDiagnostic(hadUserVerified: false, hadContextMatch: false, isUnknown: true, candidateCount: 1, scoreMargin: 0)
                }
            )
        }

        return DecodeOutput(chosenSurfaces: winner.path, stepDiagnostics: winner.diagnostics)
    }

    private func buildBaseCandidates(for info: TokenInfo) -> [CandidateOption] {
        var scoreBySurface: [String: (score: Double, verified: Bool, fromSeed: Bool, fromStore: Bool)] = [:]

        // 1. SeedLexicon unigrams (scale-invariant log-probability)
        if let seedList = SeedLexicon.vietnameseUnigrams[info.base], !seedList.isEmpty {
            let totalWeight = max(seedList.reduce(0.0) { $0 + max($1.weight, 0.0) }, 1e-9)
            for cand in seedList {
                let surface = cand.surface.lowercased()
                let prob = max(cand.weight, 1e-6) / totalWeight
                let logProb = log(prob)
                if let existing = scoreBySurface[surface] {
                    scoreBySurface[surface] = (max(existing.score, logProb), existing.verified, true, existing.fromStore)
                } else {
                    scoreBySurface[surface] = (logProb, false, true, false)
                }
            }
        }

        // 2. Personal LearningStore unigrams (strong personal & user-verified boost)
        for item in info.learnedUnigrams {
            let surface = item.surface.lowercased()
            // Unigrams are a context-free prior: a user-verified flag here only nudges (+1.0). The strong,
            // user-verified boosts live on bigram/trigram/next-word context so corrections never act as a global replace.
            let personalBoost = log1p(Double(item.count)) * 1.4 + (item.userVerified ? 1.0 : 0.0)
            if let existing = scoreBySurface[surface] {
                scoreBySurface[surface] = (
                    existing.score + personalBoost,
                    existing.verified || item.userVerified,
                    existing.fromSeed,
                    true
                )
            } else {
                // Learned word not in seed lexicon
                let baseScore = -1.2 + personalBoost
                scoreBySurface[surface] = (baseScore, item.userVerified, false, true)
            }
        }

        // 3. Fallback if empty or ambiguous English/Vietnamese word
        if scoreBySurface.isEmpty {
            scoreBySurface[info.base] = (-4.0, false, false, false)
        } else if (SeedLexicon.ambiguousEnViWords.contains(info.base) || SeedLexicon.englishWords.contains(info.base))
                    && scoreBySurface[info.base] == nil {
            scoreBySurface[info.base] = (-3.2, false, false, false)
        }

        return scoreBySurface.map { surface, meta in
            CandidateOption(
                surface: surface,
                unigramScore: meta.score,
                userVerified: meta.verified,
                fromSeed: meta.fromSeed,
                fromStore: meta.fromStore
            )
        }
        .sorted { $0.unigramScore > $1.unigramScore }
    }

    // MARK: - Step 4: Alternatives & Confidence Calibration

    private func buildAlternatives(
        tokenInfos: [TokenInfo],
        chosenSurfaces: [String],
        contextPrev2: String?,
        contextPrev1: String?
    ) -> [WordAlternative] {
        var alternatives: [WordAlternative] = []

        for idx in tokenInfos.indices {
            let info = tokenInfos[idx]
            guard info.treatAsVietnamese, !info.alreadyAccented else { continue }

            let chosen = chosenSurfaces[idx]
            let prev1 = idx > 0 ? chosenSurfaces[idx - 1] : contextPrev1
            let prev2 = idx > 1 ? chosenSurfaces[idx - 2] : (idx == 1 ? contextPrev1 : contextPrev2)
            let next1 = (idx + 1 < chosenSurfaces.count) ? chosenSurfaces[idx + 1] : nil

            let baseOptions = buildBaseCandidates(for: info)
            var ranked: [(surface: String, score: Double)] = []
            var seen = Set<String>()

            for opt in baseOptions {
                var s = opt.unigramScore
                if let p1 = prev1 {
                    if let bw = SeedLexicon.vietnameseBigrams["\(p1) \(opt.surface)"] {
                        s += 2.0 + log1p(max(0.0, bw) * 10.0) * 0.9
                    }
                    if let hit = store.bigramCandidates(prevSurface: p1, baseWord: info.base).first(where: { $0.surface == opt.surface }) {
                        s += 2.5 + log1p(Double(hit.count)) * 1.6 + (hit.userVerified ? 6.0 : 0.0)
                    }
                    if let p2 = prev2,
                       let hit = store.trigramCandidates(prev2: p2, prev1: p1, baseWord: info.base).first(where: { $0.surface == opt.surface }) {
                        s += 3.5 + log1p(Double(hit.count)) * 1.8 + (hit.userVerified ? 7.0 : 0.0)
                    }
                }
                if let n1 = next1, let bw = SeedLexicon.vietnameseBigrams["\(opt.surface) \(n1)"] {
                    s += 1.5 + log1p(max(0.0, bw) * 10.0) * 0.6
                }
                if idx + 1 < tokenInfos.count, tokenInfos[idx + 1].isAlphabetic,
                   let hit = store.nextBigramCandidates(baseWord: info.base, nextBase: tokenInfos[idx + 1].base)
                       .first(where: { $0.surface == opt.surface }) {
                    s += 2.2 + log1p(Double(hit.count)) * 1.5 + (hit.userVerified ? 6.0 : 0.0)
                }
                if seen.insert(opt.surface).inserted {
                    ranked.append((opt.surface, s))
                }
            }

            ranked.sort { $0.score > $1.score }

            let casedSelected = VietnamesePhonology.preserveCasing(from: info.raw, to: chosen)
            var casedCandidates: [String] = [casedSelected]
            var seenCased: Set<String> = [casedSelected.lowercased()]

            for item in ranked {
                let cased = VietnamesePhonology.preserveCasing(from: info.raw, to: item.surface)
                if seenCased.insert(cased.lowercased()).inserted {
                    casedCandidates.append(cased)
                }
                if casedCandidates.count >= Self.maxAlternativesPerWord { break }
            }

            // Include raw ASCII English option for ambiguous words if not already listed
            if (SeedLexicon.ambiguousEnViWords.contains(info.base) || SeedLexicon.englishWords.contains(info.base))
                && casedCandidates.count < Self.maxAlternativesPerWord
                && seenCased.insert(info.raw.lowercased()).inserted {
                casedCandidates.append(info.raw)
            }

            if casedCandidates.count > 1 {
                alternatives.append(
                    WordAlternative(
                        wordIndex: info.wordIndex,
                        baseWord: info.base,
                        selected: casedSelected,
                        candidates: casedCandidates
                    )
                )
            }
        }

        return alternatives
    }

    private func computeCalibratedConfidence(
        tokenInfos: [TokenInfo],
        stepDiagnostics: [StepDiagnostic]
    ) -> Double {
        var tokenConfidences: [Double] = []
        tokenConfidences.reserveCapacity(tokenInfos.count)

        for idx in tokenInfos.indices {
            let info = tokenInfos[idx]
            guard info.treatAsVietnamese else { continue }

            if info.alreadyAccented {
                tokenConfidences.append(0.96)
                continue
            }

            let diag = stepDiagnostics[idx]
            let conf: Double
            if diag.isUnknown {
                conf = 0.45
            } else if diag.hadUserVerified {
                conf = 0.95
            } else if diag.hadContextMatch {
                conf = min(0.94, 0.87 + min(0.07, diag.scoreMargin * 0.02))
            } else if diag.candidateCount <= 1 {
                conf = 0.86
            } else {
                // Ambiguous unigram-only decision without bigram/trigram backing -> 0.55...0.72
                conf = min(0.72, 0.55 + min(0.17, diag.scoreMargin * 0.06))
            }
            tokenConfidences.append(conf)
        }

        guard !tokenConfidences.isEmpty else { return 0.95 }
        let meanConf = tokenConfidences.reduce(0.0, +) / Double(tokenConfidences.count)
        let minConf = tokenConfidences.min() ?? meanConf
        let blended = 0.65 * meanConf + 0.35 * minConf
        return min(0.95, max(0.35, blended))
    }
}
