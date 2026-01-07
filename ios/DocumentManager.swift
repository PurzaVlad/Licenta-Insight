import Foundation
import PDFKit
import UIKit
import Vision
import SSZipArchive
import QuickLookThumbnailing

class DocumentManager: ObservableObject {
    @Published var documents: [Document] = []
    @Published var folders: [DocumentFolder] = []
    @Published var prefersGridLayout: Bool = false
    @Published var activeFolderNavigationId: UUID? = nil
    private let documentsKey = "SavedDocuments_v2" // legacy (migration only)
    private let documentsFileName = "SavedDocuments_v2.json"

    private struct PersistedState: Codable {
        var documents: [Document]
        var folders: [DocumentFolder]
        var prefersGridLayout: Bool
    }
    
    init() {
        loadDocuments()
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
        let dir = appSupport.appendingPathComponent("VaultAI", isDirectory: true)
        if !fm.fileExists(atPath: dir.path) {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent(documentsFileName)
    }
    
    // MARK: - Document Management
    
    func addDocument(_ document: Document) {
        print("💾 DocumentManager: Adding document '\\(document.title)' (\\(document.type.rawValue))")
        var updated = Self.withInferredMetadataIfNeeded(document)

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
                category: updated.category,
                keywordsResume: updated.keywordsResume,
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
        
        // Generate AI summary
        generateSummary(for: document)
    }
    
    func deleteDocument(_ document: Document) {
        documents.removeAll { $0.id == document.id }
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
                category: old.category,
                keywordsResume: old.keywordsResume,
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

    func updateContent(for documentId: UUID, to newContent: String) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: newContent,
                summary: old.summary,
                category: old.category,
                keywordsResume: old.keywordsResume,
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
            category: old.category,
            keywordsResume: old.keywordsResume,
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
                    category: old.category,
                    keywordsResume: old.keywordsResume,
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
                        category: old.category,
                        keywordsResume: old.keywordsResume,
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
    
    func generateSummary(for document: Document, force: Bool = false) {
        print("🤖 DocumentManager: Generating summary for '\(document.title)'")
        // This will integrate with EdgeAI to generate summaries
        let prompt = "<<<SUMMARY_REQUEST>>>Summarize the document content at a high level. Use short bullet points only when helpful. Avoid listing line items, prices, or long enumerations; instead label the document type (e.g., \"price list\", \"invoice\", \"contract\"). Bold key terms (names, dates, totals) using **bold**. No introduction, no commentary, no suggestions, no feedback, nothing else besides summary content. Do not write the word \"Summary\". Keep the response concise:\n\n\(document.content)"
        
        print("🤖 DocumentManager: Sending summary request, content length: \(document.content.count)")
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
            Content Length: \(document.content.count) characters
            
            ---
            
            """
        }.joined()
    }
    
    func getSmartDocumentContext() -> String {
        print("🤖 DocumentManager: Getting smart document context, document count: \(documents.count)")
        return documents.map { document in
            // Use summary if available and meaningful, otherwise use first 500 characters
            let hasUsableSummary = !document.summary.isEmpty && 
                                  document.summary != "Processing..." && 
                                  document.summary != "Processing summary..."
            
            let contentToUse = hasUsableSummary ? document.summary : String(document.content.prefix(500))
            let contentType = hasUsableSummary ? "Summary:" : "Content (first 500 chars):"
            
            return """
            Document: \(document.title)
            Type: \(document.type.rawValue)
            Date: \(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .short, timeStyle: .none))
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
        var documentType: Document.DocumentType = .text
        
        switch fileExtension {
        case "pdf":
            content = extractTextFromPDF(url: url)
            documentType = .pdf
        case "txt", "rtf":
            content = extractTextFromTXT(url: url)
            documentType = .text
        case "jpg", "jpeg", "png", "heic":
            content = extractTextFromImage(url: url)
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
        case "ppt":
            content = "PowerPoint document - text extraction coming soon"
            documentType = .ppt
        case "pptx":
            content = "PowerPoint document - text extraction coming soon"
            documentType = .pptx
        case "xls":
            content = extractTextFromSpreadsheetViaOCR(url: url)
            documentType = .xls
        case "xlsx":
            content = extractTextFromSpreadsheetViaOCR(url: url)
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
        
        let document = Document(
            title: fileName,
            content: content,
            summary: "Processing...",
            category: .general,
            keywordsResume: "",
            dateCreated: Date(),
            type: documentType,
            imageData: imageData,
            pdfData: pdfData,
            originalFileData: originalFileData
        )
        
        print("📄 DocumentManager: ✅ Document created successfully:")
        print("📄 DocumentManager:   - Title: \\(document.title)")
        print("📄 DocumentManager:   - Type: \\(document.type.rawValue)")
        print("📄 DocumentManager:   - Content length: \\(document.content.count)")
        print("📄 DocumentManager:   - Has image data: \\(document.imageData != nil)")
        print("📄 DocumentManager:   - Has PDF data: \\(document.pdfData != nil)")
        
        return document
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
    
    private func extractTextFromImage(url: URL) -> String {
        guard let image = UIImage(contentsOfFile: url.path) else {
            return "Could not load image"
        }
        
        return performOCR(on: image)
    }
    
    private func performOCR(on image: UIImage) -> String {
        guard let cgImage = image.cgImage else {
            return "Could not process image"
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        
        var recognizedText = ""
        
        do {
            try requestHandler.perform([request])
            if let results = request.results {
                recognizedText = results.compactMap { result in
                    result.topCandidates(1).first?.string
                }.joined(separator: "\n")
            }
        } catch {
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }
        
        return recognizedText.isEmpty ? "No text found in image" : recognizedText
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

    @available(iOS 13.0, *)
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
        if #available(iOS 13.0, *) {
            if let img = generateDOCXThumbnail(url: url) {
                return performOCR(on: img)
            }
        }
        return nil
    }

    private func extractTextFromSpreadsheetViaOCR(url: URL) -> String {
        if #available(iOS 13.0, *) {
            if let img = generateDOCXThumbnail(url: url) {
                let text = performOCR(on: img)
                if !text.isEmpty && !text.contains("OCR failed") {
                    return formatExtractedText(text)
                }
            }
        }
        return "Imported spreadsheet. Text extraction is limited on this file."
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
                    let backfilled = decodedDocuments.map { Self.withInferredMetadataIfNeeded($0) }
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
                let backfilled = decodedDocuments.map { Self.withInferredMetadataIfNeeded($0) }
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
                let backfilled = decodedDocuments.map { Self.withInferredMetadataIfNeeded($0) }
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
                        category: old.category,
                        keywordsResume: old.keywordsResume,
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
            document.keywordsResume.lowercased().contains(lowercaseQuery)
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
            category: inferredCategory,
            keywordsResume: inferredKeywords,
            dateCreated: doc.dateCreated,
            folderId: doc.folderId,
            sortOrder: doc.sortOrder,
            type: doc.type,
            imageData: doc.imageData,
            pdfData: doc.pdfData,
            originalFileData: doc.originalFileData
        )
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
}
