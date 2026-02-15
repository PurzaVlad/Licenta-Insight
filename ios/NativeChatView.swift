import SwiftUI
import Foundation
import UIKit

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "user" or "assistant"
    let text: String
    let date: Date
}

struct NativeChatView: View {
    private struct SessionState {
        var lastReferencedDocumentId: UUID?
    }

    private struct ChatLLMResult {
        let reply: String
        let primaryDocument: Document?
    }

    private struct DocumentSelectionResult {
        let documents: [Document]
        let primaryDocument: Document?
        let topScoreByDocumentId: [UUID: Double]
        let retrievalQueryUsed: String?
        let selectedHits: [ChunkHit]
        let allRankedHits: [ChunkHit]
    }

    @State private var input: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating: Bool = false
    @State private var isThinkingPulseOn: Bool = false
    @State private var activeChatGenerationId: UUID? = nil
    @State private var sessionState = SessionState()
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @State private var showingScopePicker = false
    @State private var scopedDocumentIds: Set<UUID> = []

    private let inputLineHeight: CGFloat = 22
    private let inputMinLines = 1
    private let inputMaxLines = 2
    private let inputBarMinHeight: CGFloat = 44
    @State private var inputHeight: CGFloat = 22
    private let inputMaxCornerRadius: CGFloat = 25
    private let inputMinCornerRadius: CGFloat = 12

    // Preprompt (edit this text to change assistant behavior)
    private let chatPreprompt = """
    You are a document assistant.

    Rules:
    - Answer in maximum 3 sentences.
    - Write normal sentences (no comma-separated keyword lists).
    - Do not output headings (e.g., "WORK EXPERIENCE") unless the user asked for a heading.
    - Do not repeat phrases.
    - Be concise.
    - For count questions (e.g., "how many", "number of", "count", "total"), bind numbers to the correct entity on the same line/chunk; do not use unrelated numbers.
    - If multiple numbers appear in the evidence, pick the number explicitly associated with the asked subject (same line/row/sentence), and do not invent.
    - No explanations unless asked.
    - Never include system tokens or internal markers.
    - Use only the provided context.
    - If information is not found, say only: "Not specified in the documents."
    """
    private let historyLimit = 4
    private let selectionMaxDocs = 6
    private let activeContextCharBudget = 4200
    private let folderContextCharBudget = 500
    private let minContextReserveChars = 450
    private let maxSummaryCharsPerDoc = 420
    private let maxSnippetChars = 420
    private let maxSnippetsPerDoc = 2
    private let maxOCRSnippetsPerDoc = 4
    private let useNoHistoryForChat = true
    private let defaultOCRDocCount = 3
    private let lowExtractedTextThreshold = 700
    private let semanticWeight: Double = 0.9
    private let docTypeBoostWeight: Double = 0.05
    private let tagBoostWeight: Double = 0.1
    private let titleBoostWeight: Double = 0.12
    private let exactTokenBoostWeight: Double = 0.9
    private let phraseBoostWeight: Double = 0.8
    private let numericTokenBoostWeight: Double = 1.6
    private let anchorChunkBoostWeight: Double = 0.35
    private let anchorChunkPenaltyWeight: Double = 0.15
    private let shortAcronymAnchorBoostWeight: Double = 0.35
    private let lastDocumentBiasWeight: Double = 0.08
    private let bm25Weight: Double = 0.65
    private let trigramWeight: Double = 0.35
    private let evidenceAbsoluteFloor: Double = 0.12
    private let evidenceMedianMargin: Double = 0.08
    private let evidenceGapThreshold: Double = 0.10
    private let passBTopEvidenceLimit = 12
    private let passBGatingKeywordMatchMin = 2
    private let expandedEvidenceLimit = 18

