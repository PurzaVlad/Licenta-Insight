import Foundation

struct ExtractedFact {
    let label: String
    let value: String
}

struct ExtractedFacts {
    let facts: [ExtractedFact]
    var isEmpty: Bool { facts.isEmpty }

    func formatted() -> String {
        facts.map { "- \($0.label): \($0.value)" }.joined(separator: "\n")
    }
}

/// Deterministic fact extraction using regex patterns on full document text.
/// Runs before the LLM summarization step to guarantee key facts appear in the prompt
/// even if they fall outside the zone-sampled content window.
enum FactExtractorService {

    private static let maxFacts = 20

    static func extract(from text: String) -> ExtractedFacts {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ExtractedFacts(facts: [])
        }

        var facts: [ExtractedFact] = []
        facts += extractLabeledDates(from: text)
        facts += extractMonetaryAmounts(from: text)
        facts += extractPercentages(from: text)
        facts += extractReferenceIDs(from: text)
        facts += extractKeyValuePairs(from: text, alreadyCaptured: facts)
        facts += extractParties(from: text)
        facts += extractKeySentences(from: text, maxCount: 5)

        let deduped = deduplicate(facts)
        return ExtractedFacts(facts: Array(deduped.prefix(maxFacts)))
    }

    // MARK: - Pattern 1: Labeled Dates

    private static func extractLabeledDates(from text: String) -> [ExtractedFact] {
        let keywords = "Effective|Signing|Expiry|Expiration|Due|Issue|Issued|Start|End|" +
                       "Maturity|Term|Valid|Commencement|Execution|Delivery|Payment|Review|" +
                       "Renewal|Filing|Closing|Service|Treatment|Prescription|Birth|DOB|" +
                       "Hire|Termination|Notice|Completion|Settlement"

        let monthNames = "Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?" +
                         "|Jul(?:y)?|Aug(?:ust)?|Sep(?:tember)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?"

        let dateFragment = "(?:" +
            "\\d{1,2}[/\\-\\.]\\d{1,2}[/\\-\\.]\\d{2,4}" +                        // 01/05/2024
            "|\\d{4}[/\\-\\.]\\d{1,2}[/\\-\\.]\\d{1,2}" +                          // 2024-01-05
            "|(?:\(monthNames))\\.?\\s+\\d{1,2}(?:st|nd|rd|th)?,?\\s+\\d{4}" +    // January 5, 2024
            "|\\d{1,2}(?:st|nd|rd|th)?\\s+(?:\(monthNames))\\.?\\s+\\d{4}" +      // 5th January 2024
            ")"

        let pattern = "(\(keywords))(\\s+Date)?\\s*[:\\-\\u2013\\u2014]\\s*(\(dateFragment))"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var seen = Set<String>()
        return matches.compactMap { match -> ExtractedFact? in
            guard match.numberOfRanges >= 4,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let dateRange = Range(match.range(at: 3), in: text) else { return nil }

            let keyword = String(text[keyRange])
            let dateValue = String(text[dateRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = dateValue.lowercased()

            guard !seen.contains(normalized) else { return nil }
            seen.insert(normalized)

            let base = keyword.prefix(1).uppercased() + keyword.dropFirst().lowercased()
            let label = base.hasSuffix("date") || base.hasSuffix("Date") ? base : "\(base) Date"
            return ExtractedFact(label: label, value: dateValue)
        }
    }

    // MARK: - Pattern 2: Monetary Amounts

    private static func extractMonetaryAmounts(from text: String) -> [ExtractedFact] {
        let pattern = "[$€£¥₹]\\s*[\\d,]+(?:\\.\\d{1,2})?\\s*[KMBkmb]?" +
                      "|[\\d,]+(?:\\.\\d{1,2})?\\s*(?:dollars?|euros?|pounds?|USD|EUR|GBP|CAD|AUD)\\b"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var results: [ExtractedFact] = []
        var seen = Set<String>()

        for match in matches {
            guard results.count < 4,
                  let r = Range(match.range, in: text) else { continue }

            let value = String(text[r])
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let normalized = value.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let lookback = lookbackContext(in: text, before: r.lowerBound, maxChars: 40)
            let label = extractTrailingLabel(from: lookback) ?? "Amount"

            results.append(ExtractedFact(label: label, value: value))
        }

        return results
    }

    // MARK: - Pattern 3: Percentages

    private static func extractPercentages(from text: String) -> [ExtractedFact] {
        let pattern = "(\\d+(?:\\.\\d{1,2})?)\\s*%"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var results: [ExtractedFact] = []
        var seen = Set<String>()

        for match in matches {
            guard results.count < 3,
                  let r = Range(match.range, in: text) else { continue }

            let value = String(text[r]).trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = value.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let lookback = lookbackContext(in: text, before: r.lowerBound, maxChars: 40)
            let label = extractTrailingLabel(from: lookback) ?? "Rate"

            results.append(ExtractedFact(label: label, value: value))
        }

        return results
    }

    // MARK: - Pattern 4: Reference IDs

    private static func extractReferenceIDs(from text: String) -> [ExtractedFact] {
        let prefixes = "Invoice|Contract|Case|Order|Policy|Claim|Reference|Agreement|" +
                       "Patient|Account|Employee|Student|File|Permit|License|Registration|" +
                       "Certificate|Application|Report|Proposal"

        let pattern = "(\(prefixes))\\s*(?:No\\.?|#|Number|ID|Ref\\.?|Code)?\\s*([A-Z0-9][\\w\\-]{1,30})"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var results: [ExtractedFact] = []
        var seen = Set<String>()

        for match in matches {
            guard results.count < 3,
                  match.numberOfRanges >= 3,
                  let labelRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else { continue }

            let labelStr = String(text[labelRange])
            let valueStr = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Reject pure short numerics (likely page numbers)
            if let _ = Int(valueStr), valueStr.count < 4 { continue }

            let normalized = valueStr.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            let base = labelStr.prefix(1).uppercased() + labelStr.dropFirst().lowercased()
            results.append(ExtractedFact(label: "\(base) ID", value: valueStr))
        }

        return results
    }

    // MARK: - Pattern 5: Key-Value Pairs

    private static func extractKeyValuePairs(from text: String, alreadyCaptured: [ExtractedFact]) -> [ExtractedFact] {
        // Only scan first 6K chars — form fields appear near the top of documents
        let searchText = String(text.prefix(6_000))
        let lines = searchText.components(separatedBy: .newlines)

        let capturedValues = Set(alreadyCaptured.map { $0.value.lowercased() })

        var results: [ExtractedFact] = []
        guard let labelPattern = try? NSRegularExpression(
            pattern: "^([A-Z][A-Za-z ]{2,30}):\\s{1,4}(\\S.{0,80})$",
            options: []
        ) else { return [] }

        for line in lines {
            guard results.count < 6 else { break }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > 4 else { continue }

            let nsLine = trimmed as NSString
            let range = NSRange(location: 0, length: nsLine.length)

            guard let match = labelPattern.firstMatch(in: trimmed, options: [], range: range),
                  match.numberOfRanges >= 3,
                  let labelRange = Range(match.range(at: 1), in: trimmed),
                  let valueRange = Range(match.range(at: 2), in: trimmed) else { continue }

            let label = String(trimmed[labelRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            let value = String(trimmed[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Label must not contain digits
            guard label.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            // Value must be substantive
            guard value.count >= 2, value != "N/A", value != "TBD", value != "n/a" else { continue }
            // Skip if already captured by a more specific pattern
            guard !capturedValues.contains(value.lowercased()) else { continue }

            results.append(ExtractedFact(label: label, value: value))
        }

        return results
    }

    // MARK: - Pattern 6: Parties / Signatories

    private static func extractParties(from text: String) -> [ExtractedFact] {
        let pattern = "(?:between|by and between|undersigned|signed by|" +
                      "party of the first part|party of the second part|parties?[:\\s])" +
                      "\\s*([A-Z][a-zA-Z\\s\\.\\,\\(\\)]{3,60})(?=[,\\n]|$)"

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))

        var results: [ExtractedFact] = []
        var seen = Set<String>()

        for match in matches {
            guard results.count < 4,
                  match.numberOfRanges >= 2,
                  let valueRange = Range(match.range(at: 1), in: text) else { continue }

            let value = String(text[valueRange])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: ",;"))
                .trimmingCharacters(in: .whitespaces)

            guard value.count >= 4 else { continue }
            let normalized = value.lowercased()
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)

            results.append(ExtractedFact(label: "Party", value: value))
        }

        return results
    }

    // MARK: - Pattern 7: Key Sentences

    /// Scores sentences by information density and position, returning the top N as key-point facts.
    /// Captures qualitative content that the structured extractors miss (clauses, obligations, scope).
    private static func extractKeySentences(from text: String, maxCount: Int) -> [ExtractedFact] {
        let window = String(text.prefix(8_000))
        let sentences = splitIntoSentences(window)

        let stopwords: Set<String> = [
            "the","and","for","are","but","not","you","all","can","was","has","had",
            "its","our","any","may","shall","will","with","from","that","this","have",
            "been","were","they","their","about","would","could","should","which",
            "there","these","those","more","some","than","into","also","when","what",
            "each","after","before","where","such","even","here","then","both","same",
            "most","other","while","under","over","between","through","against","during",
            "without","within","along","following","across","however","therefore",
            "whereas","although","whether","provided","including","regarding","concerning",
            "pursuant","thereof","herein","said","above","below","hereby","hereunder"
        ]

        struct Scored {
            let index: Int
            let sentence: String
            let score: Double
        }

        var scored: [Scored] = []
        for (i, raw) in sentences.enumerated() {
            let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.count >= 40, s.count <= 280 else { continue }
            // Skip ALL-CAPS headings
            if s.count < 70 && s == s.uppercased() { continue }
            // Require at least 40% letter content (filters table rows, bare key-value lines)
            let alphaCount = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard Double(alphaCount) / Double(s.count) > 0.40 else { continue }

            let words = s.lowercased()
                .components(separatedBy: CharacterSet.letters.inverted)
                .filter { $0.count >= 3 }
            let contentWords = words.filter { !stopwords.contains($0) }
            let contentDensity = words.isEmpty ? 0.0 : Double(contentWords.count) / Double(words.count)

            // Count mid-sentence capitalized tokens — proxy for named entities / proper nouns
            let tokens = s.components(separatedBy: " ")
            let properNouns = tokens.dropFirst().filter { tok in
                guard let first = tok.unicodeScalars.first else { return false }
                return CharacterSet.uppercaseLetters.contains(first) && tok.count >= 2
            }.count

            // Earlier sentences carry more document-level weight
            let positionRatio = Double(i) / Double(max(1, sentences.count))
            let positionWeight = positionRatio < 0.35 ? 1.4 : (positionRatio < 0.65 ? 1.0 : 0.75)

            let lengthBonus: Double = (s.count >= 50 && s.count <= 200) ? 1.2 : 1.0

            let score = (contentDensity * 3.0 + Double(properNouns) * 0.5) * positionWeight * lengthBonus
            scored.append(Scored(index: i, sentence: s, score: score))
        }

        // Pick top N by score; re-sort by original order so output reads naturally
        let top = scored
            .sorted { $0.score > $1.score }
            .prefix(maxCount)
            .sorted { $0.index < $1.index }

        return top.map { ExtractedFact(label: "Key Point", value: $0.sentence) }
    }

    private static func splitIntoSentences(_ text: String) -> [String] {
        var results: [String] = []
        let sentenceRe = try? NSRegularExpression(pattern: "(?<=[.!?])\\s+(?=[A-Z])", options: [])
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let re = sentenceRe else { results.append(trimmed); continue }

            let ns = trimmed as NSString
            let fullRange = NSRange(location: 0, length: ns.length)
            var prev = 0
            for match in re.matches(in: trimmed, options: [], range: fullRange) {
                let end = match.range.location
                if end > prev {
                    results.append(String(ns.substring(with: NSRange(location: prev, length: end - prev))))
                }
                prev = match.range.location + match.range.length
            }
            if prev < ns.length {
                results.append(String(ns.substring(from: prev)))
            }
        }
        return results
    }

    // MARK: - Deduplication

    private static func deduplicate(_ facts: [ExtractedFact]) -> [ExtractedFact] {
        var seen = Set<String>()
        var result: [ExtractedFact] = []

        for fact in facts {
            let key = fact.value
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !key.isEmpty,
                  key != "n/a",
                  key != "tbd",
                  key.count >= 2,
                  !seen.contains(key) else { continue }

            seen.insert(key)
            result.append(fact)
        }

        return result
    }

    // MARK: - Helpers

    private static func lookbackContext(in text: String, before index: String.Index, maxChars: Int) -> String {
        let start = text.index(index, offsetBy: -min(maxChars, text.distance(from: text.startIndex, to: index)), limitedBy: text.startIndex) ?? text.startIndex
        return String(text[start..<index])
    }

    /// Extracts a trailing capitalized word group from a lookback string to use as a fact label.
    private static func extractTrailingLabel(from text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "([A-Z][A-Za-z ]{1,25})\\s*$", options: []),
              let match = regex.firstMatch(in: text, options: [], range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }

        let candidate = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
        return candidate.isEmpty ? nil : candidate
    }
}
