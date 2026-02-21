import Foundation

/// Query classification for retrieval strategy routing
enum QueryType {
    case countQuestion  // how many, number of, count of
    case numericLookup  // query contains digits or currency symbols
    case dateLookup     // when, date, year, month, day
    case entityLookup   // who, whose
    case semantic       // default fallback
}

struct QueryClassifier {

    static func classifyQuery(_ question: String) -> QueryType {
        let normalized = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if isCountQuestion(normalized) { return .countQuestion }
        if isDateLookup(normalized)    { return .dateLookup }
        if isEntityLookup(normalized)  { return .entityLookup }
        if isNumericLookup(normalized) { return .numericLookup }
        return .semantic
    }

    static func makeScorerFor(_ type: QueryType) -> QueryScorer {
        switch type {
        case .countQuestion: return CountQuestionScorer()
        case .numericLookup: return NumericLookupScorer()
        case .dateLookup:    return DateLookupScorer()
        case .entityLookup:  return EntityLookupScorer()
        case .semantic:      return SemanticScorer()
        }
    }

    // MARK: - Classification (structure-only, no domain vocabulary)

    private static func isCountQuestion(_ text: String) -> Bool {
        let patterns = ["how many", "how much", "number of", "count of",
                        "total number", "total count", "how often"]
        if patterns.contains(where: { text.contains($0) }) { return true }
        if text.split(separator: " ").first == "count" { return true }
        return false
    }

    private static func isDateLookup(_ text: String) -> Bool {
        let keywords = ["when", "date", "year", "month", "day", "time", "period"]
        if keywords.contains(where: { text.contains($0) }) { return true }
        let pattern = #"\b(19|20)\d{2}\b|\b\d{1,2}/\d{1,2}/\d{2,4}\b|\b\d{1,2}-\d{1,2}-\d{2,4}\b"#
        return text.range(of: pattern, options: .regularExpression) != nil
    }

    private static func isEntityLookup(_ text: String) -> Bool {
        text.hasPrefix("who ") || text.hasPrefix("whose ") ||
        text == "who" || text == "whose"
    }

    private static func isNumericLookup(_ text: String) -> Bool {
        let pattern = #"[\$£€¥₹]|\d+[.,]\d+|\b\d+"#
        return text.range(of: pattern, options: .regularExpression) != nil
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

// MARK: - Scorers (boost based on chunk structure, not domain vocabulary)

/// Boosts chunks that contain numeric content or list/table structure.
struct CountQuestionScorer: QueryScorer {
    func score(normalizedBM25: Double, exactMatchScore: Double, chunkText: String, question: String) -> Double {
        var score = 0.7 * normalizedBM25 + 0.25 * exactMatchScore
        if chunkText.filter({ $0.isNumber }).count > 3 { score += 0.15 }
        if hasStructuredData(chunkText) { score += 0.20 }
        return score
    }

    private func hasStructuredData(_ text: String) -> Bool {
        let listLines = text.components(separatedBy: .newlines).filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("•") || t.hasPrefix("-") || t.hasPrefix("*") ||
                   t.range(of: #"^\d+\."#, options: .regularExpression) != nil
        }
        return listLines.count >= 2
    }
}

/// Boosts chunks that contain numbers or currency symbols appearing in the query.
struct NumericLookupScorer: QueryScorer {
    func score(normalizedBM25: Double, exactMatchScore: Double, chunkText: String, question: String) -> Double {
        var score = 0.5 * normalizedBM25 + 0.4 * exactMatchScore
        let qNums = extractNumbers(from: question)
        if !qNums.isEmpty, !qNums.isDisjoint(with: extractNumbers(from: chunkText)) {
            score += 0.30
        }
        if ["$", "£", "€", "¥", "₹"].contains(where: { chunkText.contains($0) }) {
            score += 0.10
        }
        return score
    }

    private func extractNumbers(from text: String) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: #"\d+(?:[.,]\d+)?"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return Set(regex.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        })
    }
}

/// Boosts chunks that contain date patterns or generic temporal keywords.
struct DateLookupScorer: QueryScorer {
    func score(normalizedBM25: Double, exactMatchScore: Double, chunkText: String, question: String) -> Double {
        var score = 0.6 * normalizedBM25 + 0.3 * exactMatchScore
        if hasDatePattern(chunkText) { score += 0.25 }
        if hasTemporalKeywords(chunkText) { score += 0.10 }
        return score
    }

    private func hasDatePattern(_ text: String) -> Bool {
        let patterns = [
            #"\b(19|20)\d{2}\b"#,
            #"\b\d{1,2}/\d{1,2}/\d{2,4}\b"#,
            #"\b\d{1,2}-\d{1,2}-\d{2,4}\b"#,
            #"\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\w*\s+\d{1,2}"#
        ]
        return patterns.contains { text.range(of: $0, options: .regularExpression) != nil }
    }

    private func hasTemporalKeywords(_ text: String) -> Bool {
        let lower = text.lowercased()
        return ["date", "year", "month", "day", "time", "period"].contains { lower.contains($0) }
    }
}

/// Boosts chunks containing sequences of capitalized words (proper nouns).
struct EntityLookupScorer: QueryScorer {
    func score(normalizedBM25: Double, exactMatchScore: Double, chunkText: String, question: String) -> Double {
        var score = 0.65 * normalizedBM25 + 0.30 * exactMatchScore
        if chunkText.range(of: #"\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)+\b"#, options: .regularExpression) != nil {
            score += 0.15
        }
        return score
    }
}

/// Default: standard BM25 + exact match weighting.
struct SemanticScorer: QueryScorer {
    func score(normalizedBM25: Double, exactMatchScore: Double, chunkText: String, question: String) -> Double {
        0.70 * normalizedBM25 + 0.25 * exactMatchScore
    }
}
