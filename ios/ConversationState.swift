import Foundation

// Protocol for documents to avoid circular dependencies
protocol ConversationDocument {
    var id: UUID { get }
    var title: String { get }
}

class ConversationState {
    // Topic stack: tracks last N referenced documents for multi-turn context
    struct TopicEntry {
        let documentId: UUID
        let documentTitle: String
        let keyTerms: [String]
        let timestamp: Date
    }

    private let maxTopicStackSize = 3

    var topicStack: [TopicEntry] = []
    var activeEntities: [String: String] = [:]  // e.g., ["invoice": "INV-2024-001"]
    var lastRewrittenQuery: String?

    /// Current active document (top of stack)
    var activeDocumentId: UUID? { topicStack.first?.documentId }
    var activeDocumentTitle: String? { topicStack.first?.documentTitle }

    func update(documentId: UUID?, documentTitle: String?, assistantResponse: String) {
        if let id = documentId, let title = documentTitle {
            // Push to topic stack (remove duplicates first)
            topicStack.removeAll { $0.documentId == id }
            let keyTerms = extractKeyTerms(from: assistantResponse)
            topicStack.insert(TopicEntry(
                documentId: id,
                documentTitle: title,
                keyTerms: keyTerms,
                timestamp: Date()
            ), at: 0)
            // Trim stack
            if topicStack.count > maxTopicStackSize {
                topicStack = Array(topicStack.prefix(maxTopicStackSize))
            }
        }
        // Extract entities from response
        updateEntities(from: assistantResponse, documentTitle: documentTitle)
    }

    func reset() {
        topicStack.removeAll()
        activeEntities.removeAll()
        lastRewrittenQuery = nil
    }

    /// Extract key terms from response for topic tracking
    private func extractKeyTerms(from text: String) -> [String] {
        let words = text.lowercased()
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
            .filter { $0.count >= 4 }

        let stopwords: Set<String> = [
            "that", "this", "with", "from", "have", "been", "were", "they",
            "their", "about", "would", "could", "should", "which", "there",
            "these", "those", "your", "more", "some", "than", "into", "also"
        ]

        var seen = Set<String>()
        return words.filter { word in
            !stopwords.contains(word) && seen.insert(word).inserted
        }.prefix(8).map { $0 }
    }

    private func updateEntities(from text: String, documentTitle: String?) {
        let entityPattern = "\\b[A-Z]{2,4}-\\d+\\b"
        if let entity = text.firstMatch(of: entityPattern) {
            let entityStr = String(entity)
            if let prefix = entityStr.split(separator: "-").first {
                activeEntities[String(prefix).lowercased()] = entityStr
            }
        }

        if let title = documentTitle {
            activeEntities["document"] = title
        }
    }
}

extension String {
    func matches(of pattern: String) -> [Substring] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        let matches = regex.matches(in: self, range: range)
        return matches.compactMap { match in
            Range(match.range, in: self).map { self[$0] }
        }
    }

    func firstMatch(of pattern: String) -> Substring? {
        matches(of: pattern).first
    }
}
