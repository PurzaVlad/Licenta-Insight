import Foundation
import PDFKit
import UIKit
import Vision
import SSZipArchive
import QuickLookThumbnailing

class DocumentManager: ObservableObject {
    enum SummaryLength: String, CaseIterable {
        case short
        case medium
        case long
    }

    enum SummaryContent: String, CaseIterable {
        case general
        case finance
        case legal
        case academic
        case medical
    }

    static let summaryUnavailableMessage = "Not available as source file is still available."
    static let ocrUnavailableWhileSourceExistsMessage = "No OCR because source file is still available."
    private static let appGroupIdentifier = "group.com.purzavlad.identity"
    private static let sharedInboxFolderName = "ShareInbox"
    @Published var documents: [Document] = []
    @Published var folders: [DocumentFolder] = []
    @Published var prefersGridLayout: Bool = false
    @Published private(set) var lastAccessedMap: [UUID: Date] = [:]
    private let maxOCRChars = 50000
    private let documentsKey = "SavedDocuments_v2" // legacy (migration only)
    private let documentsFileName = "SavedDocuments_v2.json"
    private let lastAccessedKey = "LastAccessedMap_v1"
    private let sharedInboxImportQueue = DispatchQueue(label: "com.purzavlad.identity.sharedInboxImport", qos: .utility)
    private var isImportingSharedInbox = false

    private struct PersistedState: Codable {
        var documents: [Document]
        var folders: [DocumentFolder]
        var prefersGridLayout: Bool
    }
    
