import Foundation

/// Query classification for domain-specific retrieval strategies
enum QueryType {
    case countQuestion      // how many, number of, count, total
    case numericLookup      // what is the amount, price, containing digits/currency
    case dateLookup         // when, date, year, month
    case entityLookup       // who, which person/company, name
    case semantic           // default fallback
}

/// Query classifier for routing to specialized scorers
struct QueryClassifier {
    
    /// Classify query to determine appropriate retrieval strategy
    static func classifyQuery(_ question: String) -> QueryType {
        let normalized = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Count questions: "how many", "number of", "count", "total"
        if isCountQuestion(normalized) {
            return .countQuestion
        }
        
        // Date lookup: temporal keywords and date patterns
        if isDateLookup(normalized) {
            return .dateLookup
        }
        
        // Entity lookup: who, which person/company
        if isEntityLookup(normalized) {
            return .entityLookup
        }
        
        // Numeric lookup: amounts, prices, numbers (but not count questions)
        if isNumericLookup(normalized) {
            return .numericLookup
        }
        
        // Default: semantic matching
        return .semantic
    }
    
    /// Create appropriate scorer for query type
    static func makeScorerFor(_ type: QueryType) -> QueryScorer {
        switch type {
        case .countQuestion:
            return CountQuestionScorer()
        case .numericLookup:
            return NumericLookupScorer()
        case .dateLookup:
            return DateLookupScorer()
        case .entityLookup:
            return EntityLookupScorer()
        case .semantic:
            return SemanticScorer()
        }
    }
    
    // MARK: - Classification Helpers
    
    private static func isCountQuestion(_ text: String) -> Bool {
        let countPatterns = [
            "how many", "how much", "number of", "count of",
            "total number", "total count", "how often"
        ]
        
        for pattern in countPatterns {
            if text.contains(pattern) {
                return true
            }
        }
        
        // Check for standalone "count" or "total" at start of question
        let words = text.split(separator: " ")
        if let firstWord = words.first {
            if firstWord == "count" || firstWord == "total" {
                return true
            }
        }
        
        return false
    }
    
    private static func isDateLookup(_ text: String) -> Bool {
        let dateKeywords = [
            "when", "date", "year", "month", "day",
            "time", "period", "deadline", "expiration",
            "expires", "issued", "valid until", "born", "died"
        ]
        
        for keyword in dateKeywords {
            if text.contains(keyword) {
                return true
            }
        }
        
        // Check for date patterns (YYYY, MM/DD/YYYY, etc.)
        let datePattern = #"\b(19|20)\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b|\b\d{1,2}-\d{1,2}-\d{2,4}\b"#
        if text.range(of: datePattern, options: .regularExpression) != nil {
            return true
        }
        
        return false
    }
    
    private static func isEntityLookup(_ text: String) -> Bool {
        let entityKeywords = [
            "who", "whose", "person", "people", "name",
            "company", "organization", "employer", "employee",
            "doctor", "patient", "customer", "client", "vendor"
        ]
        
        for keyword in entityKeywords {
            if text.contains(keyword) {
                return true
            }
        }
        
        // Check for "which [entity]" pattern
        if text.contains("which") {
            let entityTypes = ["person", "company", "doctor", "lawyer", "organization"]
            for entityType in entityTypes {
                if text.contains(entityType) {
                    return true
                }
            }
        }
        
        return false
    }
    
    private static func isNumericLookup(_ text: String) -> Bool {
        let numericKeywords = [
            "amount", "price", "cost", "salary", "payment",
            "balance", "total", "sum", "value", "worth",
            "income", "expense", "revenue", "profit"
        ]
        
        for keyword in numericKeywords {
            if text.contains(keyword) {
                return true
            }
        }
        
        // Check for currency symbols or numeric patterns
        let currencyPattern = #"[\$£€¥₹]|\d+[.,]\d+|^\d+"#
        if text.range(of: currencyPattern, options: .regularExpression) != nil {
            return true
        }
        
        return false
    }
}

// MARK: - Query Scorer Protocol

protocol QueryScorer {
    func score(
        normalizedBM25: Double,
        exactMatchScore: Double,
        chunkText: String,
        question: String
    ) -> Double
}

// MARK: - Specialized Scorers

/// Scorer for count questions - boosts chunks with tables, lists, numeric data
struct CountQuestionScorer: QueryScorer {
    func score(
        normalizedBM25: Double,
        exactMatchScore: Double,
        chunkText: String,
        question: String
    ) -> Double {
        var score = 0.7 * normalizedBM25 + 0.25 * exactMatchScore
        
        // Boost chunks with numeric content
        if hasNumericContent(chunkText) {
            score += 0.15
        }
        
        // Boost chunks with list/table structure
        if hasStructuredData(chunkText) {
            score += 0.20
        }
        
        return score
    }
    
