import Foundation

enum SummaryLength: String, CaseIterable {
    case short
    case medium
    case long
}

class AIService {
    static let shared = AIService()

    private let ocrService = OCRService.shared

    // Tag generation constants
    private static let tagStopwords: Set<String> = [
        "a", "an", "and", "or", "the", "of", "to", "in", "on", "at", "by", "for", "from", "with", "without",
        "into", "onto", "about", "over", "under", "through", "between", "among", "is", "are", "was", "were",
        "be", "been", "being", "this", "that", "these", "those", "it", "its", "their", "they", "them", "you",
        "your", "our", "ours", "we", "i", "me", "my", "as", "if", "then", "else", "not", "can", "could",
        "would", "should", "will", "including", "include", "includes", "using", "used", "use", "other", "etc"
    ]

    private static let defaultTagFallbacks: [String] = ["document", "content", "details", "reference"]

    private init() {}

    // MARK: - Summary Generation

    /// Builds a summary prompt for a document
    func buildSummaryPrompt(for document: Document, length: SummaryLength = .medium) -> String {
        var ocr = ""
        if let pages = document.ocrPages, !pages.isEmpty {
            let ocrText = ocrService.buildStructuredText(from: pages, includePageLabels: true)
            if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                ocr = ocrText
            }
        }
        if ocr.isEmpty {
            ocr = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let truncatedOCR = String(ocr.prefix(20000))
        return buildSummaryPrompt(input: truncatedOCR, length: length)
    }

    private func buildSummaryPrompt(input: String, length: SummaryLength) -> String {
        """
        Document:
        \(input)

        Write a \(lengthDescription(length)) summary of the above document:
        """
    }

    private func lengthDescription(_ length: SummaryLength) -> String {
        switch length {
        case .short: return "brief"
        case .medium: return "concise"
        case .long: return "detailed"
        }
    }

    // MARK: - Tag Generation

    /// Builds a tag generation prompt for a document
    func buildTagPrompt(for document: Document) -> (prompt: String, seed: String) {
        var seed = ""
        if let pages = document.ocrPages, !pages.isEmpty {
            let ocrText = ocrService.buildStructuredText(from: pages, includePageLabels: false)
            if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                seed = ocrText
            }
        }
        if seed.isEmpty {
            seed = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let snippet = String(seed.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)

        let prompt = """
        <<<TAG_REQUEST>>>
        Extract exactly 4 single-word tags from this document excerpt.
        Output only a comma-separated list with exactly 4 items.
        Use specific topic words only.
        Do not use stopwords like: and, or, the, a, an, including, with, for.

        EXCERPT:
        \(snippet)
        """

        return (prompt, snippet)
    }

    /// Processes AI-generated tags and adds fallbacks if needed
    func processTags(rawResponse: String, document: Document, seedText: String) -> [String] {
        let category = document.category.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let sourceForFallback = "\(document.title)\n\(seedText)"

        var tags = Self.parseTags(from: rawResponse, sourceText: sourceForFallback, limit: 4)
            .filter { $0.caseInsensitiveCompare(category) != .orderedSame }

        // Add fallback tags if we don't have enough
        if tags.count < 4 {
            let existing = Set(tags.map { $0.lowercased() } + [category.lowercased()])
            let topUp = Self.extractFallbackTags(
                from: sourceForFallback,
                excluding: existing,
                limit: 4 - tags.count
            )
            tags.append(contentsOf: topUp)
        }

        // Add default fallbacks if still not enough
        if tags.count < 4 {
            var used = Set(tags.map { $0.lowercased() } + [category.lowercased()])
            for filler in Self.defaultTagFallbacks {
                if tags.count >= 4 { break }
                let key = filler.lowercased()
                if used.contains(key) { continue }
                used.insert(key)
                tags.append(filler)
            }
        }

        // Return category + top 4 tags
        return [category] + Array(tags.prefix(4))
    }

    // MARK: - Tag Parsing

    /// Parses tags from AI response text
    static func parseTags(from text: String, sourceText: String? = nil, limit: Int = 4) -> [String] {
        guard limit > 0 else { return [] }

        let cleaned = text
            .replacingOccurrences(of: "[\\[\\]\\(\\)\"'""`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9,;|\\n\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned
            .split { $0 == "," || $0 == "\n" || $0 == ";" || $0 == "|" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .compactMap { normalizeTagToken($0) }

        let deduplicated = Array(Set(parts))
        let final = deduplicated.prefix(limit).map { $0.capitalized }

        if final.isEmpty, let sourceText = sourceText {
            return extractFallbackTags(from: sourceText, excluding: [], limit: limit)
        }

        return Array(final)
    }

    /// Extracts fallback tags from source text using frequency analysis
    private static func extractFallbackTags(from source: String, excluding: Set<String>, limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        let tokens = source
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        var freq: [String: Int] = [:]
        for token in tokens {
            guard let normalized = normalizeTagToken(token) else { continue }
            if excluding.contains(normalized) { continue }
            freq[normalized, default: 0] += 1
        }

        let ranked = freq.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }

        return Array(ranked.prefix(limit).map { $0.key.capitalized })
    }

    /// Normalizes and validates a tag token
    private static func normalizeTagToken(_ raw: String) -> String? {
        let token = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard token.count >= 3 else { return nil }
        guard token.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard !tagStopwords.contains(token) else { return nil }
        return token
    }

    // MARK: - Summary Cleaning

    /// Cleans AI-generated summary output
    func cleanSummaryOutput(_ raw: String) -> String {
        return raw
            .replacingOccurrences(of: "^\\s*Summary:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "^\\s*Here is a .* summary.*:\\s*", with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
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
            // Use summary if available and meaningful, otherwise use first 500 characters
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
