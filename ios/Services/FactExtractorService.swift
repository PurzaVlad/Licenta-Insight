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

/// Statistical sentence scoring — selects high-information sentences as key facts.
/// Runs before LLM summarization to guarantee representative content appears in the prompt.
enum FactExtractorService {

    private static let maxFacts = 8

    static func extract(from text: String) -> ExtractedFacts {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ExtractedFacts(facts: [])
        }
        return ExtractedFacts(facts: extractKeySentences(from: text, maxCount: maxFacts))
    }

    // MARK: - Key Sentence Extraction

    private static func extractKeySentences(from text: String, maxCount: Int) -> [ExtractedFact] {
        let window = String(text.prefix(14_000))
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
            guard s.count >= 25, s.count <= 280 else { continue }
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
            let positionWeight = positionRatio < 0.35 ? 1.2 : (positionRatio < 0.65 ? 1.0 : 0.75)

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
}