    var body: some View {
        NavigationView {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if messages.isEmpty {
                            Text("Model Ready.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 24)
                        }

                        ForEach(messages) { msg in
                            MessageRow(msg: msg)
                                .id(msg.id)
                        }

                        if isGenerating {
                            ThinkingRow(isPulseOn: $isThinkingPulseOn)
                                .id("thinking")
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 80)
                }
                .hideScrollBackground()
                .scrollDismissesKeyboardIfAvailable()
                .onChange(of: messages) { newValue in
                    if let last = newValue.last {
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .modifier(SharedSettingsSheetBackgroundModifier())
            }
            .sheet(isPresented: $showingScopePicker) {
                ScopePickerSheet(selectedIds: $scopedDocumentIds)
                    .environmentObject(documentManager)
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
        }
    }

    private var scopedDocuments: [Document] {
        scopedDocumentsForSelection()
    }

    private var isScopeActive: Bool {
        !scopedDocumentIds.isEmpty
    }

    private var inputCornerRadius: CGFloat {
        let lines = max(inputMinLines, min(inputMaxLines, Int(round(inputHeight / inputLineHeight))))
        let t = CGFloat(lines - 1) / CGFloat(max(inputMaxLines - 1, 1))
        return inputMaxCornerRadius - (inputMaxCornerRadius - inputMinCornerRadius) * t
    }

    private var inputBar: some View {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasText = !trimmed.isEmpty

        return HStack(spacing: 12) {
            Button {
                showingScopePicker = true
            } label: {
                Image(systemName: "scope")
                    .foregroundColor(isScopeActive ? .white : .primary)
                    .frame(width: 44, height: 44)
                    .background(
                        Circle()
                            .fill(isScopeActive ? Color("Primary") : (colorScheme == .light ? Color(.systemGray6) : Color.clear))
                    )
                    .shadow(
                        color: isScopeActive ? Color("Primary").opacity(0.35) : Color.black.opacity(0.15),
                        radius: isScopeActive ? 10 : 6,
                        x: 0,
                        y: isScopeActive ? 4 : 3
                    )
                    .scaleEffect(isScopeActive ? 1.03 : 1.0)
                    .animation(.easeInOut(duration: 0.18), value: isScopeActive)
            }
                    
            HStack(alignment: .center, spacing: 6) {
                Group {
                    TextField("Ask anything", text: $input, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 17))
                        .lineLimit(1...6)
                        .frame(minHeight: 24)
                        .disabled(isGenerating)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 12)
                .padding(.trailing, 6)

                Button {
                    send()
                } label: {
                    Image(systemName: isGenerating ? "stop.fill" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(!hasText && !isGenerating)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .ifAvailableiOS17CircleBorder()
                .tint(Color("Primary"))
                .frame(width: 32, height: 32)
            }
            .padding(.leading, 0)
            .padding(.trailing, 6)
            .padding(.vertical, 6)
            .frame(minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: inputCornerRadius, style: .continuous)
                    .fill(colorScheme == .light ? Color(.systemGray6) : Color.clear)
            )
            .shadow(color: Color.black.opacity(0.15), radius: 6, x: 0, y: 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private func send() {
        if isGenerating {
            stopGeneration()
            return
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        startGeneration(question: trimmed)
    }

    private func resetConversation() {
        input = ""
        messages = []
        isGenerating = false
        activeChatGenerationId = nil
    }

    private func stopGeneration() {
        guard isGenerating else { return }
        isGenerating = false
        activeChatGenerationId = nil
        EdgeAI.shared?.cancelCurrentGeneration()
    }

    private func startGeneration(question: String) {
        let generationId = UUID()
        activeChatGenerationId = generationId
        runLLMAnswer(question: question, generationId: generationId)
    }

    private func runLLMAnswer(question: String, generationId: UUID) {
        isGenerating = true

        Task {
            do {
                guard let edgeAI = EdgeAI.shared else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }

                if self.activeChatGenerationId != generationId { return }
                let result = try await callChatLLM(edgeAI: edgeAI, question: question)
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    let text = result.reply.isEmpty ? "(No response)" : result.reply
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    self.updateSessionState(from: result.primaryDocument)
                }
            } catch {
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    if error.localizedDescription != "CANCELLED" {
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: \(error.localizedDescription)", date: Date()))
                    }
                }
            }
        }
    }

    private func recentChatContext(excludingLastUser: Bool, question: String) -> String {
        let history = excludingLastUser ? Array(messages.dropLast()) : messages
        if history.isEmpty { return "None." }

        let topicShifted = isTopicShift(question: question, history: history)
        let sliceCount = topicShifted ? min(2, history.count) : min(historyLimit, history.count)
        let tail = Array(history.suffix(sliceCount))
        if tail.isEmpty { return "None." }
        return tail.map { msg in
            let role = msg.role.capitalized
            let text = cleanLine(msg.text)
            return "\(role): \(text)"
        }.joined(separator: "\n")
    }

    private func recentExchangeContext(question: String) -> String {
        let history = messages
        if history.isEmpty { return "None." }
        let topicShifted = isTopicShift(question: question, history: history)
        if topicShifted { return "None." }

        let lastUsers = history.filter { $0.role == "user" }.suffix(3)
        let lastAssistant = history.last(where: { $0.role == "assistant" })

        let userLines = lastUsers.map { cleanLine(String($0.text.prefix(220))) }
        let assistantLine = lastAssistant.map { cleanLine(String($0.text.prefix(320))) } ?? ""

        if userLines.isEmpty && assistantLine.isEmpty { return "None." }
        let usersBlock = userLines.isEmpty ? "" : userLines.enumerated().map { idx, text in
            "LastUser\(idx + 1): \(text)"
        }.joined(separator: "\n")
        let assistantBlock = assistantLine.isEmpty ? "" : "LastAssistant: \(assistantLine)"

        if usersBlock.isEmpty { return assistantBlock }
        if assistantBlock.isEmpty { return usersBlock }
        return """
        \(usersBlock)
        \(assistantBlock)
        """
    }

    private func isTopicShift(question: String, history: [ChatMessage]) -> Bool {
        guard let lastUser = history.last(where: { $0.role == "user" }) else { return true }
        let recent = cleanLine(lastUser.text)
        let qTokens = tokenSet(question)
        let rTokens = tokenSet(recent)
        if qTokens.isEmpty || rTokens.isEmpty { return false }
        let overlap = qTokens.intersection(rTokens).count
        let union = qTokens.union(rTokens).count
        if union == 0 { return false }
        let jaccard = Double(overlap) / Double(union)
        return jaccard < 0.12
    }

    private func tokenSet(_ text: String) -> Set<String> {
        let tokens = cleanLine(text)
            .lowercased()
            .split(separator: " ")
            .map(String.init)
            .filter { $0.count > 3 }
        return Set(tokens)
    }

    private func cleanLine(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func folderPathMap() -> [UUID: String] {
        let byId = Dictionary(uniqueKeysWithValues: documentManager.folders.map { ($0.id, $0) })
        var cache: [UUID: String] = [:]

        func path(for folderId: UUID) -> String {
            if let cached = cache[folderId] { return cached }
            var parts: [String] = []
            var currentId: UUID? = folderId
            var safety = 0
            while let cid = currentId, let folder = byId[cid], safety < 20 {
                parts.append(folder.name)
                currentId = folder.parentId
                safety += 1
            }
            let fullPath = parts.reversed().joined(separator: "/")
            cache[folderId] = fullPath
            return fullPath
        }

        for folder in documentManager.folders {
            _ = path(for: folder.id)
        }
        return cache
    }

    private func buildFolderIndex() -> String {
        if documentManager.folders.isEmpty { return "No folders." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        return documentManager.folders.map { folder in
            let path = pathMap[folder.id] ?? folder.name
            return """
            FolderId: \(folder.id.uuidString)
            Path: \(path)
            Created: \(formatter.string(from: folder.dateCreated))
            """
        }.joined(separator: "\n---\n")
    }

    private func buildDocumentIndex() -> String {
        let docs = documentManager.conversationEligibleDocuments()
        if docs.isEmpty { return "No documents." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        return docs.map { doc in
            let folderPath = doc.folderId.flatMap { pathMap[$0] } ?? "Root"
            return """
            DocId: \(doc.id.uuidString)
            Title: \(doc.title)
            Folder: \(folderPath)
            Tags: \(doc.tags.joined(separator: ", "))
            Date: \(formatter.string(from: doc.dateCreated))
            """
        }.joined(separator: "\n---\n")
    }

    private func buildStructuredOCRText(from pages: [OCRPage]) -> String {
        guard !pages.isEmpty else { return "" }
        var output: [String] = []
        for page in pages {
            let blocks = page.blocks.sorted { $0.order < $1.order }
            let combined = blocks.map { $0.text }.joined(separator: " ")
            output.append("Page \(page.pageIndex + 1):\n\(combined)")
        }
        return output.joined(separator: "\n\n")
    }

    private struct ChunkHit {
        let document: Document
        let chunk: OCRChunk
        let semanticScore: Double
        let docTypeMatch: Double
        let tagMatch: Double
        let titleMatch: Double
        let exactTokenMatch: Double
        let phraseMatch: Double
        let numericMatch: Double
        let finalScore: Double
    }

    private static let retrievalStopwords: Set<String> = [
        "a","an","and","or","the","of","to","in","on","for","with","without","from","at","by","as",
        "is","are","was","were","be","been","being","this","that","these","those","it","its","you",
        "your","we","our","they","their","them","i","me","my","do","does","did","can","could","should",
        "would","will","about","into","over","under","between","among","what","which","who","whom","when",
        "where","why","how","please"
    ]

    private static let anchorStopwords: Set<String> = [
        "the","a","an","and","or","to","of","for","with","in","on","at","by","from",
        "is","are","was","were","be","been","it","this","that","these","those","they","them",
        "how","what","which","who","when","where","why","anything","about"
    ]

    private func retrievalTokenArray(_ text: String) -> [String] {
        let lowered = cleanLine(text).lowercased()
        return lowered
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !Self.retrievalStopwords.contains($0) }
            .map { token in
                if token.count >= 5 && token.hasSuffix("s") {
                    return String(token.dropLast())
                }
                return token
            }
    }

    private func retrievalTokens(_ text: String) -> Set<String> {
        Set(retrievalTokenArray(text))
    }

    private func normalizedForTrigrams(_ text: String) -> String {
        cleanLine(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func characterTrigrams(for text: String) -> Set<String> {
        let normalized = normalizedForTrigrams(text)
        if normalized.isEmpty { return [] }
        if normalized.count < 3 { return [normalized] }
        let chars = Array(normalized)
        var grams = Set<String>()
        for i in 0...(chars.count - 3) {
            grams.insert(String(chars[i...(i + 2)]))
        }
        return grams
    }

    private func trigramJaccardScore(queryTrigrams: Set<String>, chunkTrigrams: Set<String>) -> Double {
        if queryTrigrams.isEmpty || chunkTrigrams.isEmpty { return 0 }
        let intersection = queryTrigrams.intersection(chunkTrigrams).count
        if intersection == 0 { return 0 }
        let union = queryTrigrams.union(chunkTrigrams).count
        return Double(intersection) / Double(max(1, union))
    }

    private struct ChunkLexicalFeatures {
        let tokens: [String]
        let tokenSet: Set<String>
        let termFreq: [String: Int]
        let length: Int
        let trigrams: Set<String>
    }

    private func buildChunkLexicalFeatures(for text: String) -> ChunkLexicalFeatures {
        let tokens = retrievalTokenArray(text)
        var termFreq: [String: Int] = [:]
        for token in tokens {
            termFreq[token, default: 0] += 1
        }
        return ChunkLexicalFeatures(
            tokens: tokens,
            tokenSet: Set(tokens),
            termFreq: termFreq,
            length: max(1, tokens.count),
            trigrams: characterTrigrams(for: text)
        )
    }

    private func bm25Score(
        queryTokens: Set<String>,
        termFreq: [String: Int],
        docLength: Int,
        documentFrequency: [String: Int],
        totalDocs: Int,
        averageDocLength: Double
    ) -> Double {
        if queryTokens.isEmpty || termFreq.isEmpty || totalDocs == 0 { return 0 }
        let k1 = 1.2
        let b = 0.75
        let avgdl = max(1.0, averageDocLength)

        var score = 0.0
        for token in queryTokens {
            let tf = Double(termFreq[token] ?? 0)
            if tf <= 0 { continue }
            let df = Double(documentFrequency[token] ?? 0)
            let n = Double(totalDocs)
            let idf = log(1.0 + ((n - df + 0.5) / (df + 0.5)))
            let denominator = tf + k1 * (1.0 - b + b * (Double(docLength) / avgdl))
            if denominator > 0 {
                score += idf * ((tf * (k1 + 1.0)) / denominator)
            }
        }

        return score
    }

    private func anchorTokens(from question: String) -> [String] {
        let rawTokens = question.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init)
        let anchors = rawTokens.filter { token in
            let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { return false }
            if isShortAcronymToken(t) { return true }
            if t.count < 5 { return false }
            if Self.anchorStopwords.contains(t.lowercased()) { return false }
            let hasUpper = t.rangeOfCharacter(from: .uppercaseLetters) != nil
            let hasDigit = t.rangeOfCharacter(from: .decimalDigits) != nil
            let hasHyphen = t.contains("-")
            let isLongDistinctive = t.count >= 6
            return hasUpper || hasDigit || hasHyphen || isLongDistinctive
        }
        var seen = Set<String>()
        return anchors.filter { seen.insert($0.lowercased()).inserted }
    }

    private func textContainsAnyAnchor(_ text: String, anchors: [String]) -> Bool {
        let lower = text.lowercased()
        return anchors.contains { anchor in
            lower.contains(anchor.lowercased())
        }
    }

    private func anchorFilteredDocuments(question: String, docs: [Document]) -> [Document] {
        let anchors = anchorTokens(from: question)
        if anchors.isEmpty { return docs }
        let filtered = docs.filter { doc in
            let contentSample = compact(doc.content, maxChars: 900)
            let rawOCRSample = doc.ocrChunks
                .prefix(2)
                .map(\.text)
                .joined(separator: " ")
            let ocrSample = compact(rawOCRSample, maxChars: 900)
            let blob = "\(doc.title) \(doc.tags.joined(separator: " ")) \(doc.summary) \(contentSample) \(ocrSample)"
            return textContainsAnyAnchor(blob, anchors: anchors)
        }
        return filtered.isEmpty ? docs : filtered
    }

    private func expandQuery(_ question: String) -> String {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return question }
        let tokens = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let hasStrongAnchor = !anchorTokens(from: question).isEmpty

        func hasAnyToken(_ terms: [String]) -> Bool {
            !tokens.intersection(Set(terms)).isEmpty
        }

        func hasAnyPhrase(_ phrases: [String]) -> Bool {
            phrases.contains { q.contains($0) }
        }

        var extras: [String] = []

        // DATE/TIME
        if hasAnyToken(["date", "start", "end", "from", "to", "period", "year", "month"]) ||
            hasAnyPhrase(["when", "effective date"]) {
            extras.append("date start end from to period year month effective")
        }

        // LOCATION
        if !hasStrongAnchor &&
            (hasAnyToken(["city", "country", "location", "based", "region", "address"]) ||
            hasAnyPhrase(["where", "based in"])) {
            extras.append("location city country region address")
        }

        // ENTITY
        if hasAnyToken(["who", "party", "person", "company", "organization", "client", "vendor", "employee", "employer"]) {
            extras.append("party person company organization client vendor employee employer")
        }

        // AMOUNT
        if hasAnyToken(["amount", "total", "price", "cost", "fee", "value", "eur", "usd", "currency"]) {
            extras.append("amount total price cost fee value eur usd currency")
        }

        // IDENTIFIER
        if hasAnyToken(["id", "identifier", "number", "reference", "ref", "code", "account", "email", "phone", "passport", "tax", "iban"]) {
            extras.append("id identifier number reference ref code account email phone passport tax")
        }

        if extras.isEmpty { return question }
        return question + "\n\nQuery hints: " + extras.joined(separator: " ")
    }

    private func predictField(for question: String) -> Document.DocumentCategory {
        DocumentManager.inferCategory(title: "", content: question, summary: question)
    }

    private func semanticOverlapScore(questionTokens: Set<String>, chunkTokens: Set<String>) -> Double {
        if questionTokens.isEmpty || chunkTokens.isEmpty { return 0 }
        let overlap = questionTokens.intersection(chunkTokens).count
        return Double(overlap) / Double(max(1, questionTokens.count))
    }

    private func normalizedMatchScore(questionTokens: Set<String>, text: String) -> Double {
        if questionTokens.isEmpty { return 0 }
        let targetTokens = retrievalTokens(text)
        if targetTokens.isEmpty { return 0 }
        let overlap = questionTokens.intersection(targetTokens).count
        return Double(overlap) / Double(max(1, questionTokens.count))
    }

    private func normalizedAlphaNumericText(_ text: String) -> String {
        let lowered = cleanLine(text).lowercased()
        let mapped = lowered.map { char -> Character in
            if char.isLetter || char.isNumber || char.isWhitespace {
                return char
            }
            return " "
        }
        return " " + String(mapped)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines) + " "
    }

    private func exactQueryTokens(from question: String) -> [String] {
        let rawTokens = cleanLine(question)
            .split { !$0.isLetter && !$0.isNumber && $0 != "-" }
            .map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for raw in rawTokens {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            let normalized = trimmed.lowercased().replacingOccurrences(of: "-", with: "")
            if normalized.isEmpty { continue }

            let isShortAcronym = isShortAcronymToken(trimmed)
            let hasDigitOrHyphen =
                trimmed.rangeOfCharacter(from: .decimalDigits) != nil ||
                trimmed.contains("-")
            let minLen = (isShortAcronym || hasDigitOrHyphen) ? 2 : 4

            if normalized.count < minLen { continue }
            if Self.retrievalStopwords.contains(normalized) { continue }

            if seen.insert(normalized).inserted {
                out.append(normalized)
            }
        }
        return out
    }

    private func isShortAcronymToken(_ token: String) -> Bool {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.count < 2 || t.count > 5 { return false }
        let lower = t.lowercased()
        if Self.anchorStopwords.contains(lower) || Self.retrievalStopwords.contains(lower) { return false }
        return t.allSatisfy { $0.isLetter }
    }

    private func exactQueryPhrases(from question: String) -> [String] {
        let source = normalizedAlphaNumericText(question)
        let words = source
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                if token.count < 2 { return false }
                if Self.retrievalStopwords.contains(token) { return false }
                return true
            }

        if words.count < 2 { return [] }
        var seen = Set<String>()
        var phrases: [String] = []

        for n in 2...3 {
            if words.count < n { continue }
            for i in 0...(words.count - n) {
                let phrase = words[i..<(i + n)].joined(separator: " ")
                if phrase.count < 6 { continue }
                if seen.insert(phrase).inserted {
                    phrases.append(phrase)
                }
            }
        }

        return phrases
    }

    private func isNumberHeavyToken(_ token: String) -> Bool {
        if token.isEmpty { return false }
        let digits = token.filter { $0.isNumber }.count
        if digits == 0 { return false }
        if digits >= 3 { return true }
        return Double(digits) / Double(max(1, token.count)) >= 0.4
    }

    private func containsExactToken(_ token: String, in normalizedText: String) -> Bool {
        normalizedText.contains(" \(token) ")
    }

    private func exactMatchScores(
        exactTokens: [String],
        phrases: [String],
        text: String
    ) -> (exactToken: Double, phrase: Double, numeric: Double) {
        if exactTokens.isEmpty && phrases.isEmpty {
            return (0, 0, 0)
        }

        let normalizedText = normalizedAlphaNumericText(text)
        var exactMatched = 0
        var numericTotal = 0
        var numericMatched = 0

        for token in exactTokens {
            let matched = containsExactToken(token, in: normalizedText)
            if matched { exactMatched += 1 }
            if isNumberHeavyToken(token) {
                numericTotal += 1
                if matched { numericMatched += 1 }
            }
        }

        var phraseMatched = 0
        for phrase in phrases {
            if normalizedText.contains(" \(phrase) ") {
                phraseMatched += 1
            }
        }

        let exactScore = exactTokens.isEmpty ? 0 : Double(exactMatched) / Double(exactTokens.count)
        let phraseScore = phrases.isEmpty ? 0 : Double(phraseMatched) / Double(phrases.count)
        let numericScore = numericTotal == 0 ? 0 : Double(numericMatched) / Double(numericTotal)
        return (exactScore, phraseScore, numericScore)
    }

    private func isAnaphoraFollowUp(_ q: String) -> Bool {
        let s = q.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let tok = s.split { !$0.isLetter && !$0.isNumber }.count
        if tok > 10 { return false }

        let cues = [
            "which", "what", "when", "where", "who", "why", "how",
            "those", "that", "these", "this", "they", "them", "it", "there"
        ]
        return cues.contains(where: { s.contains($0) })
    }

    private func compact(_ text: String, maxChars: Int) -> String {
        let t = cleanLine(text)
        if t.count <= maxChars { return t }
        return String(t.prefix(maxChars))
    }

    private func makeThreadAnchor(history: [ChatMessage]) -> String? {
        // Get last user+assistant pair
        guard let lastAssistantIdx = history.lastIndex(where: { $0.role == "assistant" }) else { return nil }
        let lastAssistant = history[lastAssistantIdx].text
        let lastUser = history[..<lastAssistantIdx].last(where: { $0.role == "user" })?.text ?? ""

        let u = compact(lastUser, maxChars: 140)
        let a = compact(lastAssistant, maxChars: 180)

        if u.isEmpty && a.isEmpty { return nil }
        return "Thread context:\nUser: \(u)\nAssistant: \(a)\n\n"
    }

    private func isLowSignalChitChat(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return true }

        let normalized = q
            .replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let chit = ["hi", "hello", "hey", "thanks", "thank you", "ok", "okay", "are you ok", "you ok", "sup", "yo"]
        if chit.contains(normalized) { return true }

        if normalized.split(separator: " ").count <= 4,
           chit.contains(where: { normalized.hasPrefix($0 + " ") || normalized.hasSuffix(" " + $0) }) {
            return true
        }

        let tokens = retrievalTokens(question)
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        return tokens.isEmpty && exactTokens.isEmpty && phrases.isEmpty
    }

    private func isExplicitSmallTalkPrompt(_ question: String) -> Bool {
        let normalized = cleanLine(question).lowercased()
        if normalized.isEmpty { return false }

        let direct = [
            "hi", "hello", "hey", "thanks", "thank you", "ok", "okay",
            "how are you", "how are you doing", "are you ok", "you ok", "sup", "yo"
        ]
        if direct.contains(normalized) { return true }

        // Emoji-only / symbol-only prompt with no letters or numbers.
        let hasAlphaNum = normalized.contains { $0.isLetter || $0.isNumber }
        if !hasAlphaNum { return true }
        return false
    }

    private func isMetaDispute(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return false }

        let tokenCount = q.split { !$0.isLetter && !$0.isNumber }.count
        guard tokenCount <= 6 else { return false }

        if q.contains("check again") { return true }
        let tokens = Set(q.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        let cues: Set<String> = ["sure", "really", "yes", "no", "wrong"]
        return !tokens.intersection(cues).isEmpty
    }

    private func isChallenge(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return false }
        let cues = [
            "are you sure",
            "how can you",
            "that's wrong",
            "you said",
            "but you",
            "clearly",
            "check again",
            "look again"
        ]
        return cues.contains(where: { q.contains($0) })
    }

    private func lastContentfulUserQuestion(_ history: [ChatMessage]) -> String? {
        for msg in history.reversed() where msg.role == "user" {
            let text = cleanLine(msg.text)
            let tokenCount = text.split { !$0.isLetter && !$0.isNumber }.count
            if tokenCount < 4 { continue }
            if isChallenge(text) { continue }
            return text
        }
        return nil
    }

    private func smallTalkReply(_ question: String) -> String {
        let s = cleanLine(question).lowercased()
        if s.contains("how are") { return "I'm good - what can I help you find in your documents?" }
        if s.contains("are you") {
            return "Yep. What do you want to do - search, summarize, or extract something?"
        }
        if s.contains("hello") || s.contains("hi") { return "Hey! What do you need help with?" }
        return "I'm here. What do you need?"
    }

    private func updateSessionState(from primaryDocument: Document?) {
        sessionState.lastReferencedDocumentId = primaryDocument?.id
    }

    private func rankedChunkHits(
        question: String,
        retrievalQuery: String? = nil,
        allDocs: [Document],
        preferredDocumentId: UUID?,
        applyLastDocumentBias: Bool
    ) -> [ChunkHit] {
        let queryForRetrieval = retrievalQuery ?? expandQuery(question)
        let questionTokens = retrievalTokens(queryForRetrieval)
        let anchors = anchorTokens(from: question)
        let shortAcronymAnchors = anchors.filter { isShortAcronymToken($0) }
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        let predictedField = predictField(for: question)
        let queryTrigrams = characterTrigrams(for: queryForRetrieval)
        var rankedCandidates: [(document: Document, chunk: OCRChunk, features: ChunkLexicalFeatures)] = []
        var documentFrequency: [String: Int] = [:]
        var totalTokenCount = 0

        for doc in allDocs {
            let chunks = doc.ocrChunks.isEmpty
                ? [OCRChunk(documentId: doc.id, pageNumber: nil, text: doc.content)]
                : doc.ocrChunks

            for chunk in chunks {
                let features = buildChunkLexicalFeatures(for: chunk.text)
                if features.tokenSet.isEmpty && features.trigrams.isEmpty { continue }
                rankedCandidates.append((document: doc, chunk: chunk, features: features))
                totalTokenCount += features.length
                for token in features.tokenSet {
                    documentFrequency[token, default: 0] += 1
                }
            }
        }

        let totalDocs = rankedCandidates.count
        let averageDocLength = totalDocs == 0 ? 1.0 : Double(totalTokenCount) / Double(totalDocs)
        var bm25ByChunkId: [UUID: Double] = [:]
        var maxBM25 = 0.0
        for candidate in rankedCandidates {
            let rawBM25 = bm25Score(
                queryTokens: questionTokens,
                termFreq: candidate.features.termFreq,
                docLength: candidate.features.length,
                documentFrequency: documentFrequency,
                totalDocs: totalDocs,
                averageDocLength: averageDocLength
            )
            bm25ByChunkId[candidate.chunk.chunkId] = rawBM25
            if rawBM25 > maxBM25 { maxBM25 = rawBM25 }
        }

        var hits: [ChunkHit] = []

        for candidate in rankedCandidates {
            let doc = candidate.document
            let chunk = candidate.chunk
            let features = candidate.features
            let docTypeMatch = doc.category == predictedField ? 1.0 : 0.0
            let tagMatch = normalizedMatchScore(questionTokens: questionTokens, text: doc.tags.joined(separator: " "))
            let titleMatch = normalizedMatchScore(questionTokens: questionTokens, text: doc.title)
            let lexicalOverlap = semanticOverlapScore(questionTokens: questionTokens, chunkTokens: features.tokenSet)
            let normalizedBM25 = maxBM25 > 0 ? ((bm25ByChunkId[chunk.chunkId] ?? 0) / maxBM25) : 0
            let trigramScore = trigramJaccardScore(queryTrigrams: queryTrigrams, chunkTrigrams: features.trigrams)
            let semanticScore = (bm25Weight * normalizedBM25) + (trigramWeight * trigramScore)
            let exact = exactMatchScores(exactTokens: exactTokens, phrases: phrases, text: chunk.text)
            let hasAnchorMatch = !anchors.isEmpty && textContainsAnyAnchor(chunk.text, anchors: anchors)
            let anchorAdjustment = anchors.isEmpty
                ? 0.0
                : (hasAnchorMatch ? anchorChunkBoostWeight : -anchorChunkPenaltyWeight)
            let shortAcronymBonus =
                shortAcronymAnchors.isEmpty
                ? 0.0
                : (textContainsAnyAnchor(chunk.text, anchors: shortAcronymAnchors)
                    ? shortAcronymAnchorBoostWeight
                    : 0.0)
            let lastDocBias =
                (applyLastDocumentBias && preferredDocumentId == doc.id) ? lastDocumentBiasWeight : 0.0
            let finalScore =
                (semanticWeight * semanticScore) +
                (0.25 * lexicalOverlap) +
                (docTypeBoostWeight * docTypeMatch) +
                (tagBoostWeight * tagMatch) +
                (titleBoostWeight * titleMatch) +
                (exactTokenBoostWeight * exact.exactToken) +
                (phraseBoostWeight * exact.phrase) +
                (numericTokenBoostWeight * exact.numeric) +
                anchorAdjustment +
                shortAcronymBonus +
                lastDocBias

            if semanticScore <= 0 &&
                lexicalOverlap <= 0 &&
                tagMatch <= 0 &&
                titleMatch <= 0 &&
                exact.exactToken <= 0 &&
                exact.phrase <= 0 &&
                exact.numeric <= 0 &&
                anchorAdjustment <= 0 &&
                shortAcronymBonus <= 0 {
                continue
            }

            hits.append(
                ChunkHit(
                    document: doc,
                    chunk: chunk,
                    semanticScore: semanticScore,
                    docTypeMatch: docTypeMatch,
                    tagMatch: tagMatch,
                    titleMatch: titleMatch,
                    exactTokenMatch: exact.exactToken,
                    phraseMatch: exact.phrase,
                    numericMatch: exact.numeric,
                    finalScore: finalScore
                )
            )
        }

        return hits.sorted { lhs, rhs in
            if lhs.finalScore != rhs.finalScore { return lhs.finalScore > rhs.finalScore }
            if lhs.semanticScore != rhs.semanticScore { return lhs.semanticScore > rhs.semanticScore }
            return lhs.document.dateCreated > rhs.document.dateCreated
        }
    }

    private struct PassBHitScore {
        let hit: ChunkHit
        let score: Double
    }

    private func isCountQuestion(_ question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        if q.isEmpty { return false }
        return q.contains("how many") || q.contains("number of") || q.contains("count") || q.contains("total")
    }

    private func normalizedForMatching(_ text: String) -> String {
        cleanLine(text)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
    }

    private func strongestSubjectAnchorToken(from question: String) -> String? {
        anchorTokens(from: question).first.map { normalizedForMatching($0) }
    }

    private func passBFeatures(
        for hit: ChunkHit,
        subjectToken: String?,
        questionTokens: Set<String>
    ) -> (subjectMatch: Bool, queryKeywordMatches: Int) {
        let chunkNormalized = normalizedForMatching(hit.chunk.text)
        let subjectMatch = subjectToken.map { chunkNormalized.contains($0) } ?? false
        let chunkTokens = retrievalTokens(hit.chunk.text)
        let queryKeywordMatches = questionTokens.intersection(chunkTokens).count
        return (subjectMatch, queryKeywordMatches)
    }

    private func chunkContainsDigits(_ text: String) -> Bool {
        text.rangeOfCharacter(from: .decimalDigits) != nil
    }

    private func passAChunkCandidates(from hits: [ChunkHit]) -> [ChunkHit] {
        if hits.isEmpty { return [] }
        let perDocLimit = 10
        let candidateCap = 80

        var docOrder: [UUID] = []
        var grouped: [UUID: [ChunkHit]] = [:]
        for hit in hits {
            let docId = hit.document.id
            if grouped[docId] == nil {
                grouped[docId] = []
                docOrder.append(docId)
            }
            grouped[docId]?.append(hit)
        }

        var merged: [ChunkHit] = []
        merged.reserveCapacity(candidateCap)
        for docId in docOrder {
            guard let docHits = grouped[docId] else { continue }
            merged.append(contentsOf: docHits.prefix(perDocLimit))
            if merged.count >= candidateCap { break }
        }

        if merged.count > candidateCap {
            return Array(merged.prefix(candidateCap))
        }
        return merged
    }

    private func passBRerankScore(
        for hit: ChunkHit,
        isCountQuestion: Bool,
        subjectToken: String?,
        questionTokens: Set<String>
    ) -> Double {
        let overlap = hit.semanticScore
        let numbers = hit.numericMatch
        let hasDigits = chunkContainsDigits(hit.chunk.text)
        let features = passBFeatures(
            for: hit,
            subjectToken: subjectToken,
            questionTokens: questionTokens
        )
        let exactKeywordHits =
            (0.75 * hit.exactTokenMatch) +
            (0.55 * hit.phraseMatch) +
            (0.25 * hit.titleMatch) +
            (0.2 * hit.tagMatch)
        let countQuestionBonus = isCountQuestion ? (hasDigits ? 0.85 : 0.0) : 0.0
        let numericWeight = isCountQuestion ? 1.8 : 1.2
        let subjectBonus = features.subjectMatch ? 0.95 : 0.0
        return
            (1.25 * overlap) +
            (numericWeight * numbers) +
            (1.1 * exactKeywordHits) +
            countQuestionBonus +
            subjectBonus
    }

    private func twoPassContextHits(from hits: [ChunkHit], question: String) -> [ChunkHit] {
        let passA = passAChunkCandidates(from: hits)
        if passA.isEmpty { return [] }

        let countQuestion = isCountQuestion(question)
        let subjectToken = strongestSubjectAnchorToken(from: question)
        let questionTokens = retrievalTokens(question)
        let reranked = passA.map { hit in
            PassBHitScore(
                hit: hit,
                score: passBRerankScore(
                    for: hit,
                    isCountQuestion: countQuestion,
                    subjectToken: subjectToken,
                    questionTokens: questionTokens
                )
            )
        }.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.hit.finalScore != rhs.hit.finalScore { return lhs.hit.finalScore > rhs.hit.finalScore }
            return lhs.hit.document.dateCreated > rhs.hit.document.dateCreated
        }
        let topEvidence = Array(reranked.prefix(passBTopEvidenceLimit).map(\.hit))

        let gated = topEvidence.filter { hit in
            let features = passBFeatures(
                for: hit,
                subjectToken: subjectToken,
                questionTokens: questionTokens
            )
            return features.subjectMatch || features.queryKeywordMatches >= passBGatingKeywordMatchMin
        }
        return gated.isEmpty ? topEvidence : gated
    }

