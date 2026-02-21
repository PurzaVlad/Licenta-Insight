import Foundation

enum SummaryLength: String, CaseIterable {
    case short
    case medium
    case long
}

class AIService {
    static let shared = AIService()

    private let ocrService = OCRService.shared

    private init() {}

    // MARK: - Content Sampling

    /// Selects representative content from a document using zone-based sampling.
    /// For long documents, samples from front, middle, and tail rather than blindly truncating.
    private func selectRepresentativeContent(for document: Document, budget: Int) -> String {
        // Prefer structured OCR pages when available
        if let pages = document.ocrPages, !pages.isEmpty {
            let fullText = ocrService.buildStructuredText(from: pages, includePageLabels: false)
            if fullText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                return sampleFromPages(pages, budget: budget)
            }
        }
        let content = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return sampleFromFlatText(content, budget: budget)
    }

    private func sampleFromPages(_ pages: [OCRPage], budget: Int) -> String {
        // Build per-page text strings
        let pageTexts: [String] = pages.map { page in
            let sorted = page.blocks.sorted { $0.order < $1.order }
            return sorted.map { $0.text }.joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let totalChars = pageTexts.reduce(0) { $0 + $1.count }
        let n = pages.count

        // If everything fits, return with page labels
        if totalChars <= budget {
            return zip(0..<n, pageTexts).map { (i, text) in
                "[Page \(i + 1)] \(text)"
            }.joined(separator: "\n\n")
        }

        let frontBudget  = (budget * 40) / 100
        let middleBudget = (budget * 40) / 100
        let tailBudget   = budget - frontBudget - middleBudget

        var result: [String] = []

        // Front zone: greedily take pages until front budget exhausted
        var frontChars = 0
        var frontEnd = 0
        for i in 0..<n {
            let available = frontBudget - frontChars
            guard available > 0 else { break }
            let snippet = String(pageTexts[i].prefix(available))
            result.append("[Page \(i + 1)] \(snippet)")
            frontChars += snippet.count
            frontEnd = i + 1
            if frontChars >= frontBudget { break }
        }

        // Tail zone: always include last 2 pages (conclusions, totals, signatures)
        let tailStart = max(frontEnd, n - 2)
        var tailChars = 0
        for i in tailStart..<n {
            let available = tailBudget - tailChars
            guard available > 0 else { break }
            let snippet = String(pageTexts[i].prefix(available))
            result.append("[Page \(i + 1)] \(snippet)")
            tailChars += snippet.count
        }

        // Middle zone: 3 evenly-spaced samples between front and tail
        let middleRegion = frontEnd..<tailStart
        if !middleRegion.isEmpty {
            let step = max(1, middleRegion.count / 3)
            let perSample = middleBudget / max(1, middleRegion.count / step)
            var middleChars = 0
            var idx = middleRegion.lowerBound
            while idx < middleRegion.upperBound && middleChars < middleBudget {
                let available = min(perSample, middleBudget - middleChars)
                guard available > 0 else { break }
                let snippet = String(pageTexts[idx].prefix(available))
                result.append("[Page \(idx + 1)] \(snippet)")
                middleChars += snippet.count
                idx += step
            }
        }

        return result.joined(separator: "\n\n")
    }

    private func sampleFromFlatText(_ text: String, budget: Int) -> String {
        guard text.count > budget else { return text }

        let frontLen  = (budget * 45) / 100
        let middleLen = (budget * 25) / 100
        let tailLen   = budget - frontLen - middleLen

        let front = String(text.prefix(frontLen))

        let midStart = max(frontLen, (text.count / 2) - (middleLen / 2))
        let midIdx = text.index(text.startIndex, offsetBy: min(midStart, text.count))
        let midSlice = String(text[midIdx...].prefix(middleLen))

        let tail = String(text.suffix(tailLen))

        return [front, "...", midSlice, "...", tail].joined(separator: "\n")
    }

    // MARK: - Summary Generation

    func buildSummaryPrompt(for document: Document, length: SummaryLength = .medium) -> String {
        let charCount = documentContentLength(for: document)
        let targetTok = targetTokens(charCount: charCount, length: length)

        // Keep total prompt within the 2048-token context window.
        // Reserve: ~250 tokens for system prompt + template overhead + output budget.
        // Remaining tokens go to document content (~4 chars per token).
        let systemOverhead = 250
        let availableContentTokens = max(200, 2048 - systemOverhead - targetTok)
        let contentBudget = min(8_000, availableContentTokens * 4)

        let content = selectRepresentativeContent(for: document, budget: contentBudget)
        let facts = FactExtractorService.extract(from: fullDocumentText(for: document))
        AppLogger.ai.debug("FactExtractor: \(facts.facts.count) facts, contentBudget=\(contentBudget) for '\(document.title)'")

        let docType = document.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines)
        let systemPrompt = buildSummarySystemPrompt(length: length, docType: docType)
        let factLimit: Int
        switch length {
        case .short:  factLimit = 3
        case .medium: factLimit = 7
        case .long:   factLimit = 12
        }
        let organizedInput = buildOrganizedInput(
            content: content,
            facts: facts,
            docType: docType,
            title: document.title,
            factLimit: factLimit
        )

        return """
        <<<NO_HISTORY>>>
        <<<SUMMARY_TASK>>>
        <<<N_PREDICT:\(targetTok)>>>
        SYSTEM:
        \(systemPrompt)

        TARGET LENGTH: approximately \(targetTok) tokens. Stay close to this length.

        DOCUMENT CONTENT:
        \(organizedInput)
        """
    }

    /// Token budget: medium = clamp(round(N×0.04 + 60), 80, 600); short = ×0.5 min 40; long = ×1.6 max 900.
    private func targetTokens(charCount: Int, length: SummaryLength) -> Int {
        let n = Double(charCount)
        let medium = min(max(Int((n * 0.04 + 60).rounded()), 80), 600)
        switch length {
        case .short:  return max(40, Int((Double(medium) * 0.5).rounded()))
        case .medium: return medium
        case .long:   return min(900, Int((Double(medium) * 1.6).rounded()))
        }
    }

    private func buildSummarySystemPrompt(length: SummaryLength, docType: String) -> String {
        let typeInstruction = docType.isEmpty
            ? ""
            : " Prioritize information most relevant to a \(docType) document."
        let base = """
        You are a document summarizer. Output ONLY the summary text. No preamble, no labels, \
        no meta-commentary. Write in clear, dense prose. Prioritize information by importance: \
        critical findings and conclusions first, supporting details second, context third.\(typeInstruction) \
        Preserve specific numbers, names, dates, and claims. Never fabricate information not \
        present in the source. Markdown is supported — use it where it improves readability.
        """
        switch length {
        case .short:
            return base + "\n\nCover only the most critical 2-3 points."
        case .medium:
            return base
        case .long:
            return base + "\n\nInclude supporting evidence, secondary findings, and relevant context beyond the main points."
        }
    }

    private func buildOrganizedInput(content: String, facts: ExtractedFacts, docType: String, title: String, factLimit: Int) -> String {
        var parts: [String] = []
        if !docType.isEmpty {
            parts.append("DOCUMENT TYPE: \(docType)")
        }
        let baseName: String
        if let dotRange = title.range(of: ".", options: .backwards) {
            baseName = String(title[title.startIndex..<dotRange.lowerBound])
        } else {
            baseName = title
        }
        parts.append("TITLE: \(baseName)")
        let limitedFacts = Array(facts.facts.prefix(factLimit))
        if !limitedFacts.isEmpty {
            let bulletFacts = limitedFacts.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
            parts.append("KEY FACTS:\n\(bulletFacts)")
        }
        parts.append("CONTENT:\n\(content)")
        return parts.joined(separator: "\n\n")
    }

    /// Returns the full best-available text for a document (for fact extraction — not zone-sampled).
    private func fullDocumentText(for document: Document) -> String {
        if let pages = document.ocrPages, !pages.isEmpty {
            let full = ocrService.buildStructuredText(from: pages, includePageLabels: false)
            if full.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                return full
            }
        }
        return document.content
    }

    /// Returns the total character count of the document's best available text source.
    private func documentContentLength(for document: Document) -> Int {
        if let pages = document.ocrPages, !pages.isEmpty {
            let full = ocrService.buildStructuredText(from: pages, includePageLabels: false)
            if full.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                return full.count
            }
        }
        return document.content.count
    }

    // MARK: - Tag Generation

    /// Builds a semantic tag prompt using multi-word concept extraction and zoned sampling.
    func buildTagPrompt(for document: Document) -> String {
        let content = selectRepresentativeContent(for: document, budget: 4000)
        return """
        <<<TAG_REQUEST>>>
        <<<N_PREDICT:50>>>
        List exactly 4 concept tags for this document. Each tag is 1-3 words. Cover: the domain or field, the main subject or named entity, the purpose or action, and one additional relevant concept.
        Output format: one tag per line, nothing else. No numbering. No bullets. No explanation.

        Document:
        \(content)
        """
    }

    /// Processes AI-generated tags into a clean array of 4 semantic tags.
    func processTags(rawResponse: String, document: Document) -> [String] {
        var tags = Self.parseTags(from: rawResponse, limit: 4)

        if tags.isEmpty {
            // Minimal fallback: use archetype if available, otherwise generic descriptors
            let archetype = document.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines)
            tags = archetype.isEmpty
                ? ["Document", "Content", "Reference", "File"]
                : [archetype, "Document", "Content", "Reference"]
        }

        return Array(tags.prefix(4))
    }

    // MARK: - Tag Parsing

    /// Parses multi-word semantic tags from AI response text.
    static func parseTags(from text: String, limit: Int = 4) -> [String] {
        guard limit > 0 else { return [] }

        // Split on newlines first (primary delimiter), then commas (secondary)
        var candidates: [String] = []
        let lines = text.components(separatedBy: CharacterSet.newlines)
        for line in lines {
            // Strip leading bullets, numbers, dashes, punctuation
            var cleaned = line.replacingOccurrences(
                of: "^[\\d\\-\\*\\.\\)\\]\\[]+\\s*",
                with: "",
                options: .regularExpression
            )
            // Allow only letters, digits, spaces, hyphens
            cleaned = cleaned.replacingOccurrences(
                of: "[^A-Za-z0-9 \\-]",
                with: "",
                options: .regularExpression
            )
            // Collapse whitespace
            cleaned = cleaned.replacingOccurrences(
                of: "\\s+",
                with: " ",
                options: .regularExpression
            ).trimmingCharacters(in: .whitespacesAndNewlines)

            if cleaned.isEmpty { continue }

            // If the line contains a comma, split further
            let parts = cleaned.components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            candidates.append(contentsOf: parts)
        }

        // Validate candidates: 2-40 chars, must contain at least one letter
        let valid = candidates.filter { candidate in
            candidate.count >= 2 &&
            candidate.count <= 40 &&
            candidate.rangeOfCharacter(from: .letters) != nil
        }

        // Deduplicate preserving order
        var seen = Set<String>()
        let deduped = valid.filter { seen.insert($0.lowercased()).inserted }

        // Title-case each tag
        return deduped.prefix(limit).map { tag in
            tag.split(separator: " ")
               .map { word in word.prefix(1).uppercased() + word.dropFirst().lowercased() }
               .joined(separator: " ")
        }
    }

    // MARK: - Keyword Generation

    /// Extracts the top N most-frequent content words (non-stopwords, ≥4 chars) from text.
    /// These act as anchor words that reveal the document's vocabulary/domain.
    private func extractTopWords(from text: String, count: Int = 10) -> [String] {
        let stopwords: Set<String> = [
            "that","this","with","from","have","been","were","they","their","about",
            "would","could","should","which","there","these","those","more","some",
            "than","into","also","when","will","what","each","after","before","where",
            "such","even","here","then","both","same","most","other","while","under",
            "over","between","through","against","during","without","within","along",
            "following","across","however","therefore","whereas","although","whether",
            "provided","including","regarding","concerning","pursuant","thereof","herein"
        ]
        var freq: [String: Int] = [:]
        text.lowercased()
            .components(separatedBy: CharacterSet.letters.inverted)
            .filter { $0.count >= 4 && !stopwords.contains($0) }
            .forEach { freq[$0, default: 0] += 1 }
        return freq.sorted { $0.value > $1.value }.prefix(count).map { $0.key }
    }

    /// Builds a keyword prompt that identifies the document archetype (type, not topic).
    /// Includes top-frequency anchor words so the model can infer the domain from vocabulary.
    func buildKeywordPrompt(for document: Document) -> String {
        let content = selectRepresentativeContent(for: document, budget: 1500)

        let titleAnchor: String = {
            let base = document.title
            if let dotRange = base.range(of: ".", options: .backwards) {
                return String(base[base.startIndex..<dotRange.lowerBound])
            }
            return base
        }()

        let topWords = extractTopWords(from: content, count: 10)
        let topWordsLine = topWords.isEmpty ? "" : "\nTop words: \(topWords.joined(separator: ", "))"

        return """
        <<<NO_HISTORY>>>
        <<<N_PREDICT:15>>>
        Name the type of this document in 2-3 words. Output only those words, no punctuation.

        Filename: \(titleAnchor)\(topWordsLine)
        Excerpt:
        \(content)
        """
    }

    /// Cleans AI-generated keyword output into a short title-cased phrase (1-3 words)
    func processKeyword(rawResponse: String) -> String {
        let firstLine = rawResponse
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        let words = firstLine
            .components(separatedBy: .whitespaces)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(3)
        var result = words.joined(separator: " ")
        result = result.replacingOccurrences(of: "[^A-Za-z ]", with: "", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespaces)
        guard !result.isEmpty else { return "" }
        return result.prefix(1).uppercased() + result.dropFirst()
    }

    // MARK: - Conversation Title Generation

    /// Builds a prompt to generate a short conversation title from the first exchange
    func buildTitlePrompt(userMessage: String, assistantExcerpt: String) -> String {
        let userSnip = String(userMessage.prefix(200))
        let assistantSnip = String(assistantExcerpt.prefix(300))
        return """
        <<<NO_HISTORY>>>
        Based on this conversation excerpt, write a short title (4–7 words, no punctuation at the end).
        Output only the title text, nothing else.

        User: \(userSnip)
        Assistant: \(assistantSnip)
        """
    }

    // MARK: - Summary Cleaning

    /// Post-processing pipeline for AI-generated summary output.
    func cleanSummaryOutput(_ raw: String) -> String {
        var result = raw
        // Strip leading preamble lines (common Qwen meta-commentary slipthrough)
        result = result.replacingOccurrences(
            of: #"^\s*(?:Here(?:\s+(?:is|are|follows))?|Sure[,!]?|The following[:\s]|This document[:\s]|Below[:\s])[^\n]*[\n:]\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Strip echoed "Summary:" label
        result = result.replacingOccurrences(
            of: #"^\s*Summary:\s*"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Strip echoed prompt blocks (KEY FACTS / DOCUMENT CONTENT / TARGET LENGTH)
        result = result.replacingOccurrences(
            of: #"(?s)^\s*(?:KEY FACTS|DOCUMENT CONTENT|DOCUMENT TYPE|TARGET LENGTH)[^\n]*\n.*?\n\n"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        // Collapse 3+ newlines → one blank line
        result = result.replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        // Ensure output starts with a capital letter
        if let first = result.unicodeScalars.first,
           CharacterSet.lowercaseLetters.contains(first) {
            result = result.prefix(1).uppercased() + result.dropFirst()
        }
        return result
    }

    // MARK: - Document Context Building

    /// Builds a comprehensive context string from all documents
    func getAllDocumentContent(from documents: [Document]) -> String {
        documents.map { document in
            """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Category: \(document.category.rawValue)
            Keywords: \(document.keywordsResume)
            Tags: \(document.tags.joined(separator: ", "))
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Summary: \(document.summary)

            Content:
            \(document.content)

            ---

            """
        }.joined()
    }

    /// Builds a summaries-only context string
    func getDocumentSummaries(from documents: [Document]) -> String {
        documents.map { document in
            """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Summary: \(document.summary)
            Tags: \(document.tags.joined(separator: ", "))
            Content Length: \(document.content.count) characters

            ---

            """
        }.joined()
    }

    /// Builds smart context using summaries when available, content preview otherwise
    func getSmartDocumentContext(from documents: [Document]) -> String {
        let summaryUnavailableMessage = "Not available as source file is still available."

        return documents.map { document in
            let summaryTrimmed = document.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasUsableSummary = !summaryTrimmed.isEmpty &&
                                  summaryTrimmed != "Processing..." &&
                                  summaryTrimmed != "Processing summary..." &&
                                  !summaryTrimmed.contains("Processing summary") &&
                                  summaryTrimmed != summaryUnavailableMessage

            let contentToUse = hasUsableSummary ? document.summary : String(document.content.prefix(500))
            let contentType = hasUsableSummary ? "Summary:" : "Content (first 500 chars):"

            return """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Tags: \(document.tags.joined(separator: ", "))
            \(contentType)
            \(contentToUse)

            ---

            """
        }.joined()
    }
}
