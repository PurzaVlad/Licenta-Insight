import Foundation
import PDFKit
import UIKit
import Vision
import SSZipArchive
import QuickLookThumbnailing

class DocumentManager: ObservableObject {
    enum SummaryContent: String, CaseIterable {
        case general
    }

    // Constants
    static let summaryUnavailableMessage = "Not available as source file is still available."
    static let ocrUnavailableWhileSourceExistsMessage = "No OCR because source file is still available."
    private var maxOCRChars: Int { AppConstants.Limits.maxOCRChars }

    // Services (injected for testability)
    private let persistenceService: PersistenceService
    private let fileProcessingService: FileProcessingService
    private let ocrService: OCRService
    private let aiService: AIService
    private let validationService: ValidationService

    // Published state
    @Published var documents: [Document] = []
    @Published var folders: [DocumentFolder] = []
    @Published var prefersGridLayout: Bool = false
    @Published private(set) var lastAccessedMap: [UUID: Date] = [:]

    // Private state
    private let sharedInboxImportQueue = DispatchQueue(label: "com.purzavlad.identity.sharedInboxImport", qos: .utility)
    private var isImportingSharedInbox = false

    init(
        persistenceService: PersistenceService = .shared,
        fileProcessingService: FileProcessingService = .shared,
        ocrService: OCRService = .shared,
        aiService: AIService = .shared,
        validationService: ValidationService = .shared
    ) {
        self.persistenceService = persistenceService
        self.fileProcessingService = fileProcessingService
        self.ocrService = ocrService
        self.aiService = aiService
        self.validationService = validationService

        loadDocuments()
        lastAccessedMap = loadLastAccessedMap()
        importSharedInboxIfNeeded()
    }

    func importSharedInboxIfNeeded() {
        guard !isImportingSharedInbox else { return }
        guard let inboxURL = sharedInboxURL(createIfMissing: true) else { return }

        isImportingSharedInbox = true
        sharedInboxImportQueue.async { [weak self] in
            guard let self else { return }

            let fm = FileManager.default
            let urls = (try? fm.contentsOfDirectory(
                at: inboxURL,
                includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            )) ?? []

            let fileURLs = urls.filter { url in
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey])
                return values?.isDirectory != true
            }
            .sorted { a, b in
                let aDate = (try? a.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                let bDate = (try? b.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
                return aDate < bDate
            }

            guard !fileURLs.isEmpty else {
                DispatchQueue.main.async {
                    self.isImportingSharedInbox = false
                }
                return
            }

            var importedDocuments: [Document] = []
            var consumedURLs: [URL] = []
            var invalidURLs: [URL] = []

            for url in fileURLs {
                // Validate file before processing
                do {
                    try ValidationService.shared.validateFile(url)
                } catch {
                    print("⚠️ DocumentManager: Skipping invalid file '\(url.lastPathComponent)': \(error.localizedDescription)")
                    invalidURLs.append(url)
                    continue
                }

                if let document = self.processFile(at: url) {
                    importedDocuments.append(document)
                    consumedURLs.append(url)
                }
            }

            DispatchQueue.main.async {
                for document in importedDocuments {
                    self.addDocument(document)
                }
                for url in consumedURLs {
                    try? fm.removeItem(at: url)
                }
                // Also clean up invalid files
                for url in invalidURLs {
                    try? fm.removeItem(at: url)
                }
                self.isImportingSharedInbox = false
            }
        }
    }


    func updateLastAccessed(id: UUID) {
        lastAccessedMap[id] = Date()
        saveLastAccessedMap()
    }

    func lastAccessedDate(for id: UUID, fallback: Date) -> Date {
        lastAccessedMap[id] ?? fallback
    }

    private func loadLastAccessedMap() -> [UUID: Date] {
        do {
            return try persistenceService.loadLastAccessedMap()
        } catch {
            print("⚠️ DocumentManager: Failed to load last accessed map: \(error.localizedDescription)")
            return [:]
        }
    }

    private func saveLastAccessedMap() {
        do {
            try persistenceService.saveLastAccessedMap(lastAccessedMap)
        } catch {
            print("❌ DocumentManager: Failed to save last accessed map: \(error.localizedDescription)")
        }
    }