    private func expandedHitsWithNeighbors(from hits: [ChunkHit], allHits: [ChunkHit]) -> [ChunkHit] {
        if hits.isEmpty { return [] }
        var byChunkId: [UUID: ChunkHit] = [:]
        for hit in allHits {
            if let existing = byChunkId[hit.chunk.chunkId], existing.finalScore >= hit.finalScore {
                continue
            }
            byChunkId[hit.chunk.chunkId] = hit
        }

        var output: [ChunkHit] = []
        var seen = Set<UUID>()

        for seed in hits {
            let chunks = seed.document.ocrChunks.isEmpty ? [seed.chunk] : seed.document.ocrChunks
            guard let centerIndex = chunks.firstIndex(where: { $0.chunkId == seed.chunk.chunkId }) else {
                if seen.insert(seed.chunk.chunkId).inserted {
                    output.append(seed)
                    if output.count >= expandedEvidenceLimit { break }
                }
                continue
            }

            let candidateIndices = [centerIndex - 1, centerIndex, centerIndex + 1]
            for idx in candidateIndices where idx >= 0 && idx < chunks.count {
                let candidateChunk = chunks[idx]
                if let seedPage = seed.chunk.pageNumber, let candidatePage = candidateChunk.pageNumber, seedPage != candidatePage {
                    continue
                }
                let resolved = byChunkId[candidateChunk.chunkId] ?? seed
                if seen.insert(resolved.chunk.chunkId).inserted {
                    output.append(resolved)
                    if output.count >= expandedEvidenceLimit { break }
                }
            }
            if output.count >= expandedEvidenceLimit { break }
        }

        return output.isEmpty ? hits : output
    }

