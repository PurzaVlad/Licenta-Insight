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
    @State private var input: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating: Bool = false
    @State private var isThinkingPulseOn: Bool = false
    @State private var activeChatGenerationId: UUID? = nil
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var showingSettings = false
    @State private var showingScopePicker = false
    @State private var scopedDocumentIds: Set<UUID> = []

    private let inputLineHeight: CGFloat = 22
    private let inputMinLines = 1
    private let inputMaxLines = 6
    @State private var inputHeight: CGFloat = 22
    private let inputMaxCornerRadius: CGFloat = 25
    private let inputMinCornerRadius: CGFloat = 12

    // Preprompt (edit this text to change assistant behavior)
    private let chatPreprompt = """
    You are VaultAI, a deeply helpful, proactive, and concise assistant.
    You can use the ACTIVE_CONTEXT below, which includes folder structure, document titles, summaries, categories, keywords, and full extracted/OCR text for selected files.
    Do not reveal internal reasoning, analysis, or chain-of-thought. Provide the final answer only.
    Use the provided context and recent chat. If the context is insufficient, ask a brief clarifying question.
    Be helpful and to the point; answer concisely unless the user explicitly asks for deep detail.
    When you use document content, cite the document title inline.
    Never say you "can't access" information; instead ask for the missing document or clarification.
    Prefer precise facts from the context over speculation. If unsure, ask a question.
    Focus heavily on document-based answers. If relevant info exists in documents, use it as the primary source.
    If multiple documents match, either compare/summarize both briefly and ask which to focus on, or ask the user to choose.
    Keep balance: avoid excessive questions; keep answers grounded and concise.
    """
    private let historyLimit = 4
    private let selectionMaxDocs = 18

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
            }
            .sheet(isPresented: $showingScopePicker) {
                ScopePickerSheet(
                    documents: documentManager.documents,
                    selectedIds: $scopedDocumentIds
                )
            }
            .safeAreaInset(edge: .bottom) {
                inputBar
            }
        }
    }

    private var scopedDocuments: [Document] {
        documentManager.documents.filter { scopedDocumentIds.contains($0.id) }
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
                    .foregroundColor(isScopeActive ? Color("Primary") : .primary)
                    .frame(width: 44, height: 44)
                    .background(
                        Group {
                            if isScopeActive {
                                Circle().fill(Color("Primary").opacity(0.12))
                            } else {
                                Circle().fill(.ultraThinMaterial)
                            }
                        }
                    )
                    .overlay(
                        Circle()
                            .stroke(isScopeActive ? Color("Primary") : Color(.systemGray4).opacity(0.35), lineWidth: 1)
                    )
            }

            HStack(spacing: 4) {
                AutoGrowingTextView(
                    text: $input,
                    height: $inputHeight,
                    minHeight: inputLineHeight * CGFloat(inputMinLines),
                    maxHeight: inputLineHeight * CGFloat(inputMaxLines),
                    font: UIFont.systemFont(ofSize: 17),
                    isEditable: !isGenerating
                )
                .frame(height: inputHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .leading) {
                    if input.isEmpty {
                        Text("Ask anything")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 17))
                            .padding(.top, 2)
                    }
                }

                Button {
                    send()
                } label: {
                    Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 30))
                        .foregroundColor(hasText || isGenerating ? Color("Primary") : .gray)
                }
                .disabled(!hasText && !isGenerating)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: inputCornerRadius, style: .continuous)
                    .fill(Color(.systemGroupedBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: inputCornerRadius, style: .continuous)
                            .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 1)
                    )
            )
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
                let reply = try await callChatLLM(edgeAI: edgeAI, question: question)
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    let text = reply.isEmpty ? "(No response)" : reply
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
        if documentManager.documents.isEmpty { return "No documents." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        return documentManager.documents.map { doc in
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

    private func shouldIncludeOCR(question: String) -> Bool {
        let q = cleanLine(question).lowercased()
        let triggers = ["ocr", "text", "verbatim", "quote", "exact", "page", "line", "paragraph"]
        return triggers.contains { q.contains($0) }
    }

    private func buildSelectedDocumentContext(selected: [Document], question: String) -> String {
        if selected.isEmpty { return "No relevant documents selected." }
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        let pathMap = folderPathMap()
        let includeOCR = shouldIncludeOCR(question: question)
        return selected.map { doc in
            let folderPath = doc.folderId.flatMap { pathMap[$0] } ?? "Root"
            let maxChars = 50000
            let contentText = String(doc.content.prefix(maxChars))
            let ocrText = includeOCR ? (doc.ocrPages.map { buildStructuredOCRText(from: $0) } ?? "") : ""
            let trimmedOCR = includeOCR ? String(ocrText.prefix(maxChars)) : ""
            return """
            DocId: \(doc.id.uuidString)
            Title: \(doc.title)
            Folder: \(folderPath)
            Type: \(doc.type.rawValue)
            Tags: \(doc.tags.joined(separator: ", "))
            Date: \(formatter.string(from: doc.dateCreated))
            Summary: \(doc.summary)

            Content:
            \(contentText)

            OCR:
            \(trimmedOCR)
            """
        }.joined(separator: "\n---\n")
    }

    private func buildSelectionPrompt(question: String) -> String {
        let recent = recentChatContext(excludingLastUser: true, question: question)
        let folders = buildFolderIndex()
        let docs = buildDocumentIndex()
        return """
        SYSTEM:
        You are selecting possibly relevant documents for a user question.
        Use only the doc index below (tags, titles, folder info).
        Think about the subject and include borderline matches to avoid missing relevant files.
        Detect topic shifts: if the current question is about a different topic than recent chat, prefer fresh matches and avoid sticking to prior documents.
        If the question is broad, include a wider set of possibly relevant docs.
        If the question is about app stats (counts, totals, number of documents/folders), return an empty array.
        Output ONLY valid JSON in this exact shape:
        {"include_ids":["UUID", "..."]}
        If none match, return an empty array.

        RECENT_CHAT:
        \(recent)

        FOLDERS:
        \(folders)

        DOC_INDEX:
        \(docs)

        QUESTION:
        \(question)
        """
    }

    private func extractFirstJSONObject(from text: String) -> String? {
        guard let start = text.firstIndex(of: "{"),
              let end = text.lastIndex(of: "}") else { return nil }
        return String(text[start...end])
    }

    private func parseSelectionIds(_ text: String, question: String, allDocs: [Document]) -> [UUID] {
        struct Selection: Decodable { let include_ids: [String] }
        if let json = extractFirstJSONObject(from: text),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(Selection.self, from: data) {
            let ids = decoded.include_ids.compactMap { UUID(uuidString: $0) }
            return ids
        }

        let uuidPattern = "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}"
        if let regex = try? NSRegularExpression(pattern: uuidPattern) {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            let matches = regex.matches(in: text, range: range)
            let ids = matches.compactMap { match -> UUID? in
                guard let r = Range(match.range, in: text) else { return nil }
                return UUID(uuidString: String(text[r]))
            }
            if !ids.isEmpty { return ids }
        }

        let questionTokens = Set(
            cleanLine(question)
                .lowercased()
                .split(separator: " ")
                .map(String.init)
                .filter { $0.count > 3 }
        )
        if questionTokens.isEmpty { return allDocs.map(\.id) }
        return allDocs.filter { doc in
            let tagText = doc.tags.joined(separator: " ")
            let haystack = "\(doc.title) \(tagText)".lowercased()
            return questionTokens.contains { haystack.contains($0) }
        }.map(\.id)
    }

    private func fallbackSelection(question: String, allDocs: [Document]) -> [Document] {
        if allDocs.isEmpty { return [] }
        let q = cleanLine(question).lowercased()
        let tokens = q.split(separator: " ").map(String.init).filter { $0.count > 3 }
        let scored = allDocs.map { doc -> (Document, Int) in
            let tagText = doc.tags.joined(separator: " ")
            let haystack = "\(doc.title) \(tagText)".lowercased()
            var score = 0
            for t in tokens where haystack.contains(t) { score += 1 }
            if !tokens.isEmpty && score == 0 { score = 0 }
            return (doc, score)
        }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return a.0.dateCreated > b.0.dateCreated
        }
        let top = sorted.prefix(6).map { $0.0 }
        return top.isEmpty ? Array(allDocs.prefix(6)) : top
    }

    private func buildAnswerPrompt(question: String, selectedDocs: [Document]) -> String {
        let recent = recentChatContext(excludingLastUser: true, question: question)
        let recentExchange = recentExchangeContext(question: question)
        let folders = buildFolderIndex()
        let selectedContext = buildSelectedDocumentContext(selected: selectedDocs, question: question)
        return """
        SYSTEM:
        \(chatPreprompt)
        Always prioritize the user's latest message as the primary instruction and topic.
        Give a concise, document-first response. Prefer facts from the selected documents.
        If multiple documents clearly match, mention both briefly and ask which one to focus on, or ask a single clarifying question.
        If the question is broad, surface the most relevant facts from the selected documents and folders.
        If there is not enough info, ask for the missing document or a clarifying detail.
        Assume relevant information is likely in the documents; prioritize using them over generic responses.

        RECENT_CHAT:
        \(recent)

        RECENT_EXCHANGE:
        \(recentExchange)

        ACTIVE_CONTEXT:
        FOLDERS:
        \(folders)

        DOCUMENTS:
        \(selectedContext)

        USER_QUESTION:
        \(question)
        """
    }

    private func buildPrompt(for question: String) -> String {
        """
        SYSTEM:
        \(chatPreprompt)

        USER:
        \(question)
        """
    }

    private func callChatLLM(edgeAI: EdgeAI, question: String) async throws -> String {
        if let statsAnswer = buildStatsAnswerIfNeeded(for: question) {
            return statsAnswer
        }

        if !scopedDocumentIds.isEmpty {
            var scopedDocs = documentManager.documents.filter { scopedDocumentIds.contains($0.id) }
            if scopedDocs.count > selectionMaxDocs {
                scopedDocs = Array(scopedDocs.prefix(selectionMaxDocs))
            }
            let prompt = buildAnswerPrompt(question: question, selectedDocs: scopedDocs)
            return try await callLLM(edgeAI: edgeAI, prompt: wrapChatPrompt(prompt))
        }

        let selectionPrompt = buildSelectionPrompt(question: question)
        let selectionRaw = try await callLLM(edgeAI: edgeAI, prompt: wrapSelectionPrompt(selectionPrompt))
        let selectedIds = parseSelectionIds(selectionRaw, question: question, allDocs: documentManager.documents)
        var selectedDocs = documentManager.documents.filter { selectedIds.contains($0.id) }
        if selectedDocs.isEmpty {
            selectedDocs = fallbackSelection(question: question, allDocs: documentManager.documents)
        }
        if selectedDocs.count > selectionMaxDocs {
            selectedDocs = Array(selectedDocs.prefix(selectionMaxDocs))
        }

        let prompt = buildAnswerPrompt(question: question, selectedDocs: selectedDocs)
        return try await callLLM(edgeAI: edgeAI, prompt: wrapChatPrompt(prompt))
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

    private func wrapChatPrompt(_ prompt: String) -> String {
        "<<<CHAT_DETAIL>>>" + prompt
    }

    private func wrapSelectionPrompt(_ prompt: String) -> String {
        "<<<CHAT_BRIEF>>>" + prompt
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

    private struct ScopePickerSheet: View {
        let documents: [Document]
        @Binding var selectedIds: Set<UUID>
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationView {
                List {
                    if documents.isEmpty {
                        Text("No documents available.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(documents.sorted { $0.dateCreated > $1.dateCreated }) { document in
                            Button {
                                toggleSelection(document.id)
                            } label: {
                                HStack {
                                    Image(systemName: iconForDocumentType(document.type))
                                        .foregroundColor(Color("Primary"))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(document.title)
                                            .font(.headline)
                                            .lineLimit(1)
                                            .foregroundColor(.primary)
                                        Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selectedIds.contains(document.id) ? "checkmark.circle.fill" : "circle")
                                        .foregroundColor(selectedIds.contains(document.id) ? Color("Primary") : .secondary)
                                }
                                }
                            }
                        }
                }
                .navigationTitle("Scope Documents")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Clear") {
                            selectedIds.removeAll()
                        }
                        .foregroundColor(.primary)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") { dismiss() }
                            .foregroundColor(.primary)
                    }
                }
            }
        }

        private func toggleSelection(_ id: UUID) {
            if selectedIds.contains(id) {
                selectedIds.remove(id)
            } else {
                selectedIds.insert(id)
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
    func scrollDismissesKeyboardIfAvailable() -> some View {
        if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
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