    func setPrefersGridLayout(_ value: Bool) {
        guard prefersGridLayout != value else { return }
        prefersGridLayout = value
        saveState()
    }

    enum FolderDeleteMode {
        case deleteAllItems
        case moveItemsToParent
    }

    private func sharedInboxURL(createIfMissing: Bool) -> URL? {
        return persistenceService.getSharedInboxURL(createIfMissing: createIfMissing)
    }

    // 1 = source is deleted/unavailable (or no source); 0 = source still exists.
    func sourceAvailabilityFlag(for document: Document) -> Int {
        if let sourceId = document.sourceDocumentId, getDocument(by: sourceId) != nil {
            return 0
        }
        return 1
    }

    func isConversationEligible(_ document: Document) -> Bool {
        sourceAvailabilityFlag(for: document) == 1
    }

    func conversationEligibleDocuments() -> [Document] {
        documents.filter { isConversationEligible($0) }
    }
    
    // MARK: - Document Management
    
    func addDocument(_ document: Document) {
        print("💾 DocumentManager: Adding document '\\(document.title)' (\\(document.type.rawValue))")
        var updated = Self.withInferredMetadataIfNeeded(document)

        // Replace placeholder summary
        if updated.summary == Self.summaryUnavailableMessage {
            updated = updated.with(summary: "Processing summary...")
        }

        // Truncate content if needed
        if shouldAutoOCR(for: updated.type) && updated.content.count > maxOCRChars {
            let truncated = String(updated.content.prefix(maxOCRChars))
            updated = updated.with(content: truncated).with(ocrPages: buildPseudoOCRPages(from: truncated))
        }

        // Build pseudo-OCR pages if needed
        if updated.ocrPages == nil && shouldAutoOCR(for: updated.type) {
            if let pages = buildPseudoOCRPages(from: updated.content), !pages.isEmpty {
                updated = updated.with(ocrPages: pages)
            }
        }

        // Assign sort order if needed
        if updated.sortOrder == 0 {
            let targetFolder = updated.folderId
            let maxOrder = documents
                .filter { $0.folderId == targetFolder }
                .map { $0.sortOrder }
                .max() ?? -1
            updated = updated.with(sortOrder: maxOrder + 1)
        }

        documents.append(updated)
        print("💾 DocumentManager: Document array now has \\(documents.count) items")
        saveState()
        print("💾 DocumentManager: Document saved successfully")

        generateSummary(for: updated)
        generateTags(for: updated)
    }
    
    func deleteDocument(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        handleSourceDeletion(sourceId: document.id)
        saveState()
    }