    private func passesAdaptiveEvidenceThreshold(_ hits: [ChunkHit]) -> Bool {
        guard !hits.isEmpty else { return false }
        let sortedScores = hits.map(\.finalScore).sorted(by: >)
        let best = sortedScores[0]
        if best >= evidenceAbsoluteFloor { return true }
        let median = sortedScores[sortedScores.count / 2]
        if best >= (median + evidenceMedianMargin) { return true }
        let second = sortedScores.count > 1 ? sortedScores[1] : best
        let gap = best - second
        return gap >= evidenceGapThreshold
    }

    private func selectDocumentsByChunkRanking(
        question: String,
        allDocs: [Document],
        preferredDocumentId: UUID?,
        applyLastDocumentBias: Bool,
        retrievalQuery: String? = nil
    ) -> DocumentSelectionResult {
        if allDocs.isEmpty {
            return DocumentSelectionResult(
                documents: [],
                primaryDocument: nil,
                topScoreByDocumentId: [:],
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: []
            )
        }
        let candidateDocs = anchorFilteredDocuments(question: question, docs: allDocs)

        let hits = rankedChunkHits(
            question: question,
            retrievalQuery: retrievalQuery,
            allDocs: candidateDocs,
            preferredDocumentId: preferredDocumentId,
            applyLastDocumentBias: applyLastDocumentBias
        )
        if hits.isEmpty {
            let fallbackScored = fallbackScoredSelection(
                question: question,
                allDocs: candidateDocs,
                retrievalQuery: retrievalQuery
            )
            let fallbackDocs = fallbackScored.map { $0.document }
            let fallbackScores = Dictionary(
                uniqueKeysWithValues: fallbackScored.map { ($0.document.id, max($0.score, 0.0001)) }
            )
            return DocumentSelectionResult(
                documents: fallbackDocs,
                primaryDocument: fallbackDocs.first,
                topScoreByDocumentId: fallbackScores,
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: hits
            )
        }
        if !passesAdaptiveEvidenceThreshold(hits) {
            return DocumentSelectionResult(
                documents: [],
                primaryDocument: nil,
                topScoreByDocumentId: [:],
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: hits
            )
        }

        let contextHits = expandedHitsWithNeighbors(
            from: twoPassContextHits(from: hits, question: question),
            allHits: hits
        )
        if contextHits.isEmpty {
            let fallbackScored = fallbackScoredSelection(
                question: question,
                allDocs: candidateDocs,
                retrievalQuery: retrievalQuery
            )
            let fallbackDocs = fallbackScored.map { $0.document }
            let fallbackScores = Dictionary(
                uniqueKeysWithValues: fallbackScored.map { ($0.document.id, max($0.score, 0.0001)) }
            )
            return DocumentSelectionResult(
                documents: fallbackDocs,
                primaryDocument: fallbackDocs.first,
                topScoreByDocumentId: fallbackScores,
                retrievalQueryUsed: retrievalQuery,
                selectedHits: [],
                allRankedHits: hits
            )
        }

        var selected: [Document] = []
        var seenDocIds = Set<UUID>()
        var topScoreByDocumentId: [UUID: Double] = [:]

        for hit in contextHits {
            let docId = hit.document.id
            topScoreByDocumentId[docId] = max(topScoreByDocumentId[docId] ?? 0, hit.finalScore)
            if seenDocIds.contains(docId) { continue }
            seenDocIds.insert(docId)
            selected.append(hit.document)
            if selected.count >= selectionMaxDocs { break }
        }

        if selected.isEmpty {
            return DocumentSelectionResult(
                documents: [],
                primaryDocument: nil,
                topScoreByDocumentId: [:],
                retrievalQueryUsed: retrievalQuery,
                selectedHits: contextHits,
                allRankedHits: hits
            )
        }

        let primaryDocId = contextHits.first?.document.id
        let primaryDocument = primaryDocId.flatMap { id in selected.first { $0.id == id } } ?? selected.first
        let selectedScores = Dictionary(
            uniqueKeysWithValues: selected.map { doc in
                (doc.id, max(topScoreByDocumentId[doc.id] ?? 0.0001, 0.0001))
            }
        )
        return DocumentSelectionResult(
            documents: selected,
            primaryDocument: primaryDocument,
            topScoreByDocumentId: selectedScores,
            retrievalQueryUsed: retrievalQuery,
            selectedHits: contextHits,
            allRankedHits: hits
        )
    }

