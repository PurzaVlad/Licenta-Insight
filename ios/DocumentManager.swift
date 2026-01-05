import Foundation
import PDFKit
import UIKit
import Vision
import SSZipArchive
import QuickLookThumbnailing

class DocumentManager: ObservableObject {
    @Published var documents: [Document] = []
    private let documentsKey = "SavedDocuments_v2"
    
    init() {
        loadDocuments()
    }
    
    // MARK: - Document Management
    
    func addDocument(_ document: Document) {
        print("💾 DocumentManager: Adding document '\\(document.title)' (\\(document.type.rawValue))")
        documents.append(document)
        print("💾 DocumentManager: Document array now has \\(documents.count) items")
        saveDocuments()
        print("💾 DocumentManager: Document saved successfully")
        
        // Generate AI summary
        generateSummary(for: document)
    }
    
    func deleteDocument(_ document: Document) {
        documents.removeAll { $0.id == document.id }
        saveDocuments()
    }

    func updateSummary(for documentId: UUID, to newSummary: String) {
        if let idx = documents.firstIndex(where: { $0.id == documentId }) {
            let old = documents[idx]
            let updated = Document(
                id: old.id,
                title: old.title,
                content: old.content,
                summary: newSummary,
                dateCreated: old.dateCreated,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveDocuments()
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
                dateCreated: old.dateCreated,
                type: old.type,
                imageData: old.imageData,
                pdfData: old.pdfData,
                originalFileData: old.originalFileData
            )
            documents[idx] = updated
            saveDocuments()
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
    
    func generateSummary(for document: Document) {
        print("🤖 DocumentManager: Generating summary for '\(document.title)'")
        // This will integrate with EdgeAI to generate summaries
        let prompt = "<<<SUMMARY_REQUEST>>>Summarize this document in 4-6 bullet points:\n\n\(document.content)"
        
        print("🤖 DocumentManager: Sending summary request, content length: \(document.content.count)")
        // Send to EdgeAI for processing
        NotificationCenter.default.post(
            name: NSNotification.Name("GenerateDocumentSummary"),
            object: nil,
            userInfo: ["documentId": document.id.uuidString, "prompt": prompt]
        )
    }
    
    func getAllDocumentContent() -> String {
        print("🤖 DocumentManager: Getting all document content, document count: \(documents.count)")
        return documents.map { document in
            """
            Document: \(document.title)
            Type: \(document.type.rawValue)
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
        case "ppt", "pptx":
            content = "PowerPoint document - text extraction coming soon"
            documentType = .docx
        case "xls", "xlsx":
            content = "Excel document - text extraction coming soon"
            documentType = .docx
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
    
    private func saveDocuments() {
        do {
            let encoded = try JSONEncoder().encode(documents)
            UserDefaults.standard.set(encoded, forKey: documentsKey)
            print("💾 DocumentManager: Successfully saved \(documents.count) documents to UserDefaults")
        } catch {
            print("❌ DocumentManager: Failed to encode documents: \(error.localizedDescription)")
        }
    }
    
    private func loadDocuments() {
        if let data = UserDefaults.standard.data(forKey: documentsKey) {
            do {
                let decodedDocuments = try JSONDecoder().decode([Document].self, from: data)
                self.documents = decodedDocuments
                print("💾 DocumentManager: Successfully loaded \(documents.count) documents from UserDefaults")
            } catch {
                print("❌ DocumentManager: Failed to decode documents: \(error.localizedDescription)")
            }
        } else {
            print("💾 DocumentManager: No saved documents found in UserDefaults")
        }
    }
    
    // MARK: - Search and Query
    
    func searchDocuments(query: String) -> [Document] {
        let lowercaseQuery = query.lowercased()
        return documents.filter { document in
            document.title.lowercased().contains(lowercaseQuery) ||
            document.content.lowercased().contains(lowercaseQuery) ||
            document.summary.lowercased().contains(lowercaseQuery)
        }
    }
}