    func updateSummary(for documentId: UUID, to newSummary: String) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        let updated = documents[idx].with(summary: newSummary)
        documents[idx] = updated
        saveState()
        if updated.tags.isEmpty {
            generateTags(for: updated)
        }
    }

    func updateContent(for documentId: UUID, to newContent: String) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        documents[idx] = documents[idx].with(content: newContent)
        saveState()
    }

    func updateTags(for documentId: UUID, to newTags: [String]) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        documents[idx] = documents[idx].with(tags: newTags)
        saveState()
    }

    func updateOCRPages(for documentId: UUID, to newPages: [OCRPage]?) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        documents[idx] = documents[idx].with(ocrPages: newPages)
        let updated = documents[idx]
        let chunkPages = updated.ocrChunks.compactMap(\.pageNumber)
        let minChunkPage = chunkPages.min()
        let maxChunkPage = chunkPages.max()
        print(
            "OCR update for doc \(updated.id): " +
            "ocrPages.count=\(updated.ocrPages?.count ?? 0), " +
            "ocrChunks.count=\(updated.ocrChunks.count), " +
            "chunkPageRange=\(minChunkPage.map(String.init) ?? "nil")...\(maxChunkPage.map(String.init) ?? "nil")"
        )
        saveState()
    }

    func updateSourceDocumentId(for documentId: UUID, to newSourceId: UUID?) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        documents[idx] = documents[idx].with(sourceDocumentId: newSourceId)
        saveState()
    }

    func generateTags(for document: Document, force: Bool = false) {
        if !force && !document.tags.isEmpty { return }
        guard let edgeAI = EdgeAI.shared else { return }

        // Use AIService to build the tag prompt
        let (prompt, seedText) = aiService.buildTagPrompt(for: document)

        edgeAI.generate(prompt, resolver: { result in
            DispatchQueue.main.async {
                let raw = (result as? String ?? "")

                // Use AIService to process the tags
                let finalTags = self.aiService.processTags(rawResponse: raw, document: document, seedText: seedText)
                self.updateTags(for: document.id, to: finalTags)
            }
        }, rejecter: { code, message, _ in
            print("❌ DocumentManager: Tag generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
        })
    }

    // MARK: - Folder Management

    func createFolder(name: String, parentId: UUID? = nil) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let maxOrder = folders
            .filter { $0.parentId == parentId }
            .map { $0.sortOrder }
            .max() ?? -1
        folders.append(DocumentFolder(name: trimmed, parentId: parentId, sortOrder: maxOrder + 1))
        saveState()
    }

    func renameFolder(folderId: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let idx = folders.firstIndex(where: { $0.id == folderId }) {
            let old = folders[idx]
            folders[idx] = DocumentFolder(id: old.id, name: trimmed, dateCreated: old.dateCreated, parentId: old.parentId, sortOrder: old.sortOrder)
            saveState()
        }
    }

    func deleteFolder(folderId: UUID, mode: FolderDeleteMode) {
        guard let folder = folders.first(where: { $0.id == folderId }) else { return }
        let parentId = folder.parentId

        switch mode {
        case .moveItemsToParent:
            // Move direct documents to parent.
            let docsToMove = documents(in: folderId)
            for d in docsToMove {
                moveDocument(documentId: d.id, toFolder: parentId)
            }

            // Move direct subfolders to parent.
            let children = folders(in: folderId)
            for child in children {
                moveFolder(folderId: child.id, toParent: parentId)
            }

            // Remove the folder itself.
            folders.removeAll { $0.id == folderId }
            normalizeFolderSortOrders(in: parentId)
            saveState()

        case .deleteAllItems:
            // Delete folder, all descendants, and all documents inside.
            let idsToDelete = descendantFolderIds(includingSelf: folderId)

            documents.removeAll { doc in
                guard let fid = doc.folderId else { return false }
                return idsToDelete.contains(fid)
            }

            folders.removeAll { idsToDelete.contains($0.id) }
            normalizeFolderSortOrders(in: parentId)
            saveState()
        }
    }

    func folders(in parentId: UUID?) -> [DocumentFolder] {
        folders
            .filter { $0.parentId == parentId }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.dateCreated < b.dateCreated
            }
    }

    func moveFolder(folderId: UUID, toParent parentId: UUID?) {
        guard let idx = folders.firstIndex(where: { $0.id == folderId }) else { return }
        let old = folders[idx]
        guard old.parentId != parentId else { return }

        // Prevent cycles (can't move into itself or its descendants).
        let descendants = descendantFolderIds(of: folderId)
        if let parentId, descendants.contains(parentId) || parentId == folderId {
            return
        }

        let maxOrder = folders
            .filter { $0.parentId == parentId && $0.id != old.id }
            .map { $0.sortOrder }
            .max() ?? -1

        folders[idx] = DocumentFolder(
            id: old.id,
            name: old.name,
            dateCreated: old.dateCreated,
            parentId: parentId,
            sortOrder: maxOrder + 1
        )

        normalizeFolderSortOrders(in: old.parentId)
        normalizeFolderSortOrders(in: parentId)
        saveState()
    }

    func descendantFolderIds(of folderId: UUID) -> Set<UUID> {
        var result = Set<UUID>()
        var stack: [UUID] = [folderId]
        while let current = stack.popLast() {
            let children = folders.filter { $0.parentId == current }.map { $0.id }
            for child in children {
                if result.insert(child).inserted {
                    stack.append(child)
                }
            }
        }
        return result
    }

    private func descendantFolderIds(includingSelf folderId: UUID) -> Set<UUID> {
        var ids = descendantFolderIds(of: folderId)
        ids.insert(folderId)
        return ids
    }

    private func normalizeFolderSortOrders(in parentId: UUID?) {
        let bucket = folders(in: parentId)
        for (i, f) in bucket.enumerated() {
            if let idx = folders.firstIndex(where: { $0.id == f.id }) {
                let old = folders[idx]
                if old.sortOrder != i {
                    folders[idx] = DocumentFolder(
                        id: old.id,
                        name: old.name,
                        dateCreated: old.dateCreated,
                        parentId: old.parentId,
                        sortOrder: i
                    )
                }
            }
        }
    }

    func moveDocument(documentId: UUID, toFolder folderId: UUID?) {
        guard let idx = documents.firstIndex(where: { $0.id == documentId }) else { return }
        let old = documents[idx]

        let maxOrder = documents
            .filter { $0.folderId == folderId && $0.id != old.id }
            .map { $0.sortOrder }
            .max() ?? -1

        documents[idx] = old.with(folderId: folderId, sortOrder: maxOrder + 1)
        normalizeSortOrders(in: folderId)
        saveState()
    }

    func reorderDocuments(in folderId: UUID?, draggedId: UUID, targetId: UUID) {
        guard draggedId != targetId else { return }

        var bucket = documents
            .filter { $0.folderId == folderId }
            .sorted { $0.sortOrder < $1.sortOrder }

        guard let from = bucket.firstIndex(where: { $0.id == draggedId }),
              let to = bucket.firstIndex(where: { $0.id == targetId }) else { return }

        let moved = bucket.remove(at: from)
        bucket.insert(moved, at: to)

        // Write back sequential sortOrder
        for (i, doc) in bucket.enumerated() {
            if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
                documents[idx] = documents[idx].with(sortOrder: i)
            }
        }

        saveState()
    }

    func documents(in folderId: UUID?) -> [Document] {
        documents
            .filter { $0.folderId == folderId }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.dateCreated < b.dateCreated
            }
    }

    func folderName(for folderId: UUID?) -> String? {
        guard let folderId else { return nil }
        return folders.first(where: { $0.id == folderId })?.name
    }

    private func normalizeSortOrders(in folderId: UUID?) {
        let bucket = documents(in: folderId)
        for (i, doc) in bucket.enumerated() {
            if let idx = documents.firstIndex(where: { $0.id == doc.id }), documents[idx].sortOrder != i {
                documents[idx] = documents[idx].with(sortOrder: i)
            }
        }
    }

    func getDocument(by id: UUID) -> Document? {
        return documents.first(where: { $0.id == id })
    }

    func refreshContentIfNeeded(for documentId: UUID) {
        guard let doc = getDocument(by: documentId) else { return }
        guard doc.type == .docx else { return }

        // Check if content looks like XML (indicates extraction failure)
        let content = doc.content
        let looksLikeXML = content.contains("<?xml") ||
                          content.contains("<w:") ||
                          content.contains("xmlns") ||
                          content.contains("PK!") ||
                          (content.filter { $0 == "<" }.count > 20 && content.count > 200)

        if looksLikeXML, let data = doc.originalFileData {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("repair_\(doc.id).docx")
            do {
                try data.write(to: tempURL)
                let result = try fileProcessingService.processFile(at: tempURL)
                try? FileManager.default.removeItem(at: tempURL)

                // Check if the new extraction is better
                let newLooksLikeXML = result.content.contains("<?xml") ||
                                     result.content.contains("<w:") ||
                                     result.content.contains("xmlns")

                if !result.content.isEmpty && !newLooksLikeXML {
                    updateContent(for: documentId, to: result.content)
                }
            } catch {
                print("📄 DocumentManager: refresh failed: \(error.localizedDescription)")
            }
        }
    }
    
    func generateSummary(
        for document: Document,
        force: Bool = false,
        length: SummaryLength = .medium,
        content: SummaryContent = .general
    ) {
        if document.type == .zip { return }
        _ = content

        print("🤖 DocumentManager: Generating summary for '\(document.title)'")

        // Use AIService to build the summary prompt
        let prompt = aiService.buildSummaryPrompt(for: document, length: length)

        if force {
            updateSummary(for: document.id, to: "Processing summary...")
        }

        // Send to EdgeAI for processing
        NotificationCenter.default.post(
            name: AppConstants.Notifications.generateDocumentSummary,
            object: nil,
            userInfo: ["documentId": document.id.uuidString, "prompt": prompt, "force": force]
        )
    }
    
    func getAllDocumentContent() -> String {
        print("🤖 DocumentManager: Getting all document content, document count: \(documents.count)")
        return aiService.getAllDocumentContent(from: documents)
    }

    func getDocumentSummaries() -> String {
        print("🤖 DocumentManager: Getting document summaries, document count: \(documents.count)")
        return aiService.getDocumentSummaries(from: documents)
    }

    func getSmartDocumentContext() -> String {
        print("🤖 DocumentManager: Getting smart document context, document count: \(documents.count)")
        return aiService.getSmartDocumentContext(from: documents)
    }
    
    // MARK: - File Processing

    func processFile(at url: URL) -> Document? {
        print("📄 DocumentManager: Processing file at \(url.lastPathComponent)")

        // Try to start accessing security scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        do {
            // Use FileProcessingService to process the file
            let result = try fileProcessingService.processFile(at: url)

            let docId = UUID()
            var content = result.content
            var ocrPages = result.ocrPages

            // Truncate if needed
            if content.count > AppConstants.Limits.maxOCRChars {
                content = String(content.prefix(AppConstants.Limits.maxOCRChars))
            }

            // Build pseudo-OCR pages if needed
            if ocrPages == nil && shouldAutoOCR(for: result.documentType) {
                ocrPages = buildPseudoOCRPages(from: content)
            }

            let baseDocument = Document(
                id: docId,
                title: url.lastPathComponent,
                content: content,
                summary: "Processing...",
                ocrPages: ocrPages,
                category: .general,
                keywordsResume: "",
                tags: [],
                sourceDocumentId: nil,
                dateCreated: Date(),
                type: result.documentType,
                imageData: result.imageData,
                pdfData: result.pdfData,
                originalFileData: result.originalFileData
            )

            print("📄 DocumentManager: ✅ Document created successfully:")
            print("📄 DocumentManager:   - Title: \(baseDocument.title)")
            print("📄 DocumentManager:   - Type: \(baseDocument.type.rawValue)")
            print("📄 DocumentManager:   - Content length: \(baseDocument.content.count)")

            return baseDocument
        } catch {
            print("❌ DocumentManager: Failed to process file: \(error.localizedDescription)")
            return nil
        }
    }
    
    // MARK: - OCR Helper Methods

    private func extractTextFromImageDetailed(url: URL) -> (text: String, pages: [OCRPage]?) {
        return ocrService.extractTextFromImage(at: url)
    }

    func buildVisionOCRPages(from data: Data, type: Document.DocumentType) -> [OCRPage]? {
        return ocrService.buildVisionOCRPages(from: data, type: type)
    }
    
    // MARK: - Persistence

    private func saveState() {
        do {
            try persistenceService.saveDocuments(documents, folders: folders, prefersGridLayout: prefersGridLayout)
            print("💾 DocumentManager: Successfully saved \(documents.count) documents + \(folders.count) folders")
        } catch {
            print("❌ DocumentManager: Failed to save documents: \(error.localizedDescription)")
        }
    }
    
    private func loadDocuments() {
        do {
            let loaded = try persistenceService.loadDocuments()
            let backfilled = loaded.documents.map { Self.withBackfilledMetadata($0) }
            self.documents = backfilled
            self.folders = loaded.folders
            self.prefersGridLayout = loaded.prefersGridLayout

            backfillSortOrdersIfNeeded()
            backfillFolderSortOrdersIfNeeded()

            print("💾 DocumentManager: Successfully loaded \(documents.count) documents + \(folders.count) folders")

            // Persist backfilled metadata/order if needed
            if zip(loaded.documents, backfilled).contains(where: { $0.keywordsResume != $1.keywordsResume || $0.category != $1.category }) {
                saveState()
            }
        } catch {
            print("❌ DocumentManager: Failed to load documents: \(error.localizedDescription)")
            self.documents = []
            self.folders = []
            self.prefersGridLayout = false
        }
    }

    private func backfillSortOrdersIfNeeded() {
        // If everything is 0 (legacy), assign stable ordering within each folder bucket
        let hasAnyNonZero = documents.contains(where: { $0.sortOrder != 0 })
        if hasAnyNonZero { return }

        // Preserve current array order within each folder bucket
        let grouped = Dictionary(grouping: documents, by: { $0.folderId })
        for (folderId, bucket) in grouped {
            for (i, doc) in bucket.enumerated() {
                if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
                    documents[idx] = documents[idx].with(sortOrder: i)
                }
            }
            normalizeSortOrders(in: folderId)
        }
    }

    private func backfillFolderSortOrdersIfNeeded() {
        // If everything is 0 (legacy), assign stable ordering within each parent bucket.
        let hasAnyNonZero = folders.contains(where: { $0.sortOrder != 0 })
        if hasAnyNonZero { return }

        let grouped = Dictionary(grouping: folders, by: { $0.parentId })
        for (parentId, bucket) in grouped {
            let stable = bucket.sorted { a, b in a.dateCreated < b.dateCreated }
            for (i, f) in stable.enumerated() {
                if let idx = folders.firstIndex(where: { $0.id == f.id }) {
                    let old = folders[idx]
                    folders[idx] = DocumentFolder(
                        id: old.id,
                        name: old.name,
                        dateCreated: old.dateCreated,
                        parentId: old.parentId,
                        sortOrder: i
                    )
                }
            }
            normalizeFolderSortOrders(in: parentId)
        }
        saveState()
    }
    
    // MARK: - Search and Query
    
    func searchDocuments(query: String) -> [Document] {
        let lowercaseQuery = query.lowercased()
        return documents.filter { document in
            document.title.lowercased().contains(lowercaseQuery) ||
            document.content.lowercased().contains(lowercaseQuery) ||
            document.summary.lowercased().contains(lowercaseQuery) ||
            document.category.rawValue.lowercased().contains(lowercaseQuery) ||
            document.keywordsResume.lowercased().contains(lowercaseQuery) ||
            document.tags.joined(separator: " ").lowercased().contains(lowercaseQuery)
        }
    }

    // MARK: - Auto Categorization + Keywords

    private static func withInferredMetadataIfNeeded(_ doc: Document) -> Document {
        // All documents use general category
        return doc
    }

    private static func withBackfilledMetadata(_ doc: Document) -> Document {
        withInferredMetadataIfNeeded(doc)
    }



    static func inferCategory(title: String, content: String, summary: String) -> Document.DocumentCategory {
        return .general
    }

    static func makeKeywordsResume(title: String, content: String, summary: String) -> String {
        return ""
    }


    private func shouldAutoOCR(for type: Document.DocumentType) -> Bool {
        switch type {
        case .pdf, .docx, .ppt, .pptx, .xls, .text, .scanned:
            return true
        case .xlsx, .image:
            return false
        case .zip:
            return false
        }
    }

    private func buildPseudoOCRPages(from text: String) -> [OCRPage]? {
        let pages = ocrService.buildPseudoOCRPages(from: text)
        return pages.isEmpty ? nil : pages
    }

    private func handleSourceDeletion(sourceId: UUID) {
        let derived = documents.filter { $0.sourceDocumentId == sourceId }
        for doc in derived {
            if shouldAutoOCR(for: doc.type) && (doc.ocrPages == nil || doc.ocrPages?.isEmpty == true) {
                let trimmed = String(doc.content.prefix(maxOCRChars))
                let pages = buildPseudoOCRPages(from: trimmed)
                if let pages = pages, !pages.isEmpty {
                    updateOCRPages(for: doc.id, to: pages)
                }
            }
            updateSourceDocumentId(for: doc.id, to: nil)
            let updated = getDocument(by: doc.id) ?? doc
            if updated.tags.isEmpty {
                generateTags(for: updated)
            }
            if updated.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                updated.summary == "Processing..." ||
                updated.summary == "Processing summary..." ||
                updated.summary == Self.summaryUnavailableMessage {
                generateSummary(for: updated)
            }
        }
    }
}