    private func logRetrievalTrace(
        question: String,
        selection: DocumentSelectionResult
    ) {
        let hits = selection.selectedHits
        let globalHits = selection.allRankedHits
        let topK = 10

        print("================ RETRIEVAL TRACE ================")
        print("Question: \"\(cleanLine(question))\"")
        print("")
        print("Top K Global Chunks (pre Pass A, K = \(topK)):")
        print("")

        if globalHits.isEmpty {
            print("(no chunk hits)")
            print("")
        } else {
            for (index, hit) in globalHits.prefix(topK).enumerated() {
                let page = hit.chunk.pageNumber.map { "Page \($0)" } ?? "Page ?"
                let snippet = trimToCharBudget(hit.chunk.text, maxChars: 520)

                print("[\(index + 1)] Score: \(String(format: "%.2f", hit.finalScore))")
                print("Doc: \(hit.document.title)")
                print("Chunk: \(hit.chunk.chunkId.uuidString) \(page)")
                print("----------------------------------------")
                print("\"\(snippet)\"")
                print("----------------------------------------")
                print("")
            }
        }

        print("Top K Selected Evidence Chunks (post Pass B, K = \(topK)):")
        print("")

        if hits.isEmpty {
            print("(no selected evidence chunks)")
            print("")
        } else {
            for (index, hit) in hits.prefix(topK).enumerated() {
                let page = hit.chunk.pageNumber.map { "Page \($0)" } ?? "Page ?"
                let snippet = trimToCharBudget(hit.chunk.text, maxChars: 520)

                print("[\(index + 1)] Score: \(String(format: "%.2f", hit.finalScore))")
                print("Doc: \(hit.document.title)")
                print("Chunk: \(hit.chunk.chunkId.uuidString) \(page)")
                print("----------------------------------------")
                print("\"\(snippet)\"")
                print("----------------------------------------")
                print("")
            }
        }

        let scores = globalHits.map(\.finalScore).sorted(by: >)
        let best = scores.first ?? 0
        let median = scores.isEmpty ? 0 : scores[scores.count / 2]
        let second = scores.count > 1 ? scores[1] : best
        let gap = best - second
        print("AdaptiveThreshold floor=\(String(format: "%.2f", evidenceAbsoluteFloor)) median+margin=\(String(format: "%.2f", evidenceMedianMargin)) gap=\(String(format: "%.2f", evidenceGapThreshold))")
        print("EvidenceStats best=\(String(format: "%.2f", best)) median=\(String(format: "%.2f", median)) gap=\(String(format: "%.2f", gap))")
        print("=================================================")
    }

