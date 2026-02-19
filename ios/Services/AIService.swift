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

    /// Builds a summary prompt feeding the full zoned content and embedding an n_predict token
    /// so the JS model runner applies the right output token budget for this document size and length.
    func buildSummaryPrompt(for document: Document, length: SummaryLength = .medium) -> String {
        let fullLength = documentContentLength(for: document)
        let content = selectRepresentativeContent(for: document, budget: 16_000)
        let archetype = document.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines)
        let facts = FactExtractorService.extract(from: fullDocumentText(for: document))
        AppLogger.ai.debug("FactExtractor: \(facts.facts.count) facts for '\(document.title)'")
        return buildSummaryPrompt(input: content, length: length, archetype: archetype, docLength: fullLength, facts: facts)
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

    /// Returns an <<<N_PREDICT:N>>> token encoding the desired output token budget,
    /// plus the raw token count for word-count estimation.
    /// Scales with document size so a 200-page doc gets a proportionally richer summary than a 1-page doc.
    /// The length preference is a multiplier: short ≈ 0.45×, medium ≈ 1×, long ≈ 2× (capped at 2400).
    private func nPredictToken(length: SummaryLength, docLength: Int) -> String {
        let base: Int
        switch docLength {
        case ..<3_000:   base = 200   // ~1 page
        case ..<8_000:   base = 320   // ~3-5 pages
        case ..<20_000:  base = 450   // ~5-15 pages
        case ..<50_000:  base = 600   // ~15-30 pages
        case ..<150_000: base = 800   // ~30-100 pages
        default:         base = 1000  // 100+ pages
        }
        let tokens: Int
        switch length {
        case .short:  tokens = max(120, Int(Double(base) * 0.5))
        case .medium: tokens = base
        case .long:   tokens = min(2000, Int(Double(base) * 2.0))
        }
        return "<<<N_PREDICT:\(tokens)>>>"
    }

    private func buildSummaryPrompt(input: String, length: SummaryLength, archetype: String, docLength: Int, facts: ExtractedFacts) -> String {
        let nPredict = nPredictToken(length: length, docLength: docLength)

        let archetypeHint = archetype.isEmpty ? "" : "This is a \(archetype).\n"
        let factsSection = facts.isEmpty ? "" : "DOCUMENT FACTS:\n\(facts.formatted())\n\n"

        let instruction: String
        switch length {
        case .short:
            instruction = """
            Write a concise summary of this document. The DOCUMENT FACTS above are verified anchors — \
            use them for accuracy but weave them naturally into your writing, don't list them verbatim. \
            Cover what the document is, who's involved, and the most critical specifics. \
            Plain language. No preamble.
            """
        case .medium:
            instruction = """
            Write a detailed, informative summary of this document. The DOCUMENT FACTS above are verified anchors \
            for accuracy — weave them naturally into your writing rather than listing them. \
            Cover what this document is, who's involved, the key terms and specifics, and what it means. \
            Let the content and complexity of the document guide the depth and structure of your response. \
            Plain language anyone can understand. No preamble.
            """
        case .long:
            instruction = """
            Write a thorough, in-depth summary of this document. The DOCUMENT FACTS above are verified anchors \
            for accuracy — weave them naturally into your writing rather than listing them. \
            Cover every significant party and their role, every important date and deadline, every key amount \
            and obligation, the conditions and terms that matter, and what this document means in practice. \
            Let the document's own structure and complexity dictate how deep you go and how you organize the summary. \
            Plain language. No preamble.
            """
        }

        return """
        <<<NO_HISTORY>>>
        \(nPredict)
        \(archetypeHint)\(factsSection)DOCUMENT:
        \(input)

        \(instruction)
        """
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
        Example output:
        employment law
        contract termination
        severance agreement
        non-disclosure clause

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

    /// Builds a keyword prompt that identifies the document archetype (type, not topic).
    func buildKeywordPrompt(for document: Document) -> String {
        let content = selectRepresentativeContent(for: document, budget: 1500)

        let titleAnchor: String = {
            let base = document.title
            if let dotRange = base.range(of: ".", options: .backwards) {
                return String(base[base.startIndex..<dotRange.lowerBound])
            }
            return base
        }()

        return """
        <<<NO_HISTORY>>>
        <<<N_PREDICT:15>>>
        Identify this document in 2-4 words. Name its type, not its topic.
        Output only those words. No punctuation. No explanation.

        Filename: \(titleAnchor)
        Document excerpt:
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

    /// Cleans AI-generated summary output.
    func cleanSummaryOutput(_ raw: String) -> String {
        var result = raw
        // Strip echoed completion cue if the model repeated it
        result = result.replacingOccurrences(of: "^\\s*Summary:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
        // Strip if model echoed back the DOCUMENT FACTS block
        result = result.replacingOccurrences(of: "(?s)^DOCUMENT FACTS:[\\s\\S]*?\\n\\n", with: "", options: [.regularExpression, .caseInsensitive])
        // Collapse 3+ consecutive newlines → one blank line; preserve intentional structure (bullets, paragraphs)
        result = result.replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
