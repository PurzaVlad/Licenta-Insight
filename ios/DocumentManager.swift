import Foundation
import PDFKit
import UIKit
import Vision

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
    
    func generateSummary(for document: Document) {
        // This will integrate with EdgeAI to generate summaries
        let prompt = "Please provide a concise summary of this document:\n\n\(document.content)"
        
        // Send to EdgeAI for processing
        NotificationCenter.default.post(
            name: NSNotification.Name("GenerateDocumentSummary"),
            object: nil,
            userInfo: ["documentId": document.id.uuidString, "prompt": prompt]
        )
    }
    
    // MARK: - File Processing
    
    func processFile(at url: URL) -> Document? {
        print("📄 DocumentManager: Processing file at \\(url.lastPathComponent)")
        guard url.startAccessingSecurityScopedResource() else {
            print("❌ DocumentManager: Failed to access security scoped resource")
            return nil
        }
        defer { url.stopAccessingSecurityScopedResource() }
        
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
        
        do {
            let fileData = try Data(contentsOf: url)
            print("📄 DocumentManager: Successfully read \\(fileData.count) bytes from file")
            
            switch fileExtension {
            case "pdf":
                pdfData = fileData
                print("📄 DocumentManager: PDF data stored for preview")
            case "jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff":
                imageData = [fileData]
                print("📄 DocumentManager: Image data stored for preview")
            case "docx", "doc", "rtf", "txt":
                // For text documents, we could store as PDF data for better viewing
                // For now, just use text content
                print("📄 DocumentManager: Text document processed")
            default:
                print("📄 DocumentManager: File data read but no specific preview format")
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
            pdfData: pdfData
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
        do {
            // Try to read as RTF/Word document using NSAttributedString
            let attributedString = try NSAttributedString(url: url, options: [
                .documentType: NSAttributedString.DocumentType.rtf,
                .characterEncoding: String.Encoding.utf8.rawValue
            ], documentAttributes: nil)
            
            let plainText = attributedString.string
            return plainText.isEmpty ? "No text content found in document" : plainText
            
        } catch {
            // Fallback: try reading as plain text
            do {
                let content = try String(contentsOf: url, encoding: .utf8)
                return content.isEmpty ? "No text content found in document" : content
            } catch {
                return "Could not read Word document: \(error.localizedDescription)\n\nThis document may require a different reader or may be password protected."
            }
        }
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
    
    func getAllDocumentContent() -> String {
        return documents.map { document in
            "Document: \\(document.title)\\nType: \\(document.type.rawValue)\\nSummary: \\(document.summary)\\n\\nOCR Content:\\n\\(document.content)\\n\\n---\\n\\n"
        }.joined()
    }
}
