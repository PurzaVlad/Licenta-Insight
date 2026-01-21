import SwiftUI
import Foundation

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "user" or "assistant"
    let text: String
    let date: Date
}

struct NativeChatView: View {
    @State private var activeDocsForChat: [Document] = []
    @State private var lastDocScopedQuestion: String = ""
    @State private var input: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating: Bool = false
    @State private var isThinkingPulseOn: Bool = false
    @State private var pendingDocConfirmation: PendingDocConfirmation? = nil
    @State private var showSummaryLoadingWarning = false
    @State private var hasShownSummaryLoadingWarning = false
    @State private var isSummaryGenerationActive = false
    @State private var showingScopePicker = false
    @State private var selectedDocIds: [UUID] = []
    @State private var selectedFolderId: UUID? = nil
    @State private var responseCache: [String: String] = [:]
    @State private var responseCacheOrder: [String] = []
    @State private var activeChatGenerationId: UUID? = nil
    @State private var lastResolvedDocsForChat: [Document] = []
    @State private var lastResolvedDocContext: String = ""
    @State private var lastResolvedDocId: UUID? = nil
    @FocusState private var isFocused: Bool
    @EnvironmentObject private var documentManager: DocumentManager

    private struct PendingDocConfirmation {
        let question: String
        let candidates: [Document]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
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
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages) { newValue in
                        if let last = newValue.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Message", text: $input)
                                .focused($isFocused)
                                .disabled(isGenerating || isSummaryGenerationActive)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.33)
                        )

                        Button {
                            send()
                        } label: {
                            Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || isSummaryGenerationActive ? .secondary : .white)
                                .background(
                                    Circle()
                                        .fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || isSummaryGenerationActive ? Color(.systemFill) : Color.accentColor)
                                )
                        }
                        .disabled(isSummaryGenerationActive || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" Chat ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(scopeLabel) {
                        showingScopePicker = true
                    }
                }
            }
        }
        .alert("Some documents are still preparing", isPresented: $showSummaryLoadingWarning) {
            Button("OK") {}
        } message: {
            Text("You can keep chatting now. I’ll answer using the documents that are ready.")
        }
        .sheet(isPresented: $showingScopePicker) {
            ChatScopePickerView(
                selectedDocIds: $selectedDocIds,
                selectedFolderId: $selectedFolderId,
                folders: documentManager.folders,
                documents: documentManager.documents
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryGenerationStatus"))) { notification in
            guard let active = notification.userInfo?["isActive"] as? Bool else { return }
            isSummaryGenerationActive = active
        }
        .onChange(of: selectedDocIds) { _ in
            activeDocsForChat = []
            pendingDocConfirmation = nil
            lastDocScopedQuestion = ""
            lastResolvedDocsForChat = []
            lastResolvedDocContext = ""
            lastResolvedDocId = nil
        }
        .onChange(of: selectedFolderId) { _ in
            activeDocsForChat = []
            pendingDocConfirmation = nil
            lastDocScopedQuestion = ""
            lastResolvedDocsForChat = []
            lastResolvedDocContext = ""
            lastResolvedDocId = nil
        }
    }

    private func send() {
        if isGenerating {
            stopGeneration()
            return
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isSummaryGenerationActive {
            messages.append(ChatMessage(
                role: "assistant",
                text: "I am busy generating a summary. Try again later.",
                date: Date()
            ))
            input = ""
            return
        }

        print("💬 NativeChatView: Sending message: '\(trimmed)'")
        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        let scopedDocs = scopedDocuments()
        activeDocsForChat = scopedDocs
        lastDocScopedQuestion = trimmed
        startGeneration(question: trimmed, docsToSearch: scopedDocs)

        // Model call is triggered by runLLMAnswer(...)
    }

    private func stopGeneration() {
        guard isGenerating else { return }
        isGenerating = false
        activeChatGenerationId = nil
        EdgeAI.shared?.cancelCurrentGeneration()
    }

    private func startGeneration(question: String, docsToSearch: [Document]) {
        let generationId = UUID()
        activeChatGenerationId = generationId
        runLLMAnswer(question: question, docsToSearch: docsToSearch, generationId: generationId)
    }

    private func tryConsumeDocConfirmationReply(_ reply: String, pending: PendingDocConfirmation) -> Bool {
        let normalized = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        if lower == "cancel" || lower == "stop" {
            pendingDocConfirmation = nil
            isGenerating = false
            messages.append(ChatMessage(role: "assistant", text: "Okay — cancelled.", date: Date()))
            return true
        }

        if pending.candidates.count == 1 {
            if lower == "yes" || lower == "y" || lower == "correct" {
                let doc = pending.candidates[0]
                pendingDocConfirmation = nil
                activeDocsForChat = [doc]
                lastDocScopedQuestion = pending.question
                startGeneration(question: pending.question, docsToSearch: [doc])
                return true
            }
            if lower == "no" || lower == "n" {
                pendingDocConfirmation = nil
                isGenerating = false
                messages.append(ChatMessage(
                    role: "assistant",
                    text: "Got it. Tell me the document name (or paste a unique phrase) and I’ll check it.",
                    date: Date()
                ))
                return true
            }
        }

        // Accept "doc 1" / "#1" / "1" etc.
        if let idx = extractFirstInt(from: lower) {
            if !pending.candidates.isEmpty, idx >= 1, idx <= pending.candidates.count {
                let doc = pending.candidates[idx - 1]
                pendingDocConfirmation = nil
                activeDocsForChat = [doc]
                lastDocScopedQuestion = pending.question
                startGeneration(question: pending.question, docsToSearch: [doc])
                return true
            }
        }

        // If we had no candidates, treat the reply as a document name hint.
        if pending.candidates.isEmpty {
            let matches = bestTitleMatches(for: lower, within: documentsWithReadySummaries(from: scopedDocuments()))
            if matches.isEmpty {
                return false
            }
            pendingDocConfirmation = nil
            activeDocsForChat = Array(matches.prefix(3))
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: Array(matches.prefix(3)))
            return true
        }

        if lower == "all" {
            pendingDocConfirmation = nil
            activeDocsForChat = pending.candidates
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: pending.candidates)
            return true
        }

        // Name match (try candidates first, then fall back to all documents)
        if let doc = bestTitleMatches(for: lower, within: pending.candidates).first {
            pendingDocConfirmation = nil
            activeDocsForChat = [doc]
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: [doc])
            return true
        }
        if let doc = bestTitleMatches(for: lower, within: documentsWithReadySummaries(from: scopedDocuments())).first {
            pendingDocConfirmation = nil
            activeDocsForChat = [doc]
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: [doc])
            return true
        }
        return false
    }

    private func looksLikeFollowUpQuestion(_ query: String) -> Bool {
        let s = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }

        // Short, referential questions are commonly follow-ups.
        if s.count <= 120 {
            let starters = ["what", "which", "when", "where", "who", "how", "did", "was", "were", "is", "are", "do", "does"]
            if starters.contains(where: { s.hasPrefix($0 + " ") || s == $0 }) {
                return true
            }
        }

        // Pronoun-heavy or continuation-style phrasing.
        let pronouns = ["it", "they", "them", "this", "that", "those", "these", "there", "he", "she"]
        if pronouns.contains(where: { s.contains(" \($0) ") || s.hasPrefix($0 + " ") }) {
            return true
        }

        // If we recently had a doc-scoped question, bias toward treating as follow-up.
        if !lastDocScopedQuestion.isEmpty {
            return true
        }

        return false
    }

    private func mentionsExplicitDifferentDocument(_ query: String) -> Bool {
        // If the user mentions a specific document title (or CV/resume/etc), allow switching.
        let lower = query.lowercased()
        if lower.contains("use ") && (lower.contains("document") || lower.contains("doc")) {
            return true
        }

        if bestTitleMatches(for: lower, within: documentsWithReadySummaries(from: scopedDocuments())).first != nil {
            // If they name a document, treat it as an explicit target (i.e., can switch).
            return true
        }
        return false
    }

    private func extractFirstInt(from s: String) -> Int? {
        let digits = s.split(whereSeparator: { !$0.isNumber })
        for d in digits {
            if let n = Int(d) { return n }
        }
        return nil
    }

    private func bestTitleMatches(for query: String, within docs: [Document]) -> [Document] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let tokens = q
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        func score(_ title: String) -> Int {
            let t = title.lowercased()
            var s = 0
            if t.contains(q) { s += 50 }
            for tok in tokens {
                if t.contains(tok) { s += 8 }
            }
            // Special synonyms for common cases
            if (q.contains("cv") || q.contains("resume")) && (t.contains("cv") || t.contains("resume")) { s += 30 }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0.title)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return scored.map { $0.doc }
    }

    private func isSmallTalk(_ query: String) -> Bool {
        let s = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }

        // Fast heuristics for greetings / chit-chat.
        let exact = [
            "hi", "hello", "hey", "yo",
            "thanks", "thank you", "thx",
            "good morning", "good afternoon", "good evening",
            "how are you", "how's it going", "whats up", "what's up"
        ]
        if exact.contains(s) { return true }

        // Short greeting prefixes
        if s.count <= 20 {
            if s.hasPrefix("hi ") || s.hasPrefix("hello ") || s.hasPrefix("hey ") { return true }
        }
        return false
    }

    private func shouldReuseLastDocsViaLLM(edgeAI: EdgeAI, question: String) async throws -> Bool {
        guard !lastResolvedDocsForChat.isEmpty else { return false }
        guard !lastResolvedDocContext.isEmpty else { return false }

        let prompt = """
        Decide if the user's message is about the same document context or a different document.
        Reply with exactly one word: SAME or NEW.
        Be strict: reply SAME only if it clearly refers to the cached document context.

        Cached document context:
        \(lastResolvedDocContext)

        User message: \(question)
        """
        let reply = try await callLLM(edgeAI: edgeAI, prompt: prompt)
        return reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("s")
    }

    private func buildDocContextSnippet(for doc: Document, maxChars: Int) -> String {
        let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = !summary.isEmpty && summary != "Processing..." && summary != "Processing summary..."
        let ocr = doc.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrPrefix = String(ocr.prefix(maxChars))
        if hasSummary {
            return "Summary:\n\(summary)\n\nOCR excerpt:\n\(ocrPrefix)"
        }
        return "OCR excerpt:\n\(ocrPrefix)"
    }

    private func buildCandidatePreview(_ docs: [Document]) -> String {
        // Only show document names (no OCR/summary previews) unless the user explicitly asks.
        let lines: [String] = docs.prefix(5).enumerated().map { (offset, doc) in
            let idx = offset + 1
            return "\(idx)) \(doc.title)"
        }
        return lines.isEmpty ? "" : ("Possible matches:\n" + lines.joined(separator: "\n"))
    }

    private func runLLMAnswer(question: String, docsToSearch: [Document], generationId: UUID) {
        isGenerating = true

        Task {
            do {
                if activeChatGenerationId != generationId { return }
                guard let edgeAI = EdgeAI.shared else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }

                if isSmallTalk(question) {
                    if activeChatGenerationId != generationId { return }
                    let reply = try await callLLM(edgeAI: edgeAI, prompt: question)
                    DispatchQueue.main.async {
                        if self.activeChatGenerationId != generationId { return }
                        self.isGenerating = false
                        let text = reply.isEmpty ? "(No response)" : reply
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                let reuseDocs = try await shouldReuseLastDocsViaLLM(edgeAI: edgeAI, question: question)
                if !reuseDocs {
                    lastResolvedDocsForChat = []
                    lastResolvedDocId = nil
                    lastResolvedDocContext = ""
                }
                let cachedDocs = reuseDocs ? lastResolvedDocsForChat : docsToSearch
                let cacheKey = makeCacheKey(question: question, docs: cachedDocs)
                if let cached = responseCache[cacheKey] {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        let text = cached.isEmpty ? "(No response)" : cached
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                if docsToSearch.isEmpty {
                    if activeChatGenerationId != generationId { return }
                    let reply = try await callLLM(edgeAI: edgeAI, prompt: question)
                    DispatchQueue.main.async {
                        if self.activeChatGenerationId != generationId { return }
                        self.isGenerating = false
                        let text = reply.isEmpty ? "(No response)" : reply
                        self.storeResponseCache(key: cacheKey, value: text)
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                if reuseDocs,
                   let finalDoc = lastResolvedDocsForChat.first,
                   let lastId = lastResolvedDocId,
                   lastId == finalDoc.id,
                   !lastResolvedDocContext.isEmpty {
                    let followUpPrompt = """
                    Cached document context:
                    \(lastResolvedDocContext)

                    Question: \(question)

                    Instruction: Include the document title "\(finalDoc.title)" in your response.
                    """
                    if activeChatGenerationId != generationId { return }
                    let finalReply = try await callLLM(edgeAI: edgeAI, prompt: followUpPrompt)
                    DispatchQueue.main.async {
                        if self.activeChatGenerationId != generationId { return }
                        self.isGenerating = false
                        let text = finalReply.isEmpty ? "(No response)" : finalReply
                        self.storeResponseCache(key: cacheKey, value: text)
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                // Stage 1: summary prefixes first; still provide titles for explicit requests.
                let titlesBlock = buildDocumentTitlesBlock(for: docsToSearch, maxDocs: 60)
                let summaryPrefixBlock = buildDocumentSummaryPrefixBlock(for: docsToSearch, maxDocs: 60, maxChars: 100)
                let stage2Prompt = """
                Document Titles:
                \(titlesBlock)

                Summary Prefixes (first 100 chars each):
                \(summaryPrefixBlock)

                Question: \(question)

                Return only the titles that still look relevant.
                Reply with:
                TITLES:
                - <title>
                or:
                NONE
                """
                if activeChatGenerationId != generationId { return }
                let stage2Reply = try await callLLM(edgeAI: edgeAI, prompt: stage2Prompt)

                var remainingDocs = parseTitleListReply(stage2Reply, allDocs: docsToSearch)
                // If summaries didn't match, keep the full set and continue.
                if remainingDocs.isEmpty { remainingDocs = docsToSearch }

                // Stage 3: full summary if multiple remain, else full OCR for the only doc.
                var stage3Reply = ""
                if remainingDocs.count > 1 {
                    let fullSummaries = buildDocumentFullSummariesBlock(for: remainingDocs, maxDocs: 12)
                    let stage3Prompt = """
                    Full Summaries:
                    \(fullSummaries)

                    Previous stage output:
                    \(stage2Reply.trimmingCharacters(in: .whitespacesAndNewlines))

                    Question: \(question)

                    Return only the titles that still look relevant.
                    Reply with:
                    TITLE: <title>
                    or:
                    NONE
                    """
                    if activeChatGenerationId != generationId { return }
                    stage3Reply = try await callLLM(edgeAI: edgeAI, prompt: stage3Prompt)
                    if let picked = parseSingleTitleReply(stage3Reply, allDocs: remainingDocs) {
                        remainingDocs = [picked]
                    } else if let picked = remainingDocs.first {
                        // If the model can't pick from summaries, default to the first candidate.
                        remainingDocs = [picked]
                    }
                }

                guard let finalDoc = remainingDocs.first else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "I couldn't find a relevant document.", date: Date()))
                    }
                    return
                }

                let ocrBlock = buildDocumentOCRBlock(for: finalDoc)
                let stage4Prompt = """
                OCR (full text):
                \(ocrBlock)

                Previous stage output:
                \(stage3Reply.trimmingCharacters(in: .whitespacesAndNewlines))

                Question: \(question)

                Instruction: Include the document title "\(finalDoc.title)" in your response.
                """
                if activeChatGenerationId != generationId { return }
                let finalReply = try await callLLM(edgeAI: edgeAI, prompt: stage4Prompt)

                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    let text = finalReply.isEmpty ? "(No response)" : finalReply
                    self.lastResolvedDocsForChat = [finalDoc]
                    self.lastResolvedDocId = finalDoc.id
                    self.lastResolvedDocContext = self.buildDocContextSnippet(for: finalDoc, maxChars: 1800)
                    self.storeResponseCache(key: cacheKey, value: text)
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
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

    private func callLLM(edgeAI: EdgeAI, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            edgeAI.generate("<<<NO_HISTORY>>>" + prompt, resolver: { result in
                continuation.resume(returning: result as? String ?? "")
            }, rejecter: { _, message, _ in
                continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
            })
        }
    }

    private func makeCacheKey(question: String, docs: [Document]) -> String {
        let docIds = docs.map { $0.id.uuidString }.sorted().joined(separator: "|")
        let normalizedQ = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedQ)|\(docIds)"
    }

    private func storeResponseCache(key: String, value: String) {
        let maxItems = 12
        responseCache[key] = value
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        if responseCacheOrder.count > maxItems {
            let overflow = responseCacheOrder.count - maxItems
            for _ in 0..<overflow {
                if let oldest = responseCacheOrder.first {
                    responseCacheOrder.removeFirst()
                    responseCache.removeValue(forKey: oldest)
                }
            }
        }
    }

    private func parseTitleListReply(_ reply: String, allDocs: [Document]) -> [Document] {
        let lower = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "none" {
            return []
        }
        let lines = reply
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let titles = lines.compactMap { line -> String? in
            if line.lowercased().hasPrefix("titles:") {
                return nil
            }
            if line.hasPrefix("-") {
                return line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        let matched = matchTitles(titles, allDocs: allDocs)
        if !matched.isEmpty { return matched }
        return matchTitles([reply], allDocs: allDocs)
    }

    private func buildNoDocumentPrompt(question: String) -> String {
        """
        You could not find a relevant document for the user's question. Respond briefly and ask the user to clarify or choose a document.

        Question: \(question)
        """
    }

    private func parseSingleTitleReply(_ reply: String, allDocs: [Document]) -> Document? {
        if let match = reply.range(of: "(?i)^title:\\s*", options: .regularExpression) {
            let picked = reply[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return matchTitles([picked], allDocs: allDocs).first
        }
        return matchTitles([reply], allDocs: allDocs).first
    }

    private func matchTitles(_ titles: [String], allDocs: [Document]) -> [Document] {
        let lowered = titles.map { $0.lowercased() }
        return allDocs.filter { doc in
            lowered.contains(where: { doc.title.lowercased() == $0 })
        }
    }



    private func buildDocumentTitlesBlock(for docs: [Document], maxDocs: Int) -> String {
        let list = docs.prefix(maxDocs).map { "- \($0.title)" }
        return list.isEmpty ? "(No documents)" : list.joined(separator: "\n")
    }

    private func buildDocumentSummaryPrefixBlock(for docs: [Document], maxDocs: Int, maxChars: Int) -> String {
        let lines = docs.prefix(maxDocs).map { doc -> String in
            let ocrPrefix = String(doc.content.prefix(maxChars)).replacingOccurrences(of: "\n", with: " ")
            return "Title - \"\(doc.title)\" Summary - \"\(ocrPrefix)\""
        }
        return lines.isEmpty ? "(No summaries)" : lines.joined(separator: "\n")
    }

    private func buildDocumentFullSummariesBlock(for docs: [Document], maxDocs: Int) -> String {
        let lines = docs.prefix(maxDocs).map { doc -> String in
            let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = summary.isEmpty ? "(No summary)" : summary
            return "Title - \"\(doc.title)\"\nSummary - \"\(body)\""
        }
        return lines.isEmpty ? "(No summaries)" : lines.joined(separator: "\n\n")
    }

    private func buildDocumentOCRBlock(for doc: Document) -> String {
        let body = doc.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrText = body.isEmpty ? "(No OCR text)" : body
        return "Title - \"\(doc.title)\"\nOCR - \"\(ocrText)\""
    }

    private func filterDocumentsByTitleMatch(question: String, docs: [Document]) -> [Document] {
        let tokens = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        guard !tokens.isEmpty else { return [] }

        func score(_ doc: Document) -> Int {
            let title = doc.title.lowercased()
            var s = 0
            for t in tokens {
                if title.contains(t) { s += 1 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return scored.map { $0.doc }
    }

    private func selectBestDocumentBySummary(question: String, docs: [Document]) -> Document? {
        let tokens = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        guard !tokens.isEmpty else { return docs.first }

        func score(_ doc: Document) -> Int {
            let summary = doc.summary.lowercased()
            var s = 0
            for t in tokens {
                if summary.contains(t) { s += 1 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .sorted { a, b in a.score > b.score }

        return scored.first?.doc
    }

    private func selectRelevantDocumentsWithScores(for query: String, maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func tokenScore(_ doc: Document, tokens: [String]) -> Int {
            let title = doc.title.lowercased()
            let summary = doc.summary.lowercased()
            let contentPrefix = String(doc.content.prefix(200)).lowercased()
            let category = doc.category.rawValue.lowercased()
            let keywords = doc.keywordsResume.lowercased()

            var s = 0
            for t in tokens {
                if title.contains(t) { s += 8 }
                if summary.contains(t) { s += 5 }
                if category.contains(t) { s += 6 }
                if keywords.contains(t) { s += 5 }
                if contentPrefix.contains(t) { s += 2 }
            }
            return s
        }

        // Fast path: if the full query string appears anywhere, boost that doc.
        let directMatches = documentManager.searchDocuments(query: trimmed)

        let allScored: [(doc: Document, score: Int)] = documentManager.documents.map { doc in
            var score = tokenScore(doc, tokens: tokens)
            if !directMatches.isEmpty && directMatches.contains(where: { $0.id == doc.id }) {
                score += 20
            }
            return (doc: doc, score: score)
        }

        let scored = allScored
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func selectRelevantDocumentsByMetadata(for query: String, maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func score(_ doc: Document) -> Int {
            let title = doc.title.lowercased()
            let category = doc.category.rawValue.lowercased()
            let keywords = doc.keywordsResume.lowercased()
            let q = trimmed.lowercased()

            var s = 0
            if title.contains(q) { s += 20 }
            if keywords.contains(q) { s += 18 }
            if category.contains(q) { s += 12 }

            for t in tokens.prefix(8) {
                if title.contains(t) { s += 10 }
                if keywords.contains(t) { s += 6 }
                if category.contains(t) { s += 6 }
            }

            // Special boost: CV/resume questions should bias toward Resume category.
            if (q.contains("experience") || q.contains("skills") || q.contains("education") || q.contains("resume") || q.contains("cv")) && doc.category == .resume {
                s += 16
            }
            return s
        }

        let scored = documentManager.documents
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func selectRelevantDocumentsBySummaryPrefix(for query: String, in docs: [Document], maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func score(_ doc: Document) -> Int {
            let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty || summary == "Processing..." || summary == "Processing summary..." {
                return 0
            }
            let prefix = String(summary.prefix(100)).lowercased()
            var s = 0
            for t in tokens.prefix(8) {
                if prefix.contains(t) { s += 4 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func selectRelevantDocumentsByFullSummary(for query: String, in docs: [Document], maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func score(_ doc: Document) -> Int {
            let summary = doc.summary.lowercased()
            if summary.isEmpty || summary == "processing..." || summary == "processing summary..." {
                return 0
            }
            var s = 0
            if summary.contains(trimmed.lowercased()) { s += 10 }
            for t in tokens.prefix(8) {
                if summary.contains(t) { s += 3 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func documentsWithReadySummaries(from docs: [Document]) -> [Document] {
        docs.filter { doc in
            let trimmed = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary...")
        }
    }

    private func scopedDocuments() -> [Document] {
        if let folderId = selectedFolderId {
            let descendantIds = documentManager.descendantFolderIds(of: folderId)
            let folderIds = descendantIds.union([folderId])
            return documentManager.documents.filter { doc in
                guard let docFolderId = doc.folderId else { return false }
                return folderIds.contains(docFolderId)
            }
        }

        if !selectedDocIds.isEmpty {
            let idSet = Set(selectedDocIds)
            return documentManager.documents.filter { idSet.contains($0.id) }
        }

        return documentManager.documents
    }

    private var scopeLabel: String {
        if let folderId = selectedFolderId {
            return documentManager.folderName(for: folderId) ?? "Folder"
        }
        if !selectedDocIds.isEmpty {
            let count = selectedDocIds.count
            return count == 1 ? "1 Doc" : "\(count) Docs"
        }
        return "Scope"
    }

    private func buildDocumentContextBlock(for docs: [Document], detailed: Bool) -> String {
        // Keep prompts small even with many documents.
        let maxCharsPerDoc = detailed ? 1800 : 200

        return docs.map { doc in
            let hasUsableSummary = !doc.summary.isEmpty &&
                doc.summary != "Processing..." &&
                doc.summary != "Processing summary..."

            let body: String
            if !detailed {
                let ocrPrefix = String(doc.content.prefix(maxCharsPerDoc))
                if hasUsableSummary {
                    body = "Summary:\n\(doc.summary)\n\nOCR (first 200 chars):\n\(ocrPrefix)"
                } else {
                    body = "OCR (first 200 chars):\n\(ocrPrefix)"
                }
            } else {
                body = String(doc.content.prefix(maxCharsPerDoc))
            }

            return """
            Document: \(doc.title)
            Type: \(doc.type.rawValue)
            Category: \(doc.category.rawValue)
            Keywords: \(doc.keywordsResume)
            Excerpt:\n\(body)
            ---
            """
        }.joined(separator: "\n")
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
    
    private func isDocumentQuery(_ query: String) -> Bool {
        let lowercaseQuery = query.lowercased()
        
        // Keywords that suggest the user wants document-based information
        let documentKeywords = [
            // Direct document references
            "document", "file", "pdf", "page", "summary", "summarize", "summery",
            
            // Query patterns about content
            "what does", "explain", "according to", "based on", "in the document", 
            "in the file", "tell me about", "what is", "how does", "what are",
            
            // Search and analysis terms  
            "find", "search", "look for", "show me", "content", "text", "information",
            
            // Analysis and interpretation
            "analyze", "review", "extract", "main points", "key points", "details",
            "meaning", "interpretation", "context", "reference", "mentions"
        ]
        
        // Check if query contains any document-related keywords
        let hasDocumentKeywords = documentKeywords.contains { lowercaseQuery.contains($0) }
        
        // Check for question patterns that typically relate to documents
        let questionPatterns = [
            "what", "how", "why", "when", "where", "who", "which"
        ]
        let hasQuestionPattern = questionPatterns.contains { lowercaseQuery.hasPrefix($0) }
        
        // If it's a question and user has documents, it's likely document-related
        // Or if it explicitly contains document keywords
        return hasDocumentKeywords || (hasQuestionPattern && !documentManager.documents.isEmpty)
    }
    
    private func isDetailedDocumentQuery(_ query: String) -> Bool {
        let lowercaseQuery = query.lowercased()
        
        // Keywords that suggest the user wants detailed analysis or specific information
        let detailedKeywords = [
            "detailed", "details", "specific", "exactly", "quote", "extract", "analyze",
            "full text", "complete", "entire", "all", "everything", "comprehensive",
            "step by step", "thorough", "in-depth", "precise", "exact", "word for word"
        ]
        
        return detailedKeywords.contains { lowercaseQuery.contains($0) }
    }
}

struct ChatScopePickerView: View {
    @Binding var selectedDocIds: [UUID]
    @Binding var selectedFolderId: UUID?
    let folders: [DocumentFolder]
    let documents: [Document]

    @Environment(\.dismiss) private var dismiss
    @State private var showDocLimitAlert = false
    private struct FolderRowItem: Identifiable {
        let id: UUID
        let folder: DocumentFolder
        let level: Int
    }

    var body: some View {
        NavigationView {
            List {
                Section("Scope") {
                    Button {
                        selectedFolderId = nil
                        selectedDocIds = []
                    } label: {
                        HStack {
                            Text("All Documents")
                            Spacer()
                            if selectedFolderId == nil && selectedDocIds.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                Section("Folder") {
                    let flattened = flattenedFolders()
                    if flattened.isEmpty {
                        Text("No folders")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(flattened) { row in
                            Button {
                                selectedFolderId = row.folder.id
                                selectedDocIds = []
                            } label: {
                                HStack {
                                    Text(row.folder.name)
                                        .padding(.leading, CGFloat(row.level) * 12)
                                    Spacer()
                                    if selectedFolderId == row.folder.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Documents (up to 3)") {
                    if documents.isEmpty {
                        Text("No documents")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documents) { doc in
                            Button {
                                toggleDocSelection(doc.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(doc.title)
                                        if let folderName = folderName(for: doc.folderId) {
                                            Text(folderName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedDocIds.contains(doc.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .disabled(selectedFolderId != nil)
                        }
                    }
                }
            }
            .navigationTitle("Chat Scope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Up to 3 documents", isPresented: $showDocLimitAlert) {
                Button("OK") {}
            } message: {
                Text("Select up to three documents or choose a folder.")
            }
        }
    }

    private func sortedFolders(in parentId: UUID?) -> [DocumentFolder] {
        folders
            .filter { $0.parentId == parentId }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.dateCreated < b.dateCreated
            }
    }

    private func flattenedFolders() -> [FolderRowItem] {
        var out: [FolderRowItem] = []
        func walk(parentId: UUID?, level: Int) {
            for folder in sortedFolders(in: parentId) {
                out.append(FolderRowItem(id: folder.id, folder: folder, level: level))
                walk(parentId: folder.id, level: level + 1)
            }
        }
        walk(parentId: nil, level: 0)
        return out
    }

    private func folderName(for folderId: UUID?) -> String? {
        guard let folderId else { return nil }
        return folders.first(where: { $0.id == folderId })?.name
    }

    private func toggleDocSelection(_ docId: UUID) {
        if let idx = selectedDocIds.firstIndex(of: docId) {
            selectedDocIds.remove(at: idx)
            return
        }

        if selectedDocIds.count >= 3 {
            showDocLimitAlert = true
            return
        }

        selectedFolderId = nil
        selectedDocIds.append(docId)
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
            .font(.body)
            .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(msg.role == "user" ? Color.accentColor : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(msg.role == "user" ? Color.clear : Color(.separator), lineWidth: msg.role == "user" ? 0 : 0.5)
            )
    }
}