    init() {
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

            for url in fileURLs {
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
        guard let data = UserDefaults.standard.data(forKey: lastAccessedKey) else { return [:] }
        do {
            let raw = try JSONDecoder().decode([String: Date].self, from: data)
            var map: [UUID: Date] = [:]
            for (key, value) in raw {
                if let id = UUID(uuidString: key) {
                    map[id] = value
                }
            }
            return map
        } catch {
            return [:]
        }
    }

    private func saveLastAccessedMap() {
        let raw = Dictionary(uniqueKeysWithValues: lastAccessedMap.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(raw) {
            UserDefaults.standard.set(data, forKey: lastAccessedKey)
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

    private func documentsFileURL() -> URL {
        // Use Application Support instead of UserDefaults (NSUserDefaults has a ~4MB limit).
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Identity", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(documentsFileName)
    }

    private func sharedInboxURL(createIfMissing: Bool) -> URL? {
        guard let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
        ) else {
            return nil
        }

        let inbox = container.appendingPathComponent(Self.sharedInboxFolderName, isDirectory: true)
        if createIfMissing && !FileManager.default.fileExists(atPath: inbox.path) {
            try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        }
        return inbox
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

        if updated.summary == Self.summaryUnavailableMessage {
            updated = Document(
                id: updated.id,
                title: updated.title,
                content: updated.content,
                summary: "Processing summary...",
                ocrPages: updated.ocrPages,
                category: updated.category,
                keywordsResume: updated.keywordsResume,
                tags: updated.tags,
                sourceDocumentId: updated.sourceDocumentId,
                dateCreated: updated.dateCreated,
                folderId: updated.folderId,
                sortOrder: updated.sortOrder,
                type: updated.type,
                imageData: updated.imageData,
                pdfData: updated.pdfData,
                originalFileData: updated.originalFileData
            )
        }

        if shouldAutoOCR(for: updated.type) {
            if updated.content.count > maxOCRChars {
                let truncated = Self.truncateText(updated.content, maxChars: maxOCRChars)
                updated = Document(
                    id: updated.id,
                    title: updated.title,
                    content: truncated,
                    summary: updated.summary,
                    ocrPages: buildPseudoOCRPages(from: truncated),
                    category: updated.category,
                    keywordsResume: updated.keywordsResume,
                    tags: updated.tags,
                    sourceDocumentId: updated.sourceDocumentId,
                    dateCreated: updated.dateCreated,
                    folderId: updated.folderId,
                    sortOrder: updated.sortOrder,
                    type: updated.type,
                    imageData: updated.imageData,
                    pdfData: updated.pdfData,
                    originalFileData: updated.originalFileData
                )
            }
        }

        if updated.ocrPages == nil && shouldAutoOCR(for: updated.type) {
            let pages = buildPseudoOCRPages(from: updated.content)
            if let pages = pages, !pages.isEmpty {
                updated = Document(
                    id: updated.id,
                    title: updated.title,
                    content: updated.content,
                    summary: updated.summary,
                    ocrPages: pages,
                    category: updated.category,
                    keywordsResume: updated.keywordsResume,
                    tags: updated.tags,
                    sourceDocumentId: updated.sourceDocumentId,
                    dateCreated: updated.dateCreated,
                    folderId: updated.folderId,
                    sortOrder: updated.sortOrder,
                    type: updated.type,
                    imageData: updated.imageData,
                    pdfData: updated.pdfData,
                    originalFileData: updated.originalFileData
                )
            }
        }

        // Assign ordering at the end of the target container (root by default).
        if updated.sortOrder == 0 {
            let targetFolder = updated.folderId
            let maxOrder = documents
                .filter { $0.folderId == targetFolder }
                .map { $0.sortOrder }
                .max() ?? -1
            updated = Document(
                id: updated.id,
                title: updated.title,
                content: updated.content,
                summary: updated.summary,
                ocrPages: updated.ocrPages,
                category: updated.category,
                keywordsResume: updated.keywordsResume,
                tags: updated.tags,
                sourceDocumentId: updated.sourceDocumentId,
                dateCreated: updated.dateCreated,
                folderId: updated.folderId,
                sortOrder: maxOrder + 1,
                type: updated.type,
                imageData: updated.imageData,
                pdfData: updated.pdfData,
                originalFileData: updated.originalFileData
            )
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
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: old.content,
                summary: newSummary,
                ocrPages: old.ocrPages,
                category: old.category,
                keywordsResume: old.keywordsResume,
                tags: old.tags,
                sourceDocumentId: old.sourceDocumentId,
                dateCreated: old.dateCreated,
                folderId: old.folderId,
                sortOrder: old.sortOrder,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveState()
            if updated.tags.isEmpty {
                generateTags(for: updated)
            }
        }
    }

    func updateContent(for documentId: UUID, to newContent: String) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: newContent,
                summary: old.summary,
                ocrPages: old.ocrPages,
                category: old.category,
                keywordsResume: old.keywordsResume,
                tags: old.tags,
                sourceDocumentId: old.sourceDocumentId,
                dateCreated: old.dateCreated,
                folderId: old.folderId,
                sortOrder: old.sortOrder,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveState()
        }
    }

    func updateTags(for documentId: UUID, to newTags: [String]) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: old.content,
                summary: old.summary,
                ocrPages: old.ocrPages,
                category: old.category,
                keywordsResume: old.keywordsResume,
                tags: newTags,
                sourceDocumentId: old.sourceDocumentId,
                dateCreated: old.dateCreated,
                folderId: old.folderId,
                sortOrder: old.sortOrder,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveState()
        }
    }

    func updateOCRPages(for documentId: UUID, to newPages: [OCRPage]?) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: old.content,
                summary: old.summary,
                ocrPages: newPages,
                category: old.category,
                keywordsResume: old.keywordsResume,
                tags: old.tags,
                sourceDocumentId: old.sourceDocumentId,
                dateCreated: old.dateCreated,
                folderId: old.folderId,
                sortOrder: old.sortOrder,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveState()
        }
    }

    func updateSourceDocumentId(for documentId: UUID, to newSourceId: UUID?) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: old.content,
                summary: old.summary,
                ocrPages: old.ocrPages,
                category: old.category,
                keywordsResume: old.keywordsResume,
                tags: old.tags,
                sourceDocumentId: newSourceId,
                dateCreated: old.dateCreated,
                folderId: old.folderId,
                sortOrder: old.sortOrder,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveState()
        }
    }

    func generateTags(for document: Document, force: Bool = false) {
        if !force && !document.tags.isEmpty { return }
        guard let edgeAI = EdgeAI.shared else { return }

        var seed = ""
        var pagesForTags = document.ocrPages
        if let pages = pagesForTags, !pages.isEmpty {
            let ocrText = Self.buildStructuredText(from: pages, includePageLabels: false)
            if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                seed = ocrText
            }
        }
        if seed.isEmpty {
            let wantsVisionOCR = document.type == .pdf || document.type == .scanned
            if wantsVisionOCR {
                var dataForOCR: Data?
                var ocrType: Document.DocumentType = .pdf
                if document.type == .scanned {
                    dataForOCR = document.pdfData ?? document.originalFileData
                    ocrType = .pdf
                } else {
                    dataForOCR = document.pdfData ?? document.originalFileData
                }

                if let dataForOCR,
                   let pages = buildVisionOCRPages(from: dataForOCR, type: ocrType),
                   !pages.isEmpty {
                    pagesForTags = pages
                    updateOCRPages(for: document.id, to: pages)
                    let ocrText = Self.buildStructuredText(from: pages, includePageLabels: false)
                    if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                        seed = ocrText
                    }
                }
            }
        }
        if seed.isEmpty {
            seed = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let snippet = String(seed.prefix(400)).trimmingCharacters(in: .whitespacesAndNewlines)
        if snippet.isEmpty { return }

        let prompt = """
        <<<TAG_REQUEST>>>
        Extract exactly 4 single-word tags from this document excerpt.
        Output only a comma-separated list with exactly 4 items.
        Use specific topic words only.
        Do not use stopwords like: and, or, the, a, an, including, with, for.

        EXCERPT:
        \(snippet)
        """

        edgeAI.generate(prompt, resolver: { result in
            DispatchQueue.main.async {
                let raw = (result as? String ?? "")
                let category = document.category.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                let sourceForFallback = "\(document.title)\n\(snippet)"

                var tags = Self.parseTags(from: raw, sourceText: sourceForFallback, limit: 4)
                    .filter { $0.caseInsensitiveCompare(category) != .orderedSame }

                if tags.count < 4 {
                    let existing = Set(tags.map { $0.lowercased() } + [category.lowercased()])
                    let topUp = Self.extractFallbackTags(
                        from: sourceForFallback,
                        excluding: existing,
                        limit: 4 - tags.count
                    )
                    tags.append(contentsOf: topUp)
                }

                if tags.count < 4 {
                    var used = Set(tags.map { $0.lowercased() } + [category.lowercased()])
                    for filler in Self.defaultTagFallbacks {
                        if tags.count >= 4 { break }
                        let key = filler.lowercased()
                        if used.contains(key) { continue }
                        used.insert(key)
                        tags.append(filler)
                    }
                }

                let finalTags = [category] + Array(tags.prefix(4))
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

        let updated = Document(
            id: old.id,
            title: old.title,
            content: old.content,
            summary: old.summary,
            ocrPages: old.ocrPages,
            category: old.category,
            keywordsResume: old.keywordsResume,
            tags: old.tags,
            sourceDocumentId: old.sourceDocumentId,
            dateCreated: old.dateCreated,
            folderId: folderId,
            sortOrder: maxOrder + 1,
            type: old.type,
            imageData: old.imageData,
            pdfData: old.pdfData,
            originalFileData: old.originalFileData
        )
        documents[idx] = updated

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

        // Write back sequential sortOrder.
        for (i, doc) in bucket.enumerated() {
            if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
                let old = documents[idx]
                documents[idx] = Document(
                    id: old.id,
                    title: old.title,
                    content: old.content,
                    summary: old.summary,
                    ocrPages: old.ocrPages,
                    category: old.category,
                    keywordsResume: old.keywordsResume,
                    tags: old.tags,
                    sourceDocumentId: old.sourceDocumentId,
                    dateCreated: old.dateCreated,
                    folderId: old.folderId,
                    sortOrder: i,
                    type: old.type,
                    imageData: old.imageData,
                    pdfData: old.pdfData,
                    originalFileData: old.originalFileData
                )
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
            if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
                let old = documents[idx]
                if old.sortOrder != i {
                    documents[idx] = Document(
                        id: old.id,
                        title: old.title,
                        content: old.content,
                        summary: old.summary,
                        ocrPages: old.ocrPages,
                        category: old.category,
                        keywordsResume: old.keywordsResume,
                        tags: old.tags,
                        sourceDocumentId: old.sourceDocumentId,
                        dateCreated: old.dateCreated,
                        folderId: old.folderId,
                        sortOrder: i,
                        type: old.type,
                        imageData: old.imageData,
                        pdfData: old.pdfData,
                        originalFileData: old.originalFileData
                    )
                }
            }
        }
    }

    func getDocument(by id: UUID) -> Document? {
        return documents.first(where: { $0.id == id })
    }

    func refreshContentIfNeeded(for documentId: UUID) {
        guard let doc = getDocument(by: documentId) else { return }
        guard doc.type == .docx else { return }
        let content = doc.content
        if looksLikeXML(content) {
            if let data = doc.originalFileData {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("repair_\(doc.id).docx")
                do {
                    try data.write(to: tempURL)
                    let fresh = extractTextFromWordDocument(url: tempURL)
                    try? FileManager.default.removeItem(at: tempURL)
                    if !fresh.isEmpty && !looksLikeXML(fresh) {
                        updateContent(for: documentId, to: formatExtractedText(fresh))
                    }
                } catch {
                    print("📄 DocumentManager: refresh write failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func looksLikeXML(_ s: String) -> Bool {
        if s.contains("<?xml") { return true }
        if s.contains("<w:") || s.contains("</w:") || s.contains("<w:t") { return true }
        if s.contains("xmlns") { return true }
        if s.contains("PK!") { return true }
        let ltCount = s.filter { $0 == "<" }.count
        return ltCount > 20 && s.count > 200
    }
    
    func generateSummary(
        for document: Document,
        force: Bool = false,
        length: SummaryLength = .medium,
        content: SummaryContent = .general
    ) {
        if document.type == .zip { return }
        print("🤖 DocumentManager: Generating summary for '\(document.title)'")
        var promptBody = ""
        if let pages = document.ocrPages, !pages.isEmpty {
            let ocrText = Self.buildStructuredText(from: pages, includePageLabels: true)
            if ocrText.trimmingCharacters(in: .whitespacesAndNewlines).count >= 40 {
                promptBody = ocrText
            }
        }
        if promptBody.isEmpty {
            promptBody = document.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let styleMarker = "<<<SUMMARY_STYLE:length=\(length.rawValue);content=\(content.rawValue)>>>"
        let prompt = """
        <<<SUMMARY_REQUEST>>>
        \(styleMarker)
        \(promptBody)
        """

        print("🤖 DocumentManager: Sending summary request, content length: \(promptBody.count)")
        if force {
            updateSummary(for: document.id, to: "Processing summary...")
        }
        // Send to EdgeAI for processing
        NotificationCenter.default.post(
            name: NSNotification.Name("GenerateDocumentSummary"),
            object: nil,
            userInfo: ["documentId": document.id.uuidString, "prompt": prompt, "force": force]
        )
    }
    
    func getAllDocumentContent() -> String {
        print("🤖 DocumentManager: Getting all document content, document count: \(documents.count)")
        return documents.map { document in
            """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Category: \(document.category.rawValue)
            Keywords: \(document.keywordsResume)
            Tags: \(document.tags.joined(separator: ", "))
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Summary: \(document.summary)
            
            Content:
            \(document.content)
            
            ---
            
            """
        }.joined()
    }
    
    func getDocumentSummaries() -> String {
        print("🤖 DocumentManager: Getting document summaries, document count: \(documents.count)")
        return documents.map { document in
            """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Summary: \(document.summary)
            Tags: \(document.tags.joined(separator: ", "))
            Content Length: \(document.content.count) characters
            
            ---
            
            """
        }.joined()
    }
    
    func getSmartDocumentContext() -> String {
        print("🤖 DocumentManager: Getting smart document context, document count: \(documents.count)")
        return documents.map { document in
            // Use summary if available and meaningful, otherwise use first 500 characters
            let summaryTrimmed = document.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasUsableSummary = !summaryTrimmed.isEmpty &&
                                  summaryTrimmed != "Processing..." &&
                                  summaryTrimmed != "Processing summary..." &&
                                  !summaryTrimmed.contains("Processing summary") &&
                                  summaryTrimmed != Self.summaryUnavailableMessage
            
            let contentToUse = hasUsableSummary ? document.summary : String(document.content.prefix(500))
            let contentType = hasUsableSummary ? "Summary:" : "Content (first 500 chars):"
            
            return """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
            Tags: \(document.tags.joined(separator: ", "))
            \(contentType)
            \(contentToUse)
            
            ---
            
            """
        }.joined()
    }
    
    // MARK: - File Processing
    
    func processFile(at url: URL) -> Document? {
        print("📄 DocumentManager: Processing file at \\(url.lastPathComponent)")
        
        // Try to start accessing security scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer { 
            if didStartAccess {
                url.stopAccessingSecurityScopedResource() 
            }
        }
        
        let fileName = url.lastPathComponent
        let fileExtension = url.pathExtension.lowercased()
        print("📄 DocumentManager: File type detected: \\(fileExtension)")
        
        var content = ""
        var ocrPages: [OCRPage]? = nil
        var documentType: Document.DocumentType = .text
        
        switch fileExtension {
        case "pdf":
            content = extractTextFromPDF(url: url)
            documentType = .pdf
        case "txt", "rtf":
            content = extractTextFromTXT(url: url)
            documentType = .text
        case "jpg", "jpeg", "png", "heic":
            content = "Imported image file. OCR extraction is skipped for image documents."
            ocrPages = nil
            documentType = .image
        case "docx", "doc":
            content = extractTextFromWordDocument(url: url)
            documentType = .docx
        case "json":
            content = extractTextFromJSON(url: url)
            documentType = .text
        case "xml":
            content = extractTextFromXML(url: url)
            documentType = .text
        case "zip":
            content = "ZIP archive"
            documentType = .zip
        case "ppt":
            let result = extractTextFromPresentationViaOCR(url: url)
            content = result.text.isEmpty ? "PowerPoint document - text extraction is limited on this file." : result.text
            ocrPages = result.pages
            documentType = .ppt
        case "pptx":
            let parsed = extractTextFromPPTXArchive(url: url)
            if !parsed.isEmpty {
                content = parsed
                ocrPages = nil
            } else {
                let result = extractTextFromPresentationViaOCR(url: url)
                content = result.text.isEmpty ? "PowerPoint document - text extraction is limited on this file." : result.text
                ocrPages = result.pages
            }
            documentType = .pptx
        case "xls":
            content = extractTextFromSpreadsheetViaOCR(url: url)
            documentType = .xls
        case "xlsx":
            content = "Imported XLSX spreadsheet. OCR extraction is skipped for XLSX documents."
            documentType = .xlsx
        default:
            content = "Unsupported file type: .\(fileExtension)"
        }
        
        print("📄 DocumentManager: Content extracted, length: \\(content.count) characters")
        
        // Store original file data for preview - ALWAYS try to store the original file
        var imageData: [Data]? = nil
        var pdfData: Data? = nil
        var originalFileData: Data? = nil
        
        do {
            let fileData = try Data(contentsOf: url)
            print("📄 DocumentManager: Successfully read \\(fileData.count) bytes from file")
            
            // Always store original file data for QuickLook preview
            originalFileData = fileData
            print("📄 DocumentManager: Original file data stored for QuickLook preview")
            
            switch fileExtension {
            case "pdf":
                pdfData = fileData
                print("📄 DocumentManager: PDF data stored for preview")
            case "jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff":
                imageData = [fileData]
                print("📄 DocumentManager: Image data stored for preview")
            case "docx", "doc", "rtf", "txt":
                print("📄 DocumentManager: Text document processed, original file available for preview")
            default:
                print("📄 DocumentManager: File data read, original file available for preview")
            }
        } catch {
            print("❌ DocumentManager: Failed to read file data: \\(error.localizedDescription)")
        }
        
        let docId = UUID()
        if content.count > maxOCRChars {
            content = Self.truncateText(content, maxChars: maxOCRChars)
        }
        if ocrPages == nil && shouldAutoOCR(for: documentType) {
            ocrPages = buildPseudoOCRPages(from: content)
        }
        let baseDocument = Document(
            id: docId,
            title: fileName,
            content: content,
            summary: "Processing...",
            ocrPages: ocrPages,
            category: .general,
            keywordsResume: "",
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            type: documentType,
            imageData: imageData,
            pdfData: pdfData,
            originalFileData: originalFileData
        )
        
        print("📄 DocumentManager: ✅ Document created successfully:")
        print("📄 DocumentManager:   - Title: \\(baseDocument.title)")
        print("📄 DocumentManager:   - Type: \\(baseDocument.type.rawValue)")
        print("📄 DocumentManager:   - Content length: \\(baseDocument.content.count)")
        print("📄 DocumentManager:   - Has image data: \\(baseDocument.imageData != nil)")
        print("📄 DocumentManager:   - Has PDF data: \\(baseDocument.pdfData != nil)")
        
        return baseDocument
    }
    
    // MARK: - Text Extraction
    
    private func extractTextFromPDF(url: URL) -> String {
        guard let pdfDocument = PDFDocument(url: url) else {
            return "Could not read PDF file"
        }
        
        var text = ""
        for pageIndex in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: pageIndex) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }
        
        return text.isEmpty ? "No text found in PDF" : text
    }
    
    private func extractTextFromTXT(url: URL) -> String {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return content
        } catch {
            return "Could not read text file: \(error.localizedDescription)"
        }
    }
    
    private func extractTextFromImageDetailed(url: URL) -> (text: String, pages: [OCRPage]?) {
        guard let image = UIImage(contentsOfFile: url.path) else {
            return ("Could not load image", nil)
        }
        let result = performOCRDetailed(on: image, pageIndex: 0)
        let structured = buildStructuredText(from: [result.page], includePageLabels: false)
        return (structured.isEmpty ? result.text : structured, [result.page])
    }
    
    private func performOCRDetailed(on image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            print("OCR: Failed to process image")
            return ("Could not process image", OCRPage(pageIndex: pageIndex, blocks: []))
        }

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "en-GB"]

        var blocks: [OCRBlock] = []
        var recognizedText = ""

        do {
            try requestHandler.perform([request])
            if let results = request.results {
                let observations = results.compactMap { result -> (String, CGRect, Double)? in
                    guard let top = result.topCandidates(1).first else { return nil }
                    return (top.string, result.boundingBox, Double(top.confidence))
                }

                let sorted = observations.sorted { first, second in
                    let yDiff = abs(first.1.minY - second.1.minY)
                    if yDiff < 0.02 {
                        return first.1.minX < second.1.minX
                    }
                    return first.1.minY > second.1.minY
                }

                for (idx, item) in sorted.enumerated() {
                    let bbox = OCRBoundingBox(
                        x: Double(item.1.origin.x),
                        y: Double(item.1.origin.y),
                        width: Double(item.1.size.width),
                        height: Double(item.1.size.height)
                    )
                    blocks.append(OCRBlock(text: item.0, confidence: item.2, bbox: bbox, order: idx))
                }

                recognizedText = sorted.map { $0.0 }.joined(separator: " ")
                recognizedText = recognizedText
                    .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                print("OCR: No results returned")
            }
        } catch {
            print("OCR Error: \(error.localizedDescription)")
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }

        let cleaned = recognizedText.isEmpty ? "No text found in image" : recognizedText
        return (cleaned, OCRPage(pageIndex: pageIndex, blocks: blocks))
    }

    private func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        guard !pages.isEmpty else { return "" }

        func paragraphize(_ lines: [(text: String, y: Double)]) -> String {
            var output: [String] = []
            var lastY: Double? = nil

            for line in lines {
                if let last = lastY, abs(line.y - last) > 0.04 {
                    output.append("")
                }
                output.append(line.text)
                lastY = line.y
            }

            return output.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        }

        var result: [String] = []
        for page in pages {
            let sorted = page.blocks.sorted { $0.order < $1.order }
            var lines: [(text: String, y: Double)] = []

            for block in sorted {
                if let last = lines.last, abs(block.bbox.y - last.y) < 0.02 {
                    let combined = last.text.isEmpty ? block.text : "\(last.text) \(block.text)"
                    lines[lines.count - 1] = (combined, last.y)
                } else {
                    lines.append((block.text, block.bbox.y))
                }
            }

            let body = paragraphize(lines)
            if includePageLabels {
                result.append("Page \(page.pageIndex + 1):\n\(body)")
            } else {
                result.append(body)
            }
        }

        return result.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        guard image.cgImage != nil else { return nil }
        
        let targetSize: CGFloat = 2560
        let imageSize = image.size
        let maxDimension = max(imageSize.width, imageSize.height)
        
        if maxDimension > targetSize {
            let scale = targetSize / maxDimension
            let newSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            return resizedImage
        }
        
        return image
    }

    func buildVisionOCRPages(from data: Data, type: Document.DocumentType) -> [OCRPage]? {
        switch type {
        case .image:
            guard let image = UIImage(data: data) else { return nil }
            let result = performOCRDetailed(on: image, pageIndex: 0)
            return [result.page]
        case .pdf:
            guard let pdf = PDFDocument(data: data) else { return nil }
            var pages: [OCRPage] = []
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index),
                      let image = renderPDFPageForOCR(page) else { continue }
                let result = performOCRDetailed(on: image, pageIndex: index)
                pages.append(result.page)
            }
            return pages.isEmpty ? nil : pages
        default:
            return nil
        }
    }

    private func renderPDFPageForOCR(_ page: PDFPage) -> UIImage? {
        let pageRect = page.bounds(for: .mediaBox)
        if pageRect.width <= 0 || pageRect.height <= 0 { return nil }
        
        let targetMax: CGFloat = 2200
        let maxDim = max(pageRect.width, pageRect.height)
        let scale = maxDim > targetMax ? (targetMax / maxDim) : min(2.0, targetMax / maxDim)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)
        
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            context.cgContext.saveGState()
            context.cgContext.scaleBy(x: scale, y: scale)
            context.cgContext.translateBy(x: 0, y: pageRect.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            page.draw(with: .mediaBox, to: context.cgContext)
            context.cgContext.restoreGState()
        }
    }
    
    private func extractTextFromWordDocument(url: URL) -> String {
        print("📄 DocumentManager: Attempting to extract text from Word document")
        let ext = url.pathExtension.lowercased()

        // Preferred: Parse DOCX XML body and extract <w:t> text nodes (no XML returned)
        if ext == "docx" {
            let parsed = extractTextFromDOCXArchive(url: url)
            let cleaned = formatExtractedText(parsed)
            if !cleaned.isEmpty && !looksLikeXML(cleaned) {
                print("📄 DocumentManager: Using DOCX parsed text (\(cleaned.count))")
                return cleaned
            }
        }

        // Fallback: OCR a rendered thumbnail of the document
        if let ocrText = extractTextFromDOCXViaOCR(url: url), !ocrText.isEmpty, !ocrText.contains("OCR failed") {
            print("📄 DocumentManager: Using OCR text from DOC thumbnail (\(ocrText.count))")
            return formatExtractedText(ocrText)
        }

        // Last resort placeholder without exposing XML
        print("📄 DocumentManager: No readable text extracted from Word; returning placeholder")
        return "Imported Word document. Text extraction is limited on this file."
    }

    private func generateDOCXThumbnail(url: URL, size: CGSize = CGSize(width: 2048, height: 2048)) -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: size,
                                                   scale: UIScreen.main.scale,
                                                   representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        generator.generateBestRepresentation(for: request) { rep, error in
            if let rep = rep {
                image = rep.uiImage
            } else {
                if let error = error { print("📄 DocumentManager: QL thumbnail error: \(error.localizedDescription)") }
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return image
    }

    private func extractTextFromDOCXViaOCR(url: URL) -> String? {
        if let img = generateDOCXThumbnail(url: url) {
            let result = performOCRDetailed(on: img, pageIndex: 0)
            return result.text
        }
        return nil
    }

    private func extractTextFromSpreadsheetViaOCR(url: URL) -> String {
        if let img = generateDOCXThumbnail(url: url) {
            let result = performOCRDetailed(on: img, pageIndex: 0)
            if !result.text.isEmpty && !result.text.contains("OCR failed") {
                return formatExtractedText(result.text)
            }
        }
        return "Imported spreadsheet. Text extraction is limited on this file."
    }

    private func extractTextFromPresentationViaOCR(url: URL) -> (text: String, pages: [OCRPage]?) {
        if let img = generateDOCXThumbnail(url: url) {
            let result = performOCRDetailed(on: img, pageIndex: 0)
            if !result.text.isEmpty && !result.text.contains("OCR failed") {
                return (formatExtractedText(result.text), [result.page])
            }
        }
        return ("", nil)
    }
    
    private func extractTextFromXMLContent(_ xmlContent: String) -> String {
        var extractedText = ""
        
        // Look for text content between XML tags, specifically targeting common document content
        let patterns = [
            // Word document text content patterns
            "<w:t[^>]*>([^<]+)</w:t>",
            "<text[^>]*>([^<]+)</text>",
            // General XML text patterns
            ">([A-Za-z][^<]{10,})<",
            // Fallback for any substantial text content
            "([A-Za-z][A-Za-z0-9\\s.,!?;:()\\[\\]\"'-]{20,})"
        ]
        
        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
                let matches = regex.matches(in: xmlContent, options: [], range: NSRange(xmlContent.startIndex..., in: xmlContent))
                
                for match in matches {
                    if match.numberOfRanges > 1 {
                        let range = match.range(at: 1)
                        if let swiftRange = Range(range, in: xmlContent) {
                            let matchedText = String(xmlContent[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // Filter out XML artifacts and binary data indicators
                            if !matchedText.isEmpty && 
                               !matchedText.contains("<?xml") && 
                               !matchedText.contains("PK!") &&
                               !matchedText.contains("<") &&
                               !matchedText.contains("xmlns") &&
                               matchedText.count > 10 {
                                extractedText += matchedText + " "
                            }
                        }
                    }
                }
                
                if extractedText.count > 100 { // If we found substantial text, use this pattern
                    break
                }
            } catch {
                print("📄 DocumentManager: Regex pattern failed: \\(error.localizedDescription)")
                continue
            }
        }
        
        return extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractTextFromDOCXArchive(url: URL) -> String {
        // Unzip DOCX to temp folder and read word/document.xml
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_extract_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {
            print("📄 DocumentManager: Failed to create temp dir: \(error.localizedDescription)")
            return ""
        }

        var unzipError: NSError?
        // Use overload with preserveAttributes preceding overwrite to match header
        let ok = SSZipArchive.unzipFile(atPath: url.path,
                        toDestination: tempDir.path,
                        preserveAttributes: false,
                        overwrite: true,
                        password: nil,
                        error: &unzipError,
                        delegate: nil)
        if !ok {
            if let unzipError = unzipError { print("📄 DocumentManager: Unzip failed: \(unzipError.localizedDescription)") }
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        let docXML = tempDir.appendingPathComponent("word/document.xml")
        guard let xmlData = try? Data(contentsOf: docXML), let xml = String(data: xmlData, encoding: .utf8) else {
            print("📄 DocumentManager: document.xml missing or unreadable")
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        var body = ""
        do {
            let re = try NSRegularExpression(pattern: "<w:t[^>]*>(.*?)</w:t>", options: [.dotMatchesLineSeparators])
            let ns = xml as NSString
            let matches = re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                if m.numberOfRanges >= 2 {
                    let t = ns.substring(with: m.range(at: 1))
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&apos;", with: "'")
                    body += t
                }
            }
        } catch {
            print("📄 DocumentManager: Regex failed: \(error.localizedDescription)")
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = extractTextFromXMLContent(xml)
            if !cleaned.isEmpty { body = cleaned }
        }

        try? FileManager.default.removeItem(at: tempDir)
        return formatExtractedText(body)
    }

    private func extractTextFromPPTXArchive(url: URL) -> String {
        // Unzip PPTX to temp folder and read ppt/slides/slide*.xml
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx_extract_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {
            print("📄 DocumentManager: Failed to create temp dir: \(error.localizedDescription)")
            return ""
        }

        var unzipError: NSError?
        let ok = SSZipArchive.unzipFile(atPath: url.path,
                        toDestination: tempDir.path,
                        preserveAttributes: false,
                        overwrite: true,
                        password: nil,
                        error: &unzipError,
                        delegate: nil)
        if !ok {
            if let unzipError = unzipError { print("📄 DocumentManager: Unzip failed: \(unzipError.localizedDescription)") }
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        let slidesDir = tempDir.appendingPathComponent("ppt/slides", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil) else {
            print("📄 DocumentManager: ppt/slides missing or unreadable")
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        let slideFiles = files
            .filter { $0.lastPathComponent.lowercased().hasPrefix("slide") && $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if slideFiles.isEmpty {
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        var collected: [String] = []
        for slideURL in slideFiles {
            guard let xmlData = try? Data(contentsOf: slideURL),
                  let xml = String(data: xmlData, encoding: .utf8) else { continue }

            var body = ""
            do {
                let re = try NSRegularExpression(pattern: "<a:t[^>]*>(.*?)</a:t>", options: [.dotMatchesLineSeparators])
                let ns = xml as NSString
                let matches = re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    if m.numberOfRanges >= 2 {
                        let t = ns.substring(with: m.range(at: 1))
                            .replacingOccurrences(of: "&amp;", with: "&")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                            .replacingOccurrences(of: "&quot;", with: "\"")
                            .replacingOccurrences(of: "&apos;", with: "'")
                        body += t + " "
                    }
                }
            } catch {
                print("📄 DocumentManager: PPTX regex failed: \(error.localizedDescription)")
            }

            let cleaned = formatExtractedText(body)
            if !cleaned.isEmpty {
                collected.append(cleaned)
            }
        }

        try? FileManager.default.removeItem(at: tempDir)
        return collected.joined(separator: "\n\n")
    }
    
    private func formatExtractedText(_ text: String) -> String {
        // Flatten to plain text: single spaces, no line artifacts, strip XML remnants
        return text
            // Remove special/control characters
            .replacingOccurrences(of: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]", with: "", options: .regularExpression)
            // Remove XML/HTML tags
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            // Decode common entities
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            // Collapse all whitespace (including newlines) to single spaces
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func extractTextFromJSON(url: URL) -> String {
        do {
            let jsonString = try String(contentsOf: url, encoding: .utf8)
            
            // Try to pretty-print the JSON
            if let jsonData = jsonString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []),
               let prettyJsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
               let prettyJsonString = String(data: prettyJsonData, encoding: .utf8) {
                return prettyJsonString
            }
            
            return jsonString
        } catch {
            return "Could not read JSON file: \(error.localizedDescription)"
        }
    }
    
    private func extractTextFromXML(url: URL) -> String {
        do {
            let xmlString = try String(contentsOf: url, encoding: .utf8)
            return xmlString.isEmpty ? "No content found in XML file" : xmlString
        } catch {
            return "Could not read XML file: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Persistence
    
    private func saveState() {
        do {
            let encoded = try JSONEncoder().encode(PersistedState(documents: documents, folders: folders, prefersGridLayout: prefersGridLayout))
            let url = documentsFileURL()
            try encoded.write(to: url, options: [.atomic])
            print("💾 DocumentManager: Successfully saved \(documents.count) documents + \(folders.count) folders to \(url.lastPathComponent)")
        } catch {
            print("❌ DocumentManager: Failed to encode documents: \(error.localizedDescription)")
        }
    }
    
    private func loadDocuments() {
        let url = documentsFileURL()

        if let data = try? Data(contentsOf: url) {
            do {
                if let state = try? JSONDecoder().decode(PersistedState.self, from: data) {
                    let decodedDocuments = state.documents
                    let backfilled = decodedDocuments.map { Self.withBackfilledMetadata($0) }
                    self.documents = backfilled
                    self.folders = state.folders
                    self.prefersGridLayout = state.prefersGridLayout
                    backfillSortOrdersIfNeeded()
                    backfillFolderSortOrdersIfNeeded()
                    print("💾 DocumentManager: Successfully loaded \(documents.count) documents + \(folders.count) folders from \(url.lastPathComponent)")

                    // Persist backfilled metadata/order once.
                    if zip(decodedDocuments, backfilled).contains(where: { $0.keywordsResume != $1.keywordsResume || $0.category != $1.category }) {
                        saveState()
                    }
                    return
                }

                // Legacy file format (documents only)
                let decodedDocuments = try JSONDecoder().decode([Document].self, from: data)
                let backfilled = decodedDocuments.map { Self.withBackfilledMetadata($0) }
                self.documents = backfilled
                self.folders = []
                self.prefersGridLayout = false
                backfillSortOrdersIfNeeded()
                backfillFolderSortOrdersIfNeeded()
                print("💾 DocumentManager: Loaded legacy documents-only file (\(documents.count) docs)")
                saveState()
                return
            } catch {
                print("❌ DocumentManager: Failed to decode documents file: \(error.localizedDescription)")
            }
        }

        // One-time migration: older builds stored JSON in UserDefaults.
        if let data = UserDefaults.standard.data(forKey: documentsKey) {
            do {
                let decodedDocuments = try JSONDecoder().decode([Document].self, from: data)
                let backfilled = decodedDocuments.map { Self.withBackfilledMetadata($0) }
                self.documents = backfilled
                self.folders = []
                self.prefersGridLayout = false
                backfillSortOrdersIfNeeded()
                backfillFolderSortOrdersIfNeeded()
                print("💾 DocumentManager: Migrated \(documents.count) documents from UserDefaults -> file")
                saveState()
                UserDefaults.standard.removeObject(forKey: documentsKey)
                return
            } catch {
                print("❌ DocumentManager: Failed to decode legacy UserDefaults documents: \(error.localizedDescription)")
            }
        }

        print("💾 DocumentManager: No saved documents found")
    }

    private func backfillSortOrdersIfNeeded() {
        // If everything is 0 (legacy), assign stable ordering within each folder bucket.
        let hasAnyNonZero = documents.contains(where: { $0.sortOrder != 0 })
        if hasAnyNonZero { return }

        // Preserve current array order within each folder bucket.
        let grouped = Dictionary(grouping: documents, by: { $0.folderId })
        for (folderId, bucket) in grouped {
            for (i, doc) in bucket.enumerated() {
                if let idx = documents.firstIndex(where: { $0.id == doc.id }) {
                    let old = documents[idx]
                    documents[idx] = Document(
                        id: old.id,
                        title: old.title,
                        content: old.content,
                        summary: old.summary,
                        ocrPages: old.ocrPages,
                        category: old.category,
                        keywordsResume: old.keywordsResume,
                        tags: old.tags,
                        sourceDocumentId: old.sourceDocumentId,
                        dateCreated: old.dateCreated,
                        folderId: old.folderId,
                        sortOrder: i,
                        type: old.type,
                        imageData: old.imageData,
                        pdfData: old.pdfData,
                        originalFileData: old.originalFileData
                    )
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
        // If we already have a keyword resume, assume metadata is present.
        if !doc.keywordsResume.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return doc
        }
        let inferredCategory = inferCategory(title: doc.title, content: doc.content, summary: doc.summary)
        let inferredKeywords = makeKeywordsResume(title: doc.title, content: doc.content, summary: doc.summary)
        return Document(
            id: doc.id,
            title: doc.title,
            content: doc.content,
            summary: doc.summary,
            ocrPages: doc.ocrPages,
            category: inferredCategory,
            keywordsResume: inferredKeywords,
            tags: doc.tags,
            sourceDocumentId: doc.sourceDocumentId,
            dateCreated: doc.dateCreated,
            folderId: doc.folderId,
            sortOrder: doc.sortOrder,
            type: doc.type,
            imageData: doc.imageData,
            pdfData: doc.pdfData,
            originalFileData: doc.originalFileData
        )
    }

    private static func withBackfilledMetadata(_ doc: Document) -> Document {
        withInferredMetadataIfNeeded(doc)
    }

    private static func parseNumberedHeading(_ line: String) -> (numbers: [Int], title: String)? {
        let pattern = #"^(\d+(\.\d+)*)[.)]?\s+(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, options: [], range: range) else { return nil }
        guard let numbersRange = Range(match.range(at: 1), in: line),
              let titleRange = Range(match.range(at: 3), in: line) else { return nil }
        let numbers = line[numbersRange].split(separator: ".").compactMap { Int($0) }
        let title = String(line[titleRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        if numbers.isEmpty || title.isEmpty { return nil }
        return (numbers, title)
    }

    private static func isHeadingLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if trimmed.count > 80 { return false }
        if trimmed == trimmed.uppercased(), trimmed.count >= 3 {
            return true
        }
        if trimmed.hasSuffix(":") && trimmed.count <= 70 {
            return true
        }
        if parseNumberedHeading(trimmed) != nil {
            return true
        }
        let words = trimmed.split(separator: " ")
        if words.count <= 4, words.allSatisfy({ $0.first?.isUppercase == true }) {
            return true
        }
        return false
    }

    private static func parseList(from lines: [String], startIndex: Int) -> (items: [String], style: String, nextIndex: Int)? {
        guard startIndex < lines.count else { return nil }
        func listItem(from line: String) -> (String, String)? {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ") {
                let item = trimmed.dropFirst(2).trimmingCharacters(in: .whitespacesAndNewlines)
                return (String(item), "bullets")
            }
            let pattern = #"^(\d+)[.)]\s+(.+)$"#
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)),
               let itemRange = Range(match.range(at: 2), in: trimmed) {
                return (String(trimmed[itemRange]).trimmingCharacters(in: .whitespacesAndNewlines), "numbered")
            }
            return nil
        }

        guard let first = listItem(from: lines[startIndex]) else { return nil }
        var items: [String] = [first.0]
        let style = first.1
        var idx = startIndex + 1
        while idx < lines.count {
            let line = lines[idx]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            guard let next = listItem(from: line) else { break }
            if next.1 != style { break }
            items.append(next.0)
            idx += 1
        }
        return (items, style, idx)
    }

    private static func parseTable(from lines: [String], startIndex: Int) -> (columns: [String], rows: [[String]], nextIndex: Int)? {
        guard startIndex < lines.count else { return nil }
        func splitColumns(_ line: String) -> [String] {
            if line.contains("|") {
                return line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            if line.contains("\t") {
                return line.split(separator: "\t").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            }
            return []
        }

        let headerCols = splitColumns(lines[startIndex])
        guard headerCols.count >= 2 else { return nil }
        var rows: [[String]] = []
        var idx = startIndex + 1
        while idx < lines.count {
            let line = lines[idx]
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
            let cols = splitColumns(line)
            if cols.count < 2 { break }
            rows.append(cols)
            idx += 1
        }
        guard !rows.isEmpty else { return nil }
        return (headerCols, rows, idx)
    }

    private static func parseParagraph(from lines: [String], startIndex: Int) -> (text: String, nextIndex: Int) {
        var parts: [String] = []
        var idx = startIndex
        while idx < lines.count {
            let line = lines[idx]
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { break }
            if isHeadingLine(trimmed) || parseList(from: lines, startIndex: idx) != nil || parseTable(from: lines, startIndex: idx) != nil {
                break
            }
            parts.append(trimmed)
            idx += 1
        }
        if parts.isEmpty {
            return ("", min(startIndex + 1, lines.count))
        }
        return (parts.joined(separator: " "), idx)
    }

    private static func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        guard !pages.isEmpty else { return "" }

        func paragraphize(_ lines: [(text: String, y: Double)]) -> String {
            var output: [String] = []
            var lastY: Double? = nil

            for line in lines {
                if let last = lastY, abs(line.y - last) > 0.04 {
                    output.append("")
                }
                output.append(line.text)
                lastY = line.y
            }

            return output.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        }

        var result: [String] = []
        for page in pages {
            let sorted = page.blocks.sorted { $0.order < $1.order }
            var lines: [(text: String, y: Double)] = []

            for block in sorted {
                if let last = lines.last, abs(block.bbox.y - last.y) < 0.02 {
                    let combined = last.text.isEmpty ? block.text : "\(last.text) \(block.text)"
                    lines[lines.count - 1] = (combined, last.y)
                } else {
                    lines.append((block.text, block.bbox.y))
                }
            }

            let body = paragraphize(lines)
            if includePageLabels {
                result.append("Page \(page.pageIndex + 1):\n\(body)")
            } else {
                result.append(body)
            }
        }

        return result.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func inferCategory(title: String, content: String, summary: String) -> Document.DocumentCategory {
        let t = title.lowercased()
        let s = summary.lowercased()
        let c = String(content.prefix(4000)).lowercased()
        let combined = "\(t)\n\(s)\n\(c)"

        func has(_ needles: [String]) -> Bool {
            for n in needles where combined.contains(n) { return true }
            return false
        }

        if has(["cv", "resume", "résumé", "curriculum vitae", "work experience", "education", "skills", "linkedin", "github"]) {
            return .resume
        }
        if has(["invoice", "receipt", "statement", "payment", "balance", "iban", "swift", "tax", "salary", "budget"]) {
            return combined.contains("receipt") ? .receipts : .finance
        }
        if has(["agreement", "contract", "terms", "nda", "non-disclosure", "liability", "lease", "court", "jurisdiction"]) {
            return .legal
        }
        if has(["diagnosis", "prescription", "patient", "clinic", "doctor", "hospital", "medication", "allergy"]) {
            return .medical
        }
        if has(["passport", "driver", "license", "identity", "id card", "ssn", "social security"]) {
            return .identity
        }
        if has(["meeting", "notes", "minutes", "agenda", "todo", "brainstorm", "journal"]) {
            return .notes
        }
        return .general
    }

    static func makeKeywordsResume(title: String, content: String, summary: String) -> String {
        let stop: Set<String> = [
            "the","and","for","with","that","this","from","are","was","were","have","has","had",
            "you","your","they","their","them","not","but","can","will","would","should","could",
            "a","an","to","of","in","on","at","as","by","or","be","is","it","we","i"
        ]

        let text = "\(title)\n\(summary)\n\(String(content.prefix(2500)))".lowercased()
        let tokens = text
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 && !stop.contains($0) }

        var freq: [String: Int] = [:]
        for tok in tokens {
            freq[tok, default: 0] += 1
        }

        let ranked = freq
            .sorted { a, b in a.value == b.value ? a.key < b.key : a.value > b.value }
            .map { $0.key }

        var parts: [String] = []
        for w in ranked {
            if parts.count >= 10 { break }
            parts.append(w)
            let candidate = parts.joined(separator: ", ")
            if candidate.count >= 50 { break }
        }

        let joined = parts.joined(separator: ", ")
        if joined.count <= 50 { return joined }
        let idx = joined.index(joined.startIndex, offsetBy: 50)
        return String(joined[..<idx])
    }

    private static let tagStopwords: Set<String> = [
        "a", "an", "and", "or", "the", "of", "to", "in", "on", "at", "by", "for", "from", "with", "without",
        "into", "onto", "about", "over", "under", "through", "between", "among", "is", "are", "was", "were",
        "be", "been", "being", "this", "that", "these", "those", "it", "its", "their", "they", "them", "you",
        "your", "our", "ours", "we", "i", "me", "my", "as", "if", "then", "else", "not", "can", "could",
        "would", "should", "will", "including", "include", "includes", "using", "used", "use", "other", "etc"
    ]

    private static let defaultTagFallbacks: [String] = ["document", "content", "details", "reference"]

    private static func normalizeTagToken(_ raw: String) -> String? {
        let token = raw
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard token.count >= 3 else { return nil }
        guard token.rangeOfCharacter(from: .letters) != nil else { return nil }
        guard !tagStopwords.contains(token) else { return nil }
        return token
    }

    private static func extractFallbackTags(from source: String, excluding: Set<String>, limit: Int) -> [String] {
        guard limit > 0 else { return [] }

        let tokens = source
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        var freq: [String: Int] = [:]
        for token in tokens {
            guard let normalized = normalizeTagToken(token) else { continue }
            if excluding.contains(normalized) { continue }
            freq[normalized, default: 0] += 1
        }

        let ranked = freq.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }

        return Array(ranked.prefix(limit).map { $0.key })
    }

    static func parseTags(from text: String, sourceText: String? = nil, limit: Int = 4) -> [String] {
        guard limit > 0 else { return [] }

        let cleaned = text
            .replacingOccurrences(of: "[\\[\\]\\(\\)\"'“”`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9,;|\\n\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let parts = cleaned
            .split { $0 == "," || $0 == "\n" || $0 == ";" || $0 == "|" }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var seen = Set<String>()
        var tags: [String] = []
        for part in parts {
            let words = part.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            for word in words {
                guard let normalized = normalizeTagToken(word) else { continue }
                if seen.contains(normalized) { continue }
                seen.insert(normalized)
                tags.append(normalized)
                break
            }
            if tags.count == limit { break }
        }

        if tags.count < limit, let sourceText = sourceText {
            let additional = extractFallbackTags(
                from: sourceText,
                excluding: seen,
                limit: limit - tags.count
            )
            for token in additional {
                if seen.contains(token) { continue }
                seen.insert(token)
                tags.append(token)
                if tags.count == limit { break }
            }
        }

        return tags
    }

    static func truncateText(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars))
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
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        let bbox = OCRBoundingBox(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
        let block = OCRBlock(text: trimmed, confidence: 1.0, bbox: bbox, order: 0)
        return [OCRPage(pageIndex: 0, blocks: [block])]
    }

    private func handleSourceDeletion(sourceId: UUID) {
        let derived = documents.filter { $0.sourceDocumentId == sourceId }
        for doc in derived {
            if shouldAutoOCR(for: doc.type) && (doc.ocrPages == nil || doc.ocrPages?.isEmpty == true) {
                let trimmed = Self.truncateText(doc.content, maxChars: maxOCRChars)
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