    private func retrySelectionWithExpandedQueryIfNeeded(
        question: String,
        allDocs: [Document],
        preferredDocumentId: UUID?,
        applyLastDocumentBias: Bool,
        currentSelection: DocumentSelectionResult
    ) -> DocumentSelectionResult {
        if !currentSelection.selectedHits.isEmpty { return currentSelection }

        let expanded = expandQuery(question)
        if cleanLine(expanded).lowercased() == cleanLine(question).lowercased() {
            return currentSelection
        }

        return selectDocumentsByChunkRanking(
            question: question,
            allDocs: allDocs,
            preferredDocumentId: preferredDocumentId,
            applyLastDocumentBias: applyLastDocumentBias,
            retrievalQuery: expanded
        )
    }

    private struct RankedSnippet {
        let text: String
        let score: Double
    }

    private func shouldIncludeOCR(question: String, document: Document, rank: Int) -> Bool {
        let q = cleanLine(question).lowercased()
        let triggers = [
            "ocr", "text", "verbatim", "quote", "exact", "page", "line", "paragraph"
        ]
        let explicitTrigger = triggers.contains { q.contains($0) }
        let hasOCRData = !(document.ocrPages?.isEmpty ?? true) || !document.ocrChunks.isEmpty
        if !hasOCRData { return false }
        if explicitTrigger { return true }
        if rank < defaultOCRDocCount { return true }
        if document.type == .scanned || document.type == .image { return true }
        let compactContent = cleanLine(document.content)
        if compactContent.count < lowExtractedTextThreshold { return true }
        return false
    }

