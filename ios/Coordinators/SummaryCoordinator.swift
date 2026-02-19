import Foundation
import Combine
import OSLog

class SummaryCoordinator: ObservableObject {
    private let documentManager: DocumentManager
    private var cancellables = Set<AnyCancellable>()

    @Published private(set) var summaryRequestsInFlight: Set<UUID> = []
    private var summaryQueue: [SummaryJob] = []
    private var isSummarizing = false
    private var currentSummaryDocId: UUID?
    private var canceledSummaryIds: Set<UUID> = []

    private struct SummaryJob: Equatable {
        let documentId: UUID
        let prompt: String
        let force: Bool
    }

    init(documentManager: DocumentManager) {
        self.documentManager = documentManager

        NotificationCenter.default.publisher(for: NSNotification.Name("GenerateDocumentSummary"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleGenerateNotification(notification)
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: NSNotification.Name("CancelDocumentSummary"))
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                self?.handleCancelNotification(notification)
            }
            .store(in: &cancellables)
    }

    // MARK: - Public

    func autoSummarizeOnAppear() {
        for doc in documentManager.documents
        where isSummaryPlaceholder(doc.summary) && shouldAutoSummarize(doc) {
            documentManager.generateSummary(for: doc)
        }
    }

    func generateMissingTagsIfNeeded() {
        for doc in documentManager.documents {
            if !doc.tags.isEmpty { continue }
            if !shouldAutoTag(doc) { continue }
            documentManager.generateTags(for: doc)
        }
    }

    func generateMissingKeywordsIfNeeded() {
        for doc in documentManager.documents {
            if !doc.keywordsResume.isEmpty { continue }
            if !shouldAutoTag(doc) { continue }  // same eligibility rules as tags
            documentManager.generateKeywords(for: doc)
        }
    }

    // MARK: - Notification Handlers

    private func handleGenerateNotification(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let idString = userInfo["documentId"] as? String,
              let prompt = userInfo["prompt"] as? String,
              let docId = UUID(uuidString: idString) else {
            return
        }
        let force = (userInfo["force"] as? Bool) ?? false
        AppLogger.ai.debug("Received GenerateDocumentSummary for \(docId), force=\(force), promptLength=\(prompt.count)")

        if !force && summaryRequestsInFlight.contains(docId) {
            return
        }
        if !force, let doc = documentManager.getDocument(by: docId),
           (!isSummaryPlaceholder(doc.summary) || !shouldAutoSummarize(doc)) {
            return
        }

        summaryQueue.removeAll { $0.documentId == docId }
        let job = SummaryJob(documentId: docId, prompt: prompt, force: force)
        summaryQueue.append(job)
        processNextSummaryIfNeeded()
    }

    private func handleCancelNotification(_ notification: Notification) {
        guard let idString = notification.userInfo?["documentId"] as? String,
              let docId = UUID(uuidString: idString) else { return }

        if let idx = summaryQueue.firstIndex(where: { $0.documentId == docId }) {
            summaryQueue.remove(at: idx)
        }

        if currentSummaryDocId == docId {
            canceledSummaryIds.insert(docId)
        }
    }

    // MARK: - EdgeAI Async Wrapper

    private func generateWithEdgeAI(_ edgeAI: EdgeAI, prompt: String) async -> String? {
        await withCheckedContinuation { continuation in
            edgeAI.generate(prompt, resolver: { result in
                let text = (result as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                continuation.resume(returning: text.isEmpty ? nil : text)
            }, rejecter: { _, _, _ in
                continuation.resume(returning: nil)
            })
        }
    }

    // MARK: - Summary Pipeline

    private func processNextSummaryIfNeeded() {
        guard !isSummarizing else { return }
        guard let next = summaryQueue.first else { return }
        guard let doc = documentManager.getDocument(by: next.documentId),
              (next.force || (isSummaryPlaceholder(doc.summary) && shouldAutoSummarize(doc))) else {
            summaryQueue.removeFirst()
            processNextSummaryIfNeeded()
            return
        }
        AppLogger.ai.debug("Starting summary generation for \(next.documentId), force=\(next.force)")

        isSummarizing = true
        currentSummaryDocId = next.documentId
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": true, "documentId": next.documentId.uuidString]
        )
        summaryRequestsInFlight.insert(next.documentId)

        guard let edgeAI = EdgeAI.shared else {
            summaryRequestsInFlight.remove(next.documentId)
            finishSummary(for: next.documentId)
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runSummaryGeneration(edgeAI: edgeAI, job: next)
        }
    }

    @MainActor
    private func runSummaryGeneration(edgeAI: EdgeAI, job: SummaryJob) async {
        let docId = job.documentId

        guard let raw = await generateWithEdgeAI(edgeAI, prompt: job.prompt) else {
            summaryRequestsInFlight.remove(docId)
            finishSummary(for: docId)
            return
        }

        guard !canceledSummaryIds.contains(docId) else {
            summaryRequestsInFlight.remove(docId)
            finishSummary(for: docId)
            return
        }

        let finalText = cleanedSummaryText(raw)

        if !canceledSummaryIds.contains(docId), !finalText.isEmpty {
            documentManager.updateSummary(for: docId, to: finalText)
        }

        summaryRequestsInFlight.remove(docId)
        finishSummary(for: docId)
    }

    private func finishSummary(for documentId: UUID) {
        canceledSummaryIds.remove(documentId)

        if let idx = summaryQueue.firstIndex(where: { $0.documentId == documentId }) {
            summaryQueue.remove(at: idx)
        } else if !summaryQueue.isEmpty {
            summaryQueue.removeFirst()
        }

        isSummarizing = false
        currentSummaryDocId = nil
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": false, "documentId": documentId.uuidString]
        )
        processNextSummaryIfNeeded()
    }

    // MARK: - Helpers

    func isSummaryPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ||
            trimmed == "Processing..." ||
            trimmed == "Processing summary..." ||
            trimmed.contains("Processing summary")
    }

    private func shouldAutoSummarize(_ doc: Document) -> Bool {
        if doc.type == .zip { return false }
        let summaryText = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if isSummaryPlaceholder(summaryText) {
            return true
        }
        if let sourceId = doc.sourceDocumentId,
           documentManager.getDocument(by: sourceId) != nil {
            return false
        }
        return true
    }

    private func shouldAutoTag(_ doc: Document) -> Bool {
        if let sourceId = doc.sourceDocumentId,
           documentManager.getDocument(by: sourceId) != nil {
            return false
        }
        if doc.type == .zip {
            return false
        }
        return true
    }

    private func cleanedSummaryText(_ text: String) -> String {
        // Delegate stripping of echoed cues and excessive blank lines to AIService
        let stripped = AIService.shared.cleanSummaryOutput(text)

        // Right-trim each line only (preserve leading bullets/indents)
        let lines = stripped.components(separatedBy: "\n")
            .map { $0.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }

        // Rebuild: allow at most one consecutive blank line; preserve bullets and paragraph breaks
        var output: [String] = []
        var consecutiveBlanks = 0
        for line in lines {
            if line.isEmpty {
                consecutiveBlanks += 1
                if consecutiveBlanks <= 1 { output.append("") }
            } else {
                consecutiveBlanks = 0
                output.append(line)
            }
        }

        while output.first?.isEmpty == true { output.removeFirst() }
        while output.last?.isEmpty == true  { output.removeLast() }
        return output.joined(separator: "\n")
    }
}
