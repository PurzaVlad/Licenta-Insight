import Foundation

// Protocol for documents to avoid circular dependencies
protocol ConversationDocument {
    var id: UUID { get }
    var title: String { get }
}

class ConversationState {
    var activeDocumentId: UUID?
    var activeDocumentTitle: String?
    var activeEntities: [String: String] = [:]  // e.g., ["invoice": "INV-2024-001"]
    var lastQueryType: String?
    var lastNumericValues: [String] = []  // Track mentioned numbers
    var lastDateValues: [String] = []     // Track mentioned dates
    
    func update(documentId: UUID?, documentTitle: String?, queryType: String, assistantResponse: String) {
        if let id = documentId, let title = documentTitle {
            activeDocumentId = id
            activeDocumentTitle = title
        }
        lastQueryType = queryType
        
        // Extract numeric values from response
        lastNumericValues = extractNumbers(from: assistantResponse)
        
        // Extract dates from response
        lastDateValues = extractDates(from: assistantResponse)
        
        // Extract entities (invoice numbers, account IDs, etc.)
        updateEntities(from: assistantResponse, documentTitle: documentTitle)
    }
    
    func resolveAnaphora(in question: String) -> String {
        var resolved = question
        let lowered = question.lowercased()
        
        // "What about it?" → "What about [document title]?"
        if containsAnaphora(lowered) {
            if let title = activeDocumentTitle {
                resolved = question.replacingOccurrences(
                    of: "\\b(it|that|this|the document)\\b",
                    with: title,
                    options: .regularExpression,
                    range: nil
                )
            }
        }
        
        // "What's the total?" (follow-up) → Include context
        if isFollowUpQuery(lowered) {
            if let title = activeDocumentTitle {
                resolved = "\(question) [Context: referring to \(title)]"
            }
        }
        
        return resolved
    }
    
    func reset() {
        activeDocumentId = nil
        activeDocumentTitle = nil
        activeEntities.removeAll()
        lastQueryType = nil
        lastNumericValues.removeAll()
        lastDateValues.removeAll()
    }
    
    private func containsAnaphora(_ text: String) -> Bool {
        let pronouns = ["it", "that", "this", "those", "these", "they", "them"]
        return pronouns.contains { text.contains($0) }
    }
    
    private func isFollowUpQuery(_ text: String) -> Bool {
        // Short query with no explicit document reference
        let tokenCount = text.split(separator: " ").count
        return tokenCount <= 5 && !text.contains("in") && !text.contains("from")
    }
    
    private func extractNumbers(from text: String) -> [String] {
        let pattern = "\\b\\d+([.,]\\d+)?\\b"
        return text.matches(of: pattern).map { String($0) }
    }
    
    private func extractDates(from text: String) -> [String] {
        // Simple date extraction: YYYY-MM-DD, MM/DD/YYYY, etc.
        let pattern = "\\b\\d{4}-\\d{2}-\\d{2}\\b|\\b\\d{1,2}/\\d{1,2}/\\d{2,4}\\b"
        return text.matches(of: pattern).map { String($0) }
    }
    
    private func updateEntities(from text: String, documentTitle: String?) {
        // Extract common entity patterns (alphanumeric identifiers)
        let entityPattern = "\\b[A-Z]{2,4}-\\d+\\b"
        if let entity = text.firstMatch(of: entityPattern) {
            let entityStr = String(entity)
            // Store by prefix (e.g., "INV-123" -> prefix "INV")
            if let prefix = entityStr.split(separator: "-").first {
                activeEntities[String(prefix).lowercased()] = entityStr
            }
        }
        
        // Extract document IDs from response
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