    private func trimToCharBudget(_ text: String, maxChars: Int) -> String {
        if maxChars <= 0 { return "" }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars { return trimmed }
        let cutoff = trimmed.index(trimmed.startIndex, offsetBy: maxChars)
        let prefix = String(trimmed[..<cutoff])
        if let lastBoundary = prefix.lastIndex(where: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            return String(prefix[..<lastBoundary]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return prefix.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func contentSnippetCandidates(_ text: String) -> [String] {
        let compact = cleanLine(text)
        if compact.isEmpty { return [] }

        let paragraphs = text
            .components(separatedBy: .newlines)
            .map(cleanLine)
            .filter { $0.count >= 24 }
        if !paragraphs.isEmpty {
            return Array(paragraphs.prefix(60))
        }

        if compact.count <= maxSnippetChars {
            return [compact]
        }

        var chunks: [String] = []
        var start = compact.startIndex
        while start < compact.endIndex {
            let end = compact.index(start, offsetBy: maxSnippetChars, limitedBy: compact.endIndex) ?? compact.endIndex
            let chunk = String(compact[start..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty { chunks.append(chunk) }
            if end == compact.endIndex { break }
            start = end
        }
        return chunks
    }

    private func snippetRelevanceScore(
        questionTokens: Set<String>,
        exactTokens: [String],
        phrases: [String],
        text: String
    ) -> Double {
        let semantic = semanticOverlapScore(
            questionTokens: questionTokens,
            chunkTokens: retrievalTokens(text)
        )
        let exact = exactMatchScores(exactTokens: exactTokens, phrases: phrases, text: text)
        return
            (semanticWeight * semantic) +
            (exactTokenBoostWeight * exact.exactToken) +
            (phraseBoostWeight * exact.phrase) +
            (numericTokenBoostWeight * exact.numeric)
    }

    private func topRankedSnippets(
        candidates: [String],
        questionTokens: Set<String>,
        exactTokens: [String],
        phrases: [String],
        limit: Int
    ) -> [String] {
        if candidates.isEmpty { return [] }
        let ranked = candidates.prefix(90).map { snippet in
            RankedSnippet(
                text: trimToCharBudget(snippet, maxChars: maxSnippetChars),
                score: snippetRelevanceScore(
                    questionTokens: questionTokens,
                    exactTokens: exactTokens,
                    phrases: phrases,
                    text: snippet
                )
            )
        }
        let sorted = ranked.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.text.count > rhs.text.count
        }
        var seen = Set<String>()
        var out: [String] = []
        for snippet in sorted {
            if out.count >= limit { break }
            let key = snippet.text.lowercased()
            if key.isEmpty { continue }
            if seen.insert(key).inserted {
                out.append(snippet.text)
            }
        }
        return out
    }

    private func buildDocumentContextBlock(
        document: Document,
        rank: Int,
        question: String,
        questionTokens: Set<String>,
        exactTokens: [String],
        phrases: [String],
        pathMap: [UUID: String],
        formatter: DateFormatter
    ) -> String {
        let folderPath = document.folderId.flatMap { pathMap[$0] } ?? "Root"
        let summary = trimToCharBudget(document.summary, maxChars: maxSummaryCharsPerDoc)
        let includeOCR = shouldIncludeOCR(question: question, document: document, rank: rank)

        let contentCandidates = contentSnippetCandidates(document.content)
        let contentSnippets = topRankedSnippets(
            candidates: contentCandidates,
            questionTokens: questionTokens,
            exactTokens: exactTokens,
            phrases: phrases,
            limit: maxSnippetsPerDoc
        )

        let ocrCandidates: [String] = includeOCR
            ? document.ocrChunks.map { chunk in
                let pagePrefix = chunk.pageNumber.map { "Page \($0): " } ?? ""
                return "\(pagePrefix)\(chunk.text)"
            }
            : []
        let ocrSnippets = topRankedSnippets(
            candidates: ocrCandidates,
            questionTokens: questionTokens,
            exactTokens: exactTokens,
            phrases: phrases,
            limit: maxOCRSnippetsPerDoc
        )

        let contentSection = contentSnippets.isEmpty
            ? "ContentSnippets: None"
            : "ContentSnippets:\n" + contentSnippets.map { "- \($0)" }.joined(separator: "\n")
        let ocrSection = ocrSnippets.isEmpty
            ? "OCRSnippets: None"
            : "OCRSnippets:\n" + ocrSnippets.map { "- \($0)" }.joined(separator: "\n")

        return """
        DocId: \(document.id.uuidString)
        Title: \(document.title)
        Folder: \(folderPath)
        Type: \(document.type.rawValue)
        Tags: \(document.tags.joined(separator: ", "))
        Date: \(formatter.string(from: document.dateCreated))
        Summary: \(summary)
        \(contentSection)
        \(ocrSection)
        """
    }

    private func contextBudgetShares(
        selected: [Document],
        topScoreByDocumentId: [UUID: Double]
    ) -> [Double] {
        if selected.isEmpty { return [] }
        if selected.count == 1 { return [1.0] }

        let rankShares: [Double]
        if selected.count == 2 {
            rankShares = [0.65, 0.35]
        } else {
            let tailShare = 0.30 / Double(selected.count - 2)
            rankShares = [0.45, 0.25] + Array(repeating: tailShare, count: selected.count - 2)
        }

        let rawScores = selected.map { max(topScoreByDocumentId[$0.id] ?? 0, 0) }
        let scoreSum = rawScores.reduce(0, +)
        let scoreShares = scoreSum > 0
            ? rawScores.map { $0 / scoreSum }
            : rankShares

        let blended = zip(rankShares, scoreShares).map { rankShare, scoreShare in
            (0.7 * rankShare) + (0.3 * scoreShare)
        }
        let blendedSum = blended.reduce(0, +)
        guard blendedSum > 0 else { return rankShares }
        return blended.map { $0 / blendedSum }
    }

    private func buildSelectedDocumentContext(
        selected: [Document],
        question: String,
        topScoreByDocumentId: [UUID: Double]
    ) -> String {
        if selected.isEmpty { return "No relevant documents selected." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        let questionTokens = retrievalTokens(expandQuery(question))
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        let shares = contextBudgetShares(selected: selected, topScoreByDocumentId: topScoreByDocumentId)

        var remainingBudget = activeContextCharBudget
        var blocks: [String] = []

        for (index, doc) in selected.enumerated() {
            if remainingBudget <= minContextReserveChars { break }
            let block = buildDocumentContextBlock(
                document: doc,
                rank: index,
                question: question,
                questionTokens: questionTokens,
                exactTokens: exactTokens,
                phrases: phrases,
                pathMap: pathMap,
                formatter: formatter
            )
            let share = index < shares.count ? shares[index] : (1.0 / Double(max(1, selected.count)))
            let targetBudget = max(900, Int(Double(activeContextCharBudget) * share))
            let blockBudget = min(remainingBudget, targetBudget)
            let trimmedBlock = trimToCharBudget(block, maxChars: blockBudget)
            if trimmedBlock.isEmpty { continue }
            blocks.append(trimmedBlock)
            remainingBudget -= (trimmedBlock.count + 8)
        }

        if blocks.isEmpty, let first = selected.first {
            let fallback = """
            DocId: \(first.id.uuidString)
            Title: \(first.title)
            Summary: \(trimToCharBudget(first.summary, maxChars: maxSummaryCharsPerDoc))
            """
            return trimToCharBudget(fallback, maxChars: activeContextCharBudget)
        }

        return blocks.joined(separator: "\n---\n")
    }

    private func fallbackScoredSelection(
        question: String,
        allDocs: [Document],
        limit: Int = 6,
        retrievalQuery: String? = nil
    ) -> [(document: Document, score: Double)] {
        if allDocs.isEmpty { return [] }
        let candidateDocs = anchorFilteredDocuments(question: question, docs: allDocs)
        let expanded = retrievalQuery ?? expandQuery(question)
        let questionTokens = retrievalTokens(expanded)
        let exactTokens = exactQueryTokens(from: question)
        let phrases = exactQueryPhrases(from: question)
        let scored = candidateDocs.map { doc -> (Document, Double) in
            let metadata = "\(doc.title) \(doc.tags.joined(separator: " ")) \(doc.summary)"
            let lexical = normalizedMatchScore(questionTokens: questionTokens, text: metadata)
            let exact = exactMatchScores(exactTokens: exactTokens, phrases: phrases, text: metadata)
            let score =
                lexical +
                (exactTokenBoostWeight * exact.exactToken) +
                (phraseBoostWeight * exact.phrase) +
                (numericTokenBoostWeight * exact.numeric)
            return (doc, score)
        }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.dateCreated > b.0.dateCreated
        }
        let top = sorted.prefix(limit).map { (document: $0.0, score: $0.1) }
        let maxScore = top.map(\.score).max() ?? 0
        if maxScore <= 0 {
            return []
        }
        return top
    }

    private func buildAnswerPrompt(
        question: String,
        selectedDocs: [Document],
        topScoreByDocumentId: [UUID: Double],
        selectedHits: [ChunkHit]
    ) -> String {
        let folders = trimToCharBudget(buildFolderIndex(), maxChars: folderContextCharBudget)
        let evidence = buildEvidenceFromSelectedHits(selectedHits, maxChars: activeContextCharBudget)
        let selectedDocList = selectedDocs.isEmpty
            ? "SelectedDocs: None"
            : selectedDocs.map { "- \($0.title) [\($0.id.uuidString)] score=\(String(format: "%.2f", topScoreByDocumentId[$0.id] ?? 0))" }.joined(separator: "\n")
        let activeContextBlock = """
        FOLDERS:
        \(folders)

        \(selectedDocList)

        \(evidence)
        """
        let lastDocId = sessionState.lastReferencedDocumentId?.uuidString ?? "None"
        return """
        SYSTEM:
        \(chatPreprompt)
        Internal process (do not expose):
        1) EXTRACT: find the smallest direct quote from EVIDENCE_CHUNKS that answers the QUESTION. If none exists, set EXTRACT=NONE.
        2) ANSWER: use only EXTRACT. If EXTRACT=NONE, output exactly: "Not specified in the documents."
        Use SESSION_POINTER only for follow-up retrieval continuity.
        Never treat SESSION_POINTER fields as factual evidence.
        Do not use prior chat/answer text as a factual source.

        SESSION_POINTER:
        LastReferencedDocumentId: \(lastDocId)

        ACTIVE_CONTEXT:
        \(activeContextBlock)

        QUESTION:
        \(question)
        """
    }

    private func buildEvidenceFromSelectedHits(_ hits: [ChunkHit], maxChars: Int) -> String {
        if hits.isEmpty { return "EVIDENCE_CHUNKS: None" }

        var out: [String] = []
        for (i, hit) in hits.enumerated() {
            let page = hit.chunk.pageNumber.map { "Page \($0)" } ?? "Page ?"
            let text = trimToCharBudget(hit.chunk.text, maxChars: 520)
            out.append("""
            [\(i + 1)] score=\(String(format: "%.2f", hit.finalScore)) doc="\(hit.document.title)" \(page) chunk=\(hit.chunk.chunkId.uuidString)
            \(text)
            """)
        }

        let joined = out.joined(separator: "\n\n")
        return trimToCharBudget("EVIDENCE_CHUNKS:\n\(joined)", maxChars: maxChars)
    }

    private func buildPrompt(for question: String) -> String {
        """
        SYSTEM:
        \(chatPreprompt)

        USER:
        \(question)
        """
    }

    private func callChatLLM(edgeAI: EdgeAI, question: String) async throws -> ChatLLMResult {
        if let statsAnswer = buildStatsAnswerIfNeeded(for: question) {
            return ChatLLMResult(reply: statsAnswer, primaryDocument: nil)
        }
        let scopedDocsRaw = !scopedDocumentIds.isEmpty ? scopedDocumentsForSelection() : []
        let docsInScopeCount = !scopedDocumentIds.isEmpty
            ? scopedDocsRaw.count
            : documentManager.conversationEligibleDocuments().count

        var effectiveQuestion = question
        let challengeQuestion = isChallenge(question) || isMetaDispute(question)
        if challengeQuestion, let lastQ = lastContentfulUserQuestion(messages) {
            effectiveQuestion = lastQ
        }
        let hasAssistantHistory = messages.contains { $0.role == "assistant" }
        let hasThreadHistory = hasAssistantHistory && messages.contains { $0.role == "user" }
        let shortFollowUp = hasAssistantHistory &&
            cleanLine(question).split { !$0.isLetter && !$0.isNumber }.count <= 6
        let anchorFollowUp = isAnaphoraFollowUp(question) || shortFollowUp
        let hasStrongQuestionAnchor = !anchorTokens(from: question).isEmpty
        if !challengeQuestion,
           !hasStrongQuestionAnchor,
           anchorFollowUp,
           let anchor = makeThreadAnchor(history: self.messages) {
            effectiveQuestion = anchor + question
        }

        if docsInScopeCount == 0 && isLowSignalChitChat(question) {
            return ChatLLMResult(reply: smallTalkReply(question), primaryDocument: nil)
        }
        if docsInScopeCount > 0 && !hasThreadHistory && isExplicitSmallTalkPrompt(question) {
            return ChatLLMResult(reply: smallTalkReply(question), primaryDocument: nil)
        }

        let allDocs = !scopedDocumentIds.isEmpty
            ? scopedDocsRaw
            : documentManager.conversationEligibleDocuments()
        let applyLastDocumentBias = !hasStrongQuestionAnchor
        let initialSelection = selectDocumentsByChunkRanking(
            question: effectiveQuestion,
            allDocs: allDocs,
            preferredDocumentId: sessionState.lastReferencedDocumentId,
            applyLastDocumentBias: applyLastDocumentBias
        )
        let selection = retrySelectionWithExpandedQueryIfNeeded(
            question: effectiveQuestion,
            allDocs: allDocs,
            preferredDocumentId: sessionState.lastReferencedDocumentId,
            applyLastDocumentBias: applyLastDocumentBias,
            currentSelection: initialSelection
        )

        logRetrievalTrace(
            question: effectiveQuestion,
            selection: selection
        )

        if selection.selectedHits.isEmpty {
            return ChatLLMResult(reply: "Not specified in the documents.", primaryDocument: nil)
        }

        let prompt = buildAnswerPrompt(
            question: effectiveQuestion,
            selectedDocs: selection.documents,
            topScoreByDocumentId: selection.topScoreByDocumentId,
            selectedHits: selection.selectedHits
        )
        let reply = try await callLLM(edgeAI: edgeAI, prompt: wrapChatPrompt(prompt))
        return ChatLLMResult(reply: reply, primaryDocument: selection.primaryDocument)
    }

    private func buildStatsAnswerIfNeeded(for question: String) -> String? {
        let q = question.lowercased()
        let wantsCount = q.contains("how many") || q.contains("number of") || q.contains("count of") || q.contains("total")
        let mentionsDocs = q.contains("document") || q.contains("docs") || q.contains("files") || q.contains("uploaded")
        let mentionsFolders = q.contains("folder")
        if !wantsCount { return nil }
        if mentionsDocs || mentionsFolders {
            let docCount = documentManager.documents.count
            let folderCount = documentManager.folders.count
            if mentionsDocs && mentionsFolders {
                return "You currently have \(docCount) documents and \(folderCount) folders."
            }
            if mentionsDocs {
                return "You currently have \(docCount) documents."
            }
            return "You currently have \(folderCount) folders."
        }
        return nil
    }

    private func scopedDocumentsForSelection() -> [Document] {
        let folderIds = Set(documentManager.folders.map { $0.id })
        let selectedFolderIds = scopedDocumentIds.intersection(folderIds)
        let selectedDocIds = scopedDocumentIds.subtracting(folderIds)

        var docs = documentManager.documents.filter { selectedDocIds.contains($0.id) }

        if !selectedFolderIds.isEmpty {
            var allFolderIds = Set<UUID>()
            for folderId in selectedFolderIds {
                allFolderIds.insert(folderId)
                allFolderIds.formUnion(documentManager.descendantFolderIds(of: folderId))
            }
            let folderDocs = documentManager.documents.filter { doc in
                guard let folderId = doc.folderId else { return false }
                return allFolderIds.contains(folderId)
            }
            docs.append(contentsOf: folderDocs)
        }

        var seen = Set<UUID>()
        let uniqueDocs = docs.filter { seen.insert($0.id).inserted }
        return uniqueDocs
            .filter { documentManager.isConversationEligible($0) }
            .sorted { $0.dateCreated > $1.dateCreated }
    }

    private func wrapChatPrompt(_ prompt: String) -> String {
        "<<<CHAT_DETAIL>>>" + prompt
    }

    private func callLLM(edgeAI: EdgeAI, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let finalPrompt = useNoHistoryForChat ? "<<<NO_HISTORY>>>" + prompt : prompt
            edgeAI.generate(finalPrompt, resolver: { result in
                continuation.resume(returning: result as? String ?? "")
            }, rejecter: { _, message, _ in
                continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
            })
        }
    }

    private struct ScopePickerSheet: View {
        @EnvironmentObject private var documentManager: DocumentManager
        @Binding var selectedIds: Set<UUID>
        @Environment(\.dismiss) private var dismiss
        @State private var editMode: EditMode = .active
        @State private var searchText = ""
        @AppStorage("documentsSortMode") private var documentsSortModeRaw = DocumentsSortMode.dateNewest.rawValue

        private enum DocumentsSortMode: String, CaseIterable {
            case dateNewest = "newest"
            case dateOldest = "oldest"
            case nameAsc = "alphabetically"
            case nameDesc = "alphabetically_desc"
            case accessNewest = "access_newest"
            case accessOldest = "access_oldest"
        }

        private enum ScopeItemKind {
            case folder(DocumentFolder)
            case document(Document)
        }

        private struct ScopeItem: Identifiable {
            let id: UUID
            let kind: ScopeItemKind
            let name: String
            let dateCreated: Date
        }

        private var documentsSortMode: DocumentsSortMode {
            DocumentsSortMode(rawValue: documentsSortModeRaw) ?? .dateNewest
        }

        private var scopeSortMode: DocumentsSortMode {
            switch documentsSortMode {
            case .accessNewest, .accessOldest:
                return documentsSortMode
            default:
                return .accessNewest
            }
        }

        private var scopeItems: [ScopeItem] {
            let folderItems = documentManager.folders.map { folder in
                ScopeItem(id: folder.id, kind: .folder(folder), name: folder.name, dateCreated: folder.dateCreated)
            }
            let documentItems = documentManager.documents.map { doc in
                ScopeItem(
                    id: doc.id,
                    kind: .document(doc),
                    name: splitDisplayTitle(doc.title).base,
                    dateCreated: doc.dateCreated
                )
            }
            return sortItems(folderItems + documentItems)
        }

        private var filteredItems: [ScopeItem] {
            let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return scopeItems }
            let needle = trimmed.lowercased()
            return scopeItems.filter { item in
                item.name.lowercased().contains(needle)
            }
        }

        var body: some View {
            NavigationView {
                List(selection: $selectedIds) {
                    if filteredItems.isEmpty {
                        Text("No documents or folders available.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(filteredItems) { item in
                            switch item.kind {
                            case .folder(let folder):
                                FolderRowView(
                                    folder: folder,
                                    docCount: documentManager.documents(in: folder.id).count,
                                    isSelected: selectedIds.contains(folder.id),
                                    isSelectionMode: true,
                                    usesNativeSelection: true,
                                    onSelectToggle: {},
                                    onOpen: {},
                                    onRename: {},
                                    onMove: {},
                                    onDelete: {},
                                    isDropTargeted: false
                                )
                                .tag(folder.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                            case .document(let document):
                                DocumentRowView(
                                    document: document,
                                    isSelected: selectedIds.contains(document.id),
                                    isSelectionMode: true,
                                    usesNativeSelection: true,
                                    onSelectToggle: {},
                                    onOpen: {},
                                    onRename: {},
                                    onMoveToFolder: {},
                                    onDelete: {},
                                    onConvert: {},
                                    onShare: {}
                                )
                                .tag(document.id)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .hideScrollBackground()
                .scrollDismissesKeyboardIfAvailable()
                .environment(\.editMode, $editMode)
                .navigationTitle("Scope")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search documents")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Clear") {
                            selectedIds.removeAll()
                        }
                        .foregroundColor(.primary)
                        .disabled(selectedIds.isEmpty)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundColor(.primary)
                            .buttonStyle(.borderedProminent)
                            .tint(Color("Primary"))
                            .disabled(selectedIds.isEmpty)
                    }
                }
            }
        }

        private func sortItems(_ items: [ScopeItem]) -> [ScopeItem] {
            switch scopeSortMode {
            case .dateNewest:
                return items.sorted {
                    if $0.dateCreated != $1.dateCreated { return $0.dateCreated > $1.dateCreated }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .dateOldest:
                return items.sorted {
                    if $0.dateCreated != $1.dateCreated { return $0.dateCreated < $1.dateCreated }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .nameAsc:
                return items.sorted {
                    let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                    return $0.dateCreated > $1.dateCreated
                }
            case .nameDesc:
                return items.sorted {
                    let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                    if nameOrder != .orderedSame { return nameOrder == .orderedDescending }
                    return $0.dateCreated > $1.dateCreated
                }
            case .accessNewest:
                return items.sorted {
                    let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                    let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                    if a != b { return a > b }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            case .accessOldest:
                return items.sorted {
                    let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                    let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                    if a != b { return a < b }
                    return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                }
            }
        }
    }

    private struct AutoGrowingTextView: UIViewRepresentable {
        @Binding var text: String
        @Binding var height: CGFloat
        let minHeight: CGFloat
        let maxHeight: CGFloat
        let font: UIFont
        let isEditable: Bool

        func makeUIView(context: Context) -> UITextView {
            let textView = UITextView()
            textView.isScrollEnabled = false
            textView.backgroundColor = .clear
            textView.font = font
            textView.textAlignment = .natural
            textView.textContainerInset = .zero
            textView.textContainer.lineFragmentPadding = 0
            textView.textContainer.lineBreakMode = .byWordWrapping
            textView.textContainer.widthTracksTextView = true
            textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            textView.delegate = context.coordinator
            return textView
        }

        func updateUIView(_ uiView: UITextView, context: Context) {
            if uiView.text != text {
                uiView.text = text
            }
            uiView.font = font
            uiView.isEditable = isEditable
            uiView.isScrollEnabled = false
            uiView.textAlignment = .natural
            recalcHeight(view: uiView)
        }

        func makeCoordinator() -> Coordinator {
            Coordinator(parent: self)
        }

        private func recalcHeight(view: UITextView) {
            let size = view.sizeThatFits(CGSize(width: view.bounds.width, height: .greatestFiniteMagnitude))
            let clamped = min(maxHeight, max(minHeight, size.height))
            if height != clamped {
                DispatchQueue.main.async {
                    height = clamped
                    view.isScrollEnabled = size.height > maxHeight
                }
            }
        }

        class Coordinator: NSObject, UITextViewDelegate {
            let parent: AutoGrowingTextView

            init(parent: AutoGrowingTextView) {
                self.parent = parent
            }

            func textViewDidChange(_ textView: UITextView) {
                parent.text = textView.text
                parent.recalcHeight(view: textView)
            }
        }
    }


    private struct ThinkingRow: View {
        @Binding var isPulseOn: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text("Thinking…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .opacity(isPulseOn ? 0.78 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    isPulseOn = true
                }
            }
            .onDisappear {
                isPulseOn = false
            }
        }
    }
}

private extension View {
    @ViewBuilder
    func ifAvailableiOS17CircleBorder() -> some View {
        self
            .buttonBorderShape(.circle)
    }
}

private struct MessageRow: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.role == "assistant" {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(formatMarkdownText(msg.text))
            .font(.system(size: 18))
            .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(msg.role == "user" ? Color("Primary") : Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(msg.role == "user" ? Color.clear : Color(.systemGray4).opacity(0.35), lineWidth: 1)
            )
    }
}