    private func hasNumericContent(_ text: String) -> Bool {
        let digitCount = text.filter { $0.isNumber }.count
        return digitCount > 3 // At least a few digits
    }
    
    private func hasStructuredData(_ text: String) -> Bool {
        // Check for list markers or table-like patterns
        let listMarkers = text.components(separatedBy: .newlines)
            .filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return trimmed.hasPrefix("•") || trimmed.hasPrefix("-") || 
                       trimmed.hasPrefix("*") || trimmed.range(of: #"^\d+\."#, options: .regularExpression) != nil
            }
        
        return listMarkers.count >= 2
    }
}

/// Scorer for numeric lookups - exact match on numbers + adjacent context
struct NumericLookupScorer: QueryScorer {
    func score(
        normalizedBM25: Double,
        exactMatchScore: Double,
        chunkText: String,
        question: String
    ) -> Double {
        var score = 0.5 * normalizedBM25 + 0.4 * exactMatchScore
        
        // Extract numbers from question
        let questionNumbers = extractNumbers(from: question)
        let chunkNumbers = extractNumbers(from: chunkText)
        
        // Boost if chunk contains any of the query numbers
        if !questionNumbers.isEmpty {
            for qNum in questionNumbers {
                if chunkNumbers.contains(qNum) {
                    score += 0.30
                    break
                }
            }
        }
        
        // Boost chunks with currency symbols
        if hasCurrencySymbols(chunkText) {
            score += 0.10
        }
        
        return score
    }
    
    private func extractNumbers(from text: String) -> Set<String> {
        let pattern = #"\d+(?:[.,]\d+)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        
        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, range: range)
        
        var numbers = Set<String>()
        for match in matches {
            if let range = Range(match.range, in: text) {
                numbers.insert(String(text[range]))
            }
        }
        return numbers
    }
    
    private func hasCurrencySymbols(_ text: String) -> Bool {
        let currencySymbols = ["$", "£", "€", "¥", "₹", "USD", "EUR", "GBP"]
        return currencySymbols.contains { text.contains($0) }
    }
}

/// Scorer for date lookups - date pattern matching + temporal keywords
struct DateLookupScorer: QueryScorer {
    func score(
        normalizedBM25: Double,
        exactMatchScore: Double,
        chunkText: String,
        question: String
    ) -> Double {
        var score = 0.6 * normalizedBM25 + 0.3 * exactMatchScore
        
        // Boost chunks with date patterns
        if hasDatePattern(chunkText) {
            score += 0.25
        }
        
        // Boost chunks with temporal keywords
        if hasTemporalKeywords(chunkText) {
            score += 0.10
        }
        
        return score
    }
    
    private func hasDatePattern(_ text: String) -> Bool {
        // Common date patterns: YYYY, MM/DD/YYYY, DD-MM-YYYY, Month DD, YYYY
        let datePatterns = [
            #"\b(19|20)\d{2}\b"#,                    // Year
            #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,         // MM/DD/YYYY
            #"\b\d{1,2}-\d{1,2}-\d{2,4}\b"#,         // DD-MM-YYYY
            #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\s+\d{1,2}"# // Month DD
        ]
        
        for pattern in datePatterns {
            if text.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }
    
    private func hasTemporalKeywords(_ text: String) -> Bool {
        let keywords = ["expires", "issued", "valid", "deadline", "born", "died", "date", "year"]
        let lowercased = text.lowercased()
        return keywords.contains { lowercased.contains($0) }
    }
}

/// Scorer for entity lookups - boost proper nouns and capitalized sequences
struct EntityLookupScorer: QueryScorer {
    func score(
        normalizedBM25: Double,
        exactMatchScore: Double,
        chunkText: String,
        question: String
    ) -> Double {
        var score = 0.65 * normalizedBM25 + 0.30 * exactMatchScore
        
        // Boost chunks with capitalized sequences (likely names)
        if hasProperNouns(chunkText) {
            score += 0.15
        }
        
        // Boost if chunk contains specific entity markers
        if hasEntityMarkers(chunkText) {
            score += 0.10
        }
        
        return score
    }
    
    private func hasProperNouns(_ text: String) -> Bool {
        // Look for sequences of capitalized words (potential names)
        let pattern = #"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }
    
    private func hasEntityMarkers(_ text: String) -> Bool {
        let markers = ["Dr.", "Mr.", "Mrs.", "Ms.", "Inc.", "LLC", "Corp.", "Ltd."]
        return markers.contains { text.contains($0) }
    }
}

/// Default semantic scorer - standard BM25 + exact match
struct SemanticScorer: QueryScorer {
    func score(
        normalizedBM25: Double,
        exactMatchScore: Double,
        chunkText: String,
        question: String
    ) -> Double {
        // Standard simplified scoring
        return 0.70 * normalizedBM25 + 0.25 * exactMatchScore
    }
}
