import SwiftUI
import UIKit
import Foundation
import Vision
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import QuickLook

// No need for TempDocumentManager - using DocumentManager.swift

struct Document: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let title: String
    let content: String
    let summary: String
    let dateCreated: Date
    let type: DocumentType
    let imageData: [Data]? // Store scanned images
    let pdfData: Data? // Store generated PDF
    let originalFileData: Data? // Store original file for QuickLook preview
    
    init(title: String, content: String, summary: String, dateCreated: Date, type: DocumentType, imageData: [Data]?, pdfData: Data?, originalFileData: Data? = nil) {
        self.id = UUID()
        self.title = title
        self.content = content
        self.summary = summary
        self.dateCreated = dateCreated
        self.type = type
        self.imageData = imageData
        self.pdfData = pdfData
        self.originalFileData = originalFileData
    }
    
    init(id: UUID, title: String, content: String, summary: String, dateCreated: Date, type: DocumentType, imageData: [Data]?, pdfData: Data?, originalFileData: Data? = nil) {
        self.id = id
        self.title = title
        self.content = content
        self.summary = summary
        self.dateCreated = dateCreated
        self.type = type
        self.imageData = imageData
        self.pdfData = pdfData
        self.originalFileData = originalFileData
    }
    
    enum DocumentType: String, CaseIterable, Codable {
        case pdf = "PDF"
        case docx = "Word Document"
        case image = "Image"
        case scanned = "Scanned Document"
        case text = "Text Document"
    }
    
    // Hashable conformance
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    // Equatable conformance
    static func == (lhs: Document, rhs: Document) -> Bool {
        return lhs.id == rhs.id
    }
}

struct TabContainerView: View {
    var body: some View {
        TabView {
            DocumentsView()
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("Documents")
                }
            
            NativeChatView()
                .tabItem {
                    Image(systemName: "message")
                    Text("Chat")
                }
        }
    }
}

struct DocumentsView: View {
    @StateObject private var documentManager = DocumentManager()
    @State private var showingDocumentPicker = false
    @State private var showingScanner = false
    @State private var isProcessing = false
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText = ""
    @State private var showingDocumentPreview = false
    @State private var previewDocumentURL: URL?
    @State private var currentDocument: Document?
    @State private var showingAISummary = false
    @State private var isOpeningPreview = false
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var documentToRename: Document?
    
    var body: some View {
        NavigationView {
            ZStack {
                VStack {
                // Debug: Print current document count whenever view refreshes
                let _ = print("🖥️ DocumentsView: Current document count: \\(documentManager.documents.count)")
                let _ = print("🖥️ DocumentsView: Documents: \\(documentManager.documents.map { $0.title })")
                
                if documentManager.documents.isEmpty && !isProcessing {
                    VStack(spacing: 20) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.system(size: 60))
                            .foregroundColor(.secondary)
                        
                        Text("No Documents Yet")
                            .font(.title2)
                            .fontWeight(.medium)
                        
                        Text("Import documents or scan with OCR to get started")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        
                        VStack(spacing: 12) {
                            Button("Scan Document") {
                                showingScanner = true
                            }
                            .buttonStyle(.borderedProminent)
                            
                            Button("Import Files") {
                                showingDocumentPicker = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ZStack {
                        List {
                            ForEach(documentManager.documents, id: \ .id) { document in
                                Button(action: {
                                    openDocumentPreview(document: document)
                                }) {
                                    DocumentRowView(
                                        document: document,
                                        onRename: { renameDocument(document) },
                                        onDelete: { deleteDocument(document) },
                                        onConvert: { convertDocument(document) }
                                    )
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .contentShape(Rectangle())
                                .buttonStyle(PlainButtonStyle())
                            }
                            .onDelete(perform: deleteDocuments)
                        }
                        
                        if isOpeningPreview {
                            ZStack {
                                Rectangle()
                                    .fill(.ultraThinMaterial)
                                    .ignoresSafeArea()
                                VStack(spacing: 12) {
                                    ProgressView()
                                        .scaleEffect(1.2)
                                    Text("Opening preview...")
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            
            // Full-screen processing overlay
            if isProcessing {
                ZStack {
                    Rectangle()
                        .fill(.ultraThinMaterial)
                        .ignoresSafeArea(.all)
                    VStack(spacing: 16) {
                        ProgressView()
                            .scaleEffect(1.5)
                        Text("Processing document...")
                            .font(.headline)
                            .foregroundColor(.primary)
                    }
                }

                }

                // Full-screen processing overlay
                if isProcessing {
                    ZStack {
                        Rectangle()
                            .fill(.ultraThinMaterial)
                            .ignoresSafeArea(.all)
                        VStack(spacing: 16) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Processing document...")
                                .font(.headline)
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Test Add Document") {
                            print("🧪 Test: Creating test document")
                            let testDocument = Document(
                                title: "Test Document",
                                content: "This is a test document to verify functionality.",
                                summary: "Test summary",
                                dateCreated: Date(),
                                type: .text,
                                imageData: nil,
                                pdfData: nil
                            )
                            documentManager.addDocument(testDocument)
                            print("🧪 Test: Test document added")
                        }
                        
                        Button("Scan Document") {
                            showingScanner = true
                        }
                        Button("Import Files") {
                            showingDocumentPicker = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in
                processImportedFiles(urls)
            }
        }
        .sheet(isPresented: $showingScanner) {
            if VNDocumentCameraViewController.isSupported {
                DocumentScannerView { scannedImages in
                    self.scannedImages = scannedImages
                    self.prepareNamingDialog(for: scannedImages)
                }
            } else {
                SimpleCameraView { scannedText in
                    processScannedText(scannedText)
                }
            }
        }
        .alert("Name Document", isPresented: $showingNamingDialog) {
            TextField("Document name", text: $customName)
            
            Button("Use Suggested") {
                finalizeDocument(with: suggestedName)
            }
            
            Button("Use Custom") {
                finalizeDocument(with: customName.isEmpty ? suggestedName : customName)
            }
            
            Button("Cancel", role: .cancel) {
                scannedImages.removeAll()
                extractedText = ""
            }
        } message: {
            Text("Suggested name: \"\(suggestedName)\"\n\nWould you like to use this name or enter a custom one?")
        }
        .alert("Rename Document", isPresented: $showingRenameDialog) {
            TextField("Document name", text: $renameText)
            
            Button("Rename") {
                guard let document = documentToRename else { return }
                let newTitle = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !newTitle.isEmpty else { return }

                if let idx = documentManager.documents.firstIndex(where: { $0.id == document.id }) {
                    let old = documentManager.documents[idx]
                    let updated = Document(
                        id: old.id,
                        title: newTitle,
                        content: old.content,
                        summary: old.summary,
                        dateCreated: old.dateCreated,
                        type: old.type,
                        imageData: old.imageData,
                        pdfData: old.pdfData,
                        originalFileData: old.originalFileData
                    )
                    documentManager.documents[idx] = updated

                    // Persist via an existing public save-triggering method.
                    documentManager.updateSummary(for: updated.id, to: updated.summary)
                }

                documentToRename = nil
            }
            
            Button("Cancel", role: .cancel) {
                documentToRename = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for the document")
        }
        .sheet(isPresented: $showingDocumentPreview, onDismiss: { isOpeningPreview = false }) {
            if let url = previewDocumentURL, let document = currentDocument {
                DocumentPreviewView(url: url, document: document, onAISummary: {
                    showingDocumentPreview = false
                    showingAISummary = true
                })
            }
        }
        .sheet(isPresented: $showingAISummary) {
            if let document = currentDocument {
                DocumentSummaryView(document: document)
                    .environmentObject(documentManager)
            }
        }
    }
    
    private func deleteDocuments(offsets: IndexSet) {
        for index in offsets {
            let document = documentManager.documents[index]
            documentManager.deleteDocument(document)
        }
    }
    
    // Menu actions
    private func renameDocument(_ document: Document) {
        documentToRename = document
        renameText = document.title
        showingRenameDialog = true
    }
    
    private func deleteDocument(_ document: Document) {
        documentManager.deleteDocument(document)
    }
    
    private func convertDocument(_ document: Document) {
        // TODO: Implement document conversion functionality
        print("Convert document: \(document.title)")
    }
    
    private func processImportedFiles(_ urls: [URL]) {
        print("📱 UI: Starting to process \\(urls.count) imported files")
        isProcessing = true
        
        // Process each file synchronously to avoid async issues
        var processedCount = 0
        
        for url in urls {
            print("📱 UI: Processing file: \\(url.lastPathComponent)")
            print("📱 UI: File URL: \\(url.absoluteString)")
            print("📱 UI: File exists: \\(FileManager.default.fileExists(atPath: url.path))")
            
            // Try to access the security scoped resource
            let didStartAccess = url.startAccessingSecurityScopedResource()
            print("📱 UI: Security scoped access: \\(didStartAccess)")
            
            // Even if security access fails, try to process the file
            if let document = documentManager.processFile(at: url) {
                print("📱 UI: ✅ Successfully created document: \\(document.title)")
                print("📱 UI: Document content preview: \\(String(document.content.prefix(100)))...")
                
                documentManager.addDocument(document)
                processedCount += 1
                print("📱 UI: Document added. Total documents now: \\(documentManager.documents.count)")
            } else {
                print("❌ UI: Failed to create document for: \\(url.lastPathComponent)")
            }
            
            // Stop accessing security scoped resource if we started it
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        print("📱 UI: ✅ Processing complete. Processed \\(processedCount)/\\(urls.count) files")
        print("📱 UI: Final document count: \\(documentManager.documents.count)")
        
        // Force UI refresh
        DispatchQueue.main.async {
            self.isProcessing = false
            print("📱 UI: UI refresh triggered")
        }
    }
    
    private func processScannedText(_ text: String) {
        isProcessing = true
        
        let document = Document(
            title: "Scanned Document \(documentManager.documents.count + 1)",
            content: text,
            summary: "Processing summary...",
            dateCreated: Date(),
            type: .scanned,
            imageData: nil,
            pdfData: nil
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }
    
    private func prepareNamingDialog(for images: [UIImage]) {
        guard let firstImage = images.first else { return }
        
        isProcessing = true
        
        // Extract text from first image to get content for AI naming
        print("Starting OCR extraction for AI naming...")
        let firstPageText = performOCR(on: firstImage)
        print("First page OCR result: \(firstPageText.prefix(100))...") // Log first 100 chars
        
        // Process all images for full content
        var allText = ""
        for (index, image) in images.enumerated() {
            print("Processing page \(index + 1) for OCR...")
            let pageText = performOCR(on: image)
            allText += "Page \(index + 1):\n\(pageText)\n\n"
            print("Page \(index + 1) OCR completed: \(pageText.count) characters")
        }
        extractedText = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("Total extracted text: \(extractedText.count) characters")
        
        // Use AI to suggest document name
        if !firstPageText.isEmpty && firstPageText != "No text found in image" && !firstPageText.contains("OCR failed") {
            print("Using AI to generate document name from OCR text")
            generateAIDocumentName(from: firstPageText)
        } else {
            print("OCR extraction failed or returned no text, using default name")
            // Fallback to default name
            suggestedName = "Scanned Document"
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        }
    }
    
    private func generateAIDocumentName(from text: String) {
        func sanitizeTitle(_ s: String) -> String {
            var name = s
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Replace any non-letter/digit with space to keep readable words
            name = name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
            // Collapse whitespace and trim
            name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return name.isEmpty ? "Scanned Document" : name
        }
        func titleCase(_ s: String) -> String {
            return s.split(separator: " ").map { w in
                let lw = w.lowercased()
                return lw.prefix(1).uppercased() + lw.dropFirst()
            }.joined(separator: " ")
        }
        func heuristicName(from text: String) -> String {
            // Extract first few meaningful words
            let stop: Set<String> = ["the","a","an","and","or","of","to","for","in","on","by","with","from","at","as","is","are","was","were","be","been","being"]
            let tokens = text
                .replacingOccurrences(of: "[^A-Za-z0-9 ]+", with: " ", options: .regularExpression)
                .lowercased()
                .split(separator: " ")
                .filter { !$0.isEmpty && $0.count > 2 && !stop.contains(String($0)) }
            let words = Array(tokens.prefix(3))
            if words.isEmpty { return "Scanned Document" }
            return titleCase(words.joined(separator: " "))
        }
        // Enhanced prompt for better document name generation
        let prompt = """
        <<<SUMMARY_REQUEST>>>You are analyzing OCR-extracted text from a scanned document. Create a short, descriptive name following these rules:
        
        STRICT REQUIREMENTS:
        - Exactly 2-3 words maximum
        - Use Title Case (First Letter Of Each Word Capitalized)
        - Be specific and descriptive
        - No generic words like "Document", "Text", "File"
        - No file extensions
        
        Examples of good names:
        - "Meeting Notes"
        - "Invoice Receipt"
        - "Lab Report"
        - "Contract Agreement"
        
        OCR Text from scanned document:
        \(text.prefix(800))
        
        Response format: Just the 2-3 word name, nothing else.
        """
        
        print("🏷️ DocumentsView: Generating AI document name from OCR text")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🏷️ DocumentsView: Got name suggestion result: \(String(describing: result))")
            DispatchQueue.main.async {
                if let result = result as? String, !result.isEmpty {
                    // Clean up the AI response, keep up to 3 words, then sanitize for filesystem
                    let cleanResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let words = cleanResult.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .prefix(3)
                    let joined = words.joined(separator: " ")
                    let friendly = titleCase(sanitizeTitle(joined))
                    self.suggestedName = friendly.isEmpty ? heuristicName(from: text) : friendly
                } else {
                    print("❌ DocumentsView: Empty or nil name suggestion result")
                    self.suggestedName = heuristicName(from: text)
                }
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentsView: Name generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.suggestedName = heuristicName(from: text)
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        })
    }
    
    private func finalizeDocument(with name: String) {
        guard !scannedImages.isEmpty else { return }
        
        isProcessing = true
        
        var imageDataArray: [Data] = []
        for image in scannedImages {
            if let imageData = image.jpegData(compressionQuality: 0.95) {
                imageDataArray.append(imageData)
            }
        }
        
        // Generate PDF from images
        let pdfData = createPDF(from: scannedImages)
        
        let document = Document(
            title: name,
            content: extractedText,
            summary: "Processing summary...",
            dateCreated: Date(),
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            documentManager.addDocument(document)
            isProcessing = false
            
            // Clear temporary data
            scannedImages.removeAll()
            extractedText = ""
            suggestedName = ""
            customName = ""
        }
    }
    
    private func processScannedImages(_ images: [UIImage]) {
        isProcessing = true
        
        var allText = ""
        var imageDataArray: [Data] = []
        
        for (index, image) in images.enumerated() {
            let text = performOCR(on: image)
            allText += "Page \(index + 1):\n\(text)\n\n"
            
            // Save image data with high quality
            if let imageData = image.jpegData(compressionQuality: 0.95) {
                imageDataArray.append(imageData)
            }
        }
        
        // Generate PDF from images
        let pdfData = createPDF(from: images)
        
        let document = Document(
            title: "Scanned Document \(documentManager.documents.count + 1)",
            content: allText.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: "Processing summary...",
            dateCreated: Date(),
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }
    
    private func createPDF(from images: [UIImage]) -> Data? {
        let pdfData = NSMutableData()
        
        guard let dataConsumer = CGDataConsumer(data: pdfData) else { return nil }
        
        // Use standard US Letter page size (8.5 x 11 inches at 72 DPI)
        let pageWidth: CGFloat = 612  // 8.5 * 72
        let pageHeight: CGFloat = 792  // 11 * 72
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var mediaBox = pageRect
        
        guard let pdfContext = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) else { return nil }
        
        for image in images {
            pdfContext.beginPDFPage(nil)
            
            if let cgImage = image.cgImage {
                // Calculate scaling to fit image within page while maintaining aspect ratio
                let imageSize = image.size
                let imageAspectRatio = imageSize.width / imageSize.height
                let pageAspectRatio = pageWidth / pageHeight
                
                var drawRect: CGRect
                
                if imageAspectRatio > pageAspectRatio {
                    // Image is wider - fit to page width
                    let scaledHeight = pageWidth / imageAspectRatio
                    let yOffset = (pageHeight - scaledHeight) / 2
                    drawRect = CGRect(x: 0, y: yOffset, width: pageWidth, height: scaledHeight)
                } else {
                    // Image is taller - fit to page height
                    let scaledWidth = pageHeight * imageAspectRatio
                    let xOffset = (pageWidth - scaledWidth) / 2
                    drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: pageHeight)
                }
                
                pdfContext.draw(cgImage, in: drawRect)
            }
            
            pdfContext.endPDFPage()
        }
        
        pdfContext.closePDF()
        return pdfData as Data
    }
    
    private func performOCR(on image: UIImage) -> String {
        // Ensure image is properly oriented and processed
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            print("OCR: Failed to process image")
            return "Could not process image"
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        // Set supported languages (add more if needed)
        request.recognitionLanguages = ["en-US"]
        
        var recognizedText = ""
        let semaphore = DispatchSemaphore(value: 0)
        
        do {
            try requestHandler.perform([request])
            
            if let results = request.results {
                // Get all text observations and sort by position
                let textObservations = results.compactMap { observation -> (String, CGRect)? in
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    return (topCandidate.string, observation.boundingBox)
                }
                
                // Sort by Y position (top to bottom) then X position (left to right)
                let sortedObservations = textObservations.sorted { first, second in
                    let yDiff = abs(first.1.minY - second.1.minY)
                    if yDiff < 0.02 { // Same line threshold
                        return first.1.minX < second.1.minX
                    }
                    return first.1.minY > second.1.minY // Flip Y because Vision uses bottom-left origin
                }
                
                recognizedText = sortedObservations.map { $0.0 }.joined(separator: " ")
                
                // Clean up the text
                recognizedText = recognizedText
                    .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                print("OCR: Successfully extracted \(recognizedText.count) characters")
            } else {
                print("OCR: No results returned")
            }
        } catch {
            print("OCR Error: \(error.localizedDescription)")
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }
        
        return recognizedText.isEmpty ? "No text found in image" : recognizedText
    }
    
    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        // Ensure proper orientation and size for OCR
        guard let cgImage = image.cgImage else { return nil }
        
        let targetSize: CGFloat = 2048 // Good balance between quality and performance
        let imageSize = image.size
        let maxDimension = max(imageSize.width, imageSize.height)
        
        // Only resize if image is too large
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
    
    private func openDocumentPreview(document: Document) {
        isOpeningPreview = true
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExt = getFileExtension(for: document.type)
        let tempURL = tempDirectory.appendingPathComponent("\(document.title).\(fileExt)")
        
        func present(url: URL) {
            self.previewDocumentURL = url
            self.currentDocument = document
            self.showingDocumentPreview = true
        }
        
        // Prefer original file, then PDF, then first image fallback
        if let data = document.originalFileData ?? document.pdfData ?? document.imageData?.first {
            do {
                try data.write(to: tempURL)
                present(url: tempURL)
            } catch {
                print("Error creating temp file: \(error)")
                isOpeningPreview = false
            }
        } else {
            // Fallback: show content in a simple text preview via summary sheet
            self.currentDocument = document
            self.showingAISummary = true
            isOpeningPreview = false
        }
    }
    
    private func getFileExtension(for type: Document.DocumentType) -> String {
        switch type {
        case .pdf:
            return "pdf"
        case .docx:
            return "docx"
        case .text:
            return "txt"
        case .scanned:
            return "pdf"
        case .image:
            return "jpg"
        }
    }
}

struct DocumentRowView: View {
    let document: Document
    @State private var isGeneratingSummary = false

    let onRename: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void
    
    var body: some View {
        HStack(spacing: 12) {
            // First page preview image
            Group {
                if let pdfData = document.pdfData {
                    // PDF first page thumbnail
                    PDFThumbnailView(data: pdfData)
                        .frame(width: 60, height: 80)
                        .cornerRadius(6)
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                        
                } else if let imageDataArray = document.imageData,
                          !imageDataArray.isEmpty,
                          let firstImageData = imageDataArray.first,
                          let uiImage = UIImage(data: firstImageData) {
                    // First scanned page thumbnail
                    Image(uiImage: uiImage)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 60, height: 80)
                        .clipped()
                        .cornerRadius(6)
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                        
                } else {
                    // Document type specific icon
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 60, height: 80)
                        .overlay(
                            VStack(spacing: 4) {
                                Image(systemName: iconForDocumentType(document.type))
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                
                                Text(document.type.rawValue.components(separatedBy: " ").first ?? "")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        )
                        .shadow(radius: 2)
                        .allowsHitTesting(false)
                }
            }
            
            // Document info
            VStack(alignment: .leading, spacing: 8) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(nil) // Allow unlimited lines
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true) // Allow vertical expansion
                
                Spacer()
                
                Text(document.dateCreated, style: .date)
                    .font(.caption)
                    .foregroundColor(Color(.tertiaryLabel))
            }
            
            Spacer()
            
            // 3-dot menu
            Menu {
                Button(action: onRename) { Text("✏️ Rename") }
                Button(action: onDelete) { Text("🗑️ Delete") }
                Button(action: onConvert) { Text("♻️ Convert") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .frame(minHeight: 96) // Minimum height, but allows expansion
    }
    
    private func generateAISummary() {
        print("🧠 DocumentRowView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
        print("🧠 DocumentRowView: Sending summary request, content length: \(document.content.count)")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🧠 DocumentRowView: Got summary result: \(String(describing: result))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                if let result = result as? String, !result.isEmpty {
                    // Show the summary in an alert
                    let alert = UIAlertController(
                        title: "AI Summary",
                        message: result,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    
                    // Present from the current window
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootViewController = window.rootViewController {
                        rootViewController.present(alert, animated: true)
                    }
                } else {
                    print("🧠 DocumentRowView: Invalid or empty summary result")
                }
            }
        }, rejecter: { code, message, error in
            print("🧠 DocumentRowView: Summary generation failed - Code: \(String(describing: code)), Message: \(String(describing: message)), Error: \(String(describing: error))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                let alert = UIAlertController(
                    title: "Summary Failed",
                    message: "Failed to generate AI summary. Please try again.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootViewController = window.rootViewController {
                    rootViewController.present(alert, animated: true)
                }
            }
        })
    }
}

struct DocumentDetailView: View {
    let document: Document
    @State private var currentPage = 0
    @State private var showingTextView = false
    @State private var isGeneratingSummary = false
    @State private var showingDocumentPreview = false
    @State private var documentURL: URL?
    
    var body: some View {
        VStack(spacing: 0) {
            // Show PDF if available, otherwise show images
            if let pdfData = document.pdfData {
                // PDF viewer
                PDFViewRepresentable(data: pdfData)
                    .background(Color(.systemBackground))
                    
            } else if let imageDataArray = document.imageData, !imageDataArray.isEmpty {
                // Image viewer with proper scaling
                TabView(selection: $currentPage) {
                    ForEach(0..<imageDataArray.count, id: \.self) { index in
                        if let uiImage = UIImage(data: imageDataArray[index]) {
                            GeometryReader { geometry in
                                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                                    Image(uiImage: uiImage)
                                        .resizable()
                                        .interpolation(.high)
                                        .aspectRatio(contentMode: .fit)
                                        .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .background(Color(.systemBackground))
                            .tag(index)
                        }
                    }
                }
                .tabViewStyle(PageTabViewStyle())
                .indexViewStyle(PageIndexViewStyle(backgroundDisplayMode: .always))
                
                // Page indicator and controls
                HStack {
                    Button("Text View") {
                        showingTextView = true
                    }
                    .padding()
                    
                    Button("Preview") {
                        prepareDocumentForPreview()
                    }
                    .padding()
                    
                    Spacer()
                    
                    if imageDataArray.count > 1 {
                        Text("Page \(currentPage + 1) of \(imageDataArray.count)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding()
                    }
                }
                .background(Color(.systemBackground))
                
            } else {
                // Enhanced text view based on document type
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Document type indicator
                        HStack {
                            Image(systemName: iconForDocumentType(document.type))
                                .foregroundColor(.blue)
                            Text(document.type.rawValue)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.top)
                        
                        // Document content with better formatting
                        VStack(alignment: .leading, spacing: 16) {
                            // Summary section (if available and not default)
                            if !document.summary.isEmpty && document.summary != "Processing..." {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: "brain.head.profile")
                                            .foregroundColor(.orange)
                                        Text("AI Summary")
                                            .font(.headline)
                                    }
                                    
                                    Text(document.summary)
                                        .font(.body)
                                        .foregroundColor(.primary)
                                        .padding()
                                        .background(Color(.secondarySystemBackground))
                                        .cornerRadius(12)
                                }
                                
                                Divider()
                            }
                            
                            // Content section
                            VStack(alignment: .leading, spacing: 8) {
                                HStack {
                                    Image(systemName: "doc.text")
                                        .foregroundColor(.green)
                                    Text("Content")
                                        .font(.headline)
                                }
                                
                                if document.content.isEmpty {
                                    Text("No text content available")
                                        .font(.body)
                                        .foregroundColor(.secondary)
                                        .italic()
                                        .padding()
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .background(Color(.tertiarySystemBackground))
                                        .cornerRadius(12)
                                } else {
                                    Text(document.content)
                                        .font(.body)
                                        .lineSpacing(4)
                                        .padding()
                                        .background(Color(.tertiarySystemBackground))
                                        .cornerRadius(12)
                                        .textSelection(.enabled)
                                }
                            }
                        }
                        .padding(.horizontal)
                        
                        Spacer(minLength: 20)
                    }
                }
                .background(Color(.systemGroupedBackground))
            }
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingTextView) {
            NavigationView {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Summary Section
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Summary")
                                .font(.headline)
                            
                            Text(document.summary)
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                        
                        Divider()
                        
                        // Extracted Text
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Extracted Text")
                                .font(.headline)
                            
                            Text(document.content)
                                .font(.body)
                                .padding()
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                                .textSelection(.enabled)
                        }
                        
                        Spacer()
                    }
                    .padding()
                }
                .navigationTitle("Text Content")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingTextView = false
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(spacing: 12) {
                // Document Preview Button
                Button(action: {
                    prepareDocumentForPreview()
                }) {
                    HStack {
                        Image(systemName: "doc.magnifyingglass")
                        Text("Preview")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.green)
                    .clipShape(Capsule())
                }
                
                // AI Summary Button
                Button(action: {
                    generateAISummary()
                }) {
                    HStack {
                        if isGeneratingSummary {
                            ProgressView()
                                .scaleEffect(0.8)
                                .tint(.white)
                        } else {
                            Image(systemName: "brain.head.profile")
                        }
                        Text(isGeneratingSummary ? "Generating..." : "AI Summary")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.blue)
                    .clipShape(Capsule())
                }
                .disabled(isGeneratingSummary)
            }
            .padding()
        }
        .sheet(isPresented: $showingDocumentPreview) {
            if let url = documentURL {
                DocumentPreviewView(url: url)
            }
        }
    }
    
    private func generateAISummary() {
        print("🧠 DocumentRowView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
        print("🧠 DocumentRowView: Sending summary request, content length: \(document.content.count)")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🧠 DocumentRowView: Got summary result: \(String(describing: result))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                if let result = result as? String, !result.isEmpty {
                    // Show the summary in an alert
                    let alert = UIAlertController(
                        title: "AI Summary",
                        message: result,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    
                    // Present from the current window
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootViewController = window.rootViewController {
                        var presentingController = rootViewController
                        while let presented = presentingController.presentedViewController {
                            presentingController = presented
                        }
                        presentingController.present(alert, animated: true)
                    }
                } else {
                    print("❌ DocumentRowView: Empty or nil result")
                    let alert = UIAlertController(
                        title: "Error",
                        message: "Empty response from AI. Please try again.",
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootViewController = window.rootViewController {
                        var presentingController = rootViewController
                        while let presented = presentingController.presentedViewController {
                            presentingController = presented
                        }
                        presentingController.present(alert, animated: true)
                    }
                }
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentRowView: Summary generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                // Handle error
                let alert = UIAlertController(
                    title: "Error",
                    message: "Failed to generate summary: \(message ?? "Unknown error")",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootViewController = window.rootViewController {
                    var presentingController = rootViewController
                    while let presented = presentingController.presentedViewController {
                        presentingController = presented
                    }
                    presentingController.present(alert, animated: true)
                }
            }
        })
    }
    
    private func prepareDocumentForPreview() {
        // Create a temporary file for preview
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExtension = getFileExtension(for: document.type)
        let tempFileName = "preview_\(document.id).\(fileExtension)"
        let tempURL = tempDirectory.appendingPathComponent(tempFileName)
        
        // Try to get the original document data
        if let originalData = getDocumentData() {
            do {
                try originalData.write(to: tempURL)
                documentURL = tempURL
                showingDocumentPreview = true
                print("📄 DocumentDetailView: Prepared document for preview at \(tempURL)")
            } catch {
                print("📄 DocumentDetailView: Failed to prepare document for preview: \(error)")
                // Fallback to text view
                showingTextView = true
            }
        } else {
            print("📄 DocumentDetailView: No document data available, showing text view")
            showingTextView = true
        }
    }
    
    private func getDocumentData() -> Data? {
        // Return the stored original file data for QuickLook preview
        if let originalData = document.originalFileData {
            print("📄 DocumentDetailView: Retrieved \\(originalData.count) bytes of original file data")
            return originalData
        }
        
        // Fallback to PDF data if available
        if let pdfData = document.pdfData {
            print("📄 DocumentDetailView: Using PDF data as fallback (\\(pdfData.count) bytes)")
            return pdfData
        }
        
        // Fallback to image data if available
        if let imageData = document.imageData?.first {
            print("📄 DocumentDetailView: Using image data as fallback (\\(imageData.count) bytes)")
            return imageData
        }
        
        print("📄 DocumentDetailView: No document data available for preview")
        return nil
    }
    
    private func getFileExtension(for type: Document.DocumentType) -> String {
        switch type {
        case .pdf:
            return "pdf"
        case .docx:
            return "docx"
        case .text:
            return "txt"
        case .scanned:
            return "pdf"  // Scanned documents are typically saved as PDF
        case .image:
            return "jpg"
        }
    }
}

// MARK: - Helper Functions
private func iconForDocumentType(_ type: Document.DocumentType) -> String {
    switch type {
    case .pdf:
        return "doc.richtext"
    case .docx:
        return "doc.text"
    case .image:
        return "photo"
    case .scanned:
        return "doc.viewfinder"
    case .text:
        return "doc.plaintext"
    }
}

struct PDFThumbnailView: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        
        // Generate thumbnail from PDF
        if let document = PDFDocument(data: data),
           let firstPage = document.page(at: 0) {
            let pageRect = firstPage.bounds(for: .mediaBox)
            let thumbnail = firstPage.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
            imageView.image = thumbnail
        }
        
        return imageView
    }
    
    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Update if needed
    }
}

// MARK: - Document Preview View
struct OldDocumentPreviewView: View {
    let document: Document
    @Binding var showingDocumentInfo: Bool
    @State private var isGeneratingSummary = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Document Preview
            Group {
                if let pdfData = document.pdfData {
                    // PDF first page preview
                    PDFFirstPageView(data: pdfData)
                        .background(Color(.systemBackground))
                        
                } else if let imageDataArray = document.imageData, 
                          !imageDataArray.isEmpty,
                          let firstImageData = imageDataArray.first,
                          let uiImage = UIImage(data: firstImageData) {
                    // First scanned page preview
                    GeometryReader { geometry in
                        ScrollView([.horizontal, .vertical], showsIndicators: false) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .interpolation(.high)
                                .aspectRatio(contentMode: .fit)
                                .frame(maxWidth: geometry.size.width, maxHeight: geometry.size.height)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .background(Color(.systemBackground))
                    
                } else {
                    // Text document preview
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            Text(document.content.prefix(500) + (document.content.count > 500 ? "..." : ""))
                                .font(.body)
                                .padding()
                                .textSelection(.enabled)
                        }
                    }
                    .background(Color(.systemBackground))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Menu {
                    Button("Document Info") {
                        showingDocumentInfo = true
                    }
                    
                    Button("Generate AI Summary") {
                        generateAISummary()
                    }
                    
                    if document.imageData != nil || document.pdfData != nil {
                        Button("Full View") {
                            // Navigate to full document view - would need NavigationLink here
                        }
                    }
                } label: {
                    Image(systemName: "info.circle")
                }
            }
        }
        .sheet(isPresented: $showingDocumentInfo) {
            NavigationView {
                VStack(alignment: .leading, spacing: 20) {
                    // Document Information
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Document Information")
                            .font(.title2)
                            .fontWeight(.semibold)
                        
                        InfoRow(label: "Name", value: document.title)
                        InfoRow(label: "Date Added", value: DateFormatter.shortDate.string(from: document.dateCreated))
                        InfoRow(label: "Source", value: document.type == .scanned ? "Scanned" : "Manually Added")
                        InfoRow(label: "Type", value: document.type.rawValue)
                        
                        if let imageData = document.imageData {
                            InfoRow(label: "Pages", value: "\(imageData.count)")
                        }
                        
                        if !document.content.isEmpty {
                            InfoRow(label: "Content Length", value: "\(document.content.count) characters")
                        }
                    }
                    
                    Divider()
                    
                    // Content Preview
                    if !document.content.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Content Preview")
                                .font(.headline)
                            
                            Text(document.content.prefix(200) + (document.content.count > 200 ? "..." : ""))
                                .font(.body)
                                .foregroundColor(.secondary)
                                .padding()
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                    
                    Spacer()
                }
                .padding()
                .navigationTitle("Document Info")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Done") {
                            showingDocumentInfo = false
                        }
                    }
                }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            // AI Summary Button
            Button(action: {
                generateAISummary()
            }) {
                HStack {
                    if isGeneratingSummary {
                        ProgressView()
                            .scaleEffect(0.8)
                            .tint(.white)
                    } else {
                        Image(systemName: "brain.head.profile")
                    }
                    Text(isGeneratingSummary ? "Generating..." : "AI Summary")
                        .font(.caption.weight(.medium))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.blue)
                .clipShape(Capsule())
            }
            .padding()
            .disabled(isGeneratingSummary)
        }
    }
    
    private func generateAISummary() {
        print("🧠 OldDocumentPreviewView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
        print("🧠 OldDocumentPreviewView: Sending summary request, content length: \(document.content.count)")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🧠 OldDocumentPreviewView: Got summary result: \(String(describing: result))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                if let result = result as? String, !result.isEmpty {
                    // Show the summary in an alert
                    let alert = UIAlertController(
                        title: "AI Summary",
                        message: result,
                        preferredStyle: .alert
                    )
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    
                    // Present from the current window
                    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                       let window = windowScene.windows.first,
                       let rootViewController = window.rootViewController {
                        rootViewController.present(alert, animated: true)
                    }
                } else {
                    print("🧠 OldDocumentPreviewView: Invalid or empty summary result")
                }
            }
        }, rejecter: { code, message, error in
            print("🧠 OldDocumentPreviewView: Summary generation failed - Code: \(String(describing: code)), Message: \(String(describing: message)), Error: \(String(describing: error))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                let alert = UIAlertController(
                    title: "Summary Failed",
                    message: "Failed to generate AI summary. Please try again.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                
                if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                   let window = windowScene.windows.first,
                   let rootViewController = window.rootViewController {
                    rootViewController.present(alert, animated: true)
                }
            }
        })
    }
}

// MARK: - Helper Views
struct InfoRow: View {
    let label: String
    let value: String
    
    var body: some View {
        HStack {
            Text(label)
                .font(.body)
                .foregroundColor(.secondary)
                .frame(width: 100, alignment: .leading)
            
            Text(value)
                .font(.body)
                .fontWeight(.medium)
            
            Spacer()
        }
    }
}

struct PDFFirstPageView: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(data: data)
        pdfView.displayMode = .singlePage
        pdfView.autoScales = true
        pdfView.displayDirection = .vertical
        pdfView.usePageViewController(true)
        pdfView.pageShadowsEnabled = false
        pdfView.isUserInteractionEnabled = false  // Disable interaction for preview
        return pdfView
    }
    
    func updateUIView(_ uiView: PDFView, context: Context) {
        if uiView.document?.dataRepresentation() != data {
            uiView.document = PDFDocument(data: data)
        }
        // Always show first page
        if let document = uiView.document, let firstPage = document.page(at: 0) {
            uiView.go(to: firstPage)
        }
    }
}

extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

struct DocumentPicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .pdf, .rtf, .plainText, .image, .jpeg, .png, .heic,
            UTType("com.microsoft.word.doc")!,
            UTType("org.openxmlformats.wordprocessingml.document")!,
            UTType("com.microsoft.powerpoint.ppt")!,
            UTType("org.openxmlformats.presentationml.presentation")!,
            .spreadsheet,
            .json,
            .xml
        ], asCopy: true)
        
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.completion(urls)
        }
    }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: ([UIImage]) -> Void
    
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }
    
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        
        init(_ parent: DocumentScannerView) {
            self.parent = parent
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var scannedImages: [UIImage] = []
            
            for pageIndex in 0..<scan.pageCount {
                // Get the processed, cropped image from the scanner
                let image = scan.imageOfPage(at: pageIndex)
                scannedImages.append(image)
            }
            
            parent.completion(scannedImages)
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("Document scanning failed: \(error.localizedDescription)")
            controller.dismiss(animated: true)
        }
    }
}

struct SimpleCameraView: UIViewControllerRepresentable {
    let completion: (String) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        
        // Check if camera is available
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            // Fallback to photo library if camera not available (simulator)
            picker.sourceType = .photoLibrary
        }
        
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SimpleCameraView
        
        init(_ parent: SimpleCameraView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                let recognizedText = performOCR(on: image)
                parent.completion(recognizedText)
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
        
        private func performOCR(on image: UIImage) -> String {
            guard let cgImage = image.cgImage else {
                return "Could not process image"
            }
            
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            
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
    }
}

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
    @FocusState private var isFocused: Bool
    @StateObject private var documentManager = DocumentManager()

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
                                .disabled(isGenerating)
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
                                .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating ? .secondary : .white)
                                .background(
                                    Circle()
                                        .fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating ? Color(.systemFill) : Color.accentColor)
                                )
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("VaultAI")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        print("💬 NativeChatView: Sending message: '\(trimmed)'")
        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        // Smart context: Only include documents when question seems document-related
        var contextualPrompt = trimmed
        if !documentManager.documents.isEmpty && isDocumentQuery(trimmed) {
            // Use full content for detailed analysis, smart context for general questions
            let isDetailedQuery = isDetailedDocumentQuery(trimmed)
            let documentContext = isDetailedQuery ? 
                documentManager.getAllDocumentContent() : 
                documentManager.getSmartDocumentContext()
            
            let contextType = isDetailedQuery ? "full content" : "smart context (summaries/500 chars)"
            print("💬 NativeChatView: Document query detected, using \(contextType), length: \(documentContext.count)")
            
            contextualPrompt = """
            You are an AI assistant with access to the user's document collection. These documents contain OCR-extracted text from scanned pages/images and manually added files.
            
            Use this information to provide helpful, accurate responses. Note that some text may contain OCR extraction errors - use context to understand unclear parts.
            
            \(isDetailedQuery ? "Full Document Content:" : "Document Information:")
            \(documentContext)

            User: \(trimmed)
            
            \(isDetailedQuery ? "Provide a detailed response based on the full document content." : "Provide a helpful response based on the available document information. If you need more specific details, let the user know they can ask for more detailed analysis.")
            """
        } else if !documentManager.documents.isEmpty {
            print("💬 NativeChatView: General query - not including document context (performance optimization)")
        } else {
            print("💬 NativeChatView: No documents available for context")
        }

        print("💬 NativeChatView: Final prompt length: \(contextualPrompt.count)")

        // Call into RN JS via EdgeAI native module
        Task {
            do {
                guard let edgeAI = EdgeAI.shared else {
                    print("❌ NativeChatView: EdgeAI.shared is nil")
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }
                
                print("💬 NativeChatView: Calling EdgeAI.generate...")
                let reply = try await withCheckedThrowingContinuation { continuation in
                    edgeAI.generate(contextualPrompt, resolver: { result in
                        print("💬 NativeChatView: Got result from EdgeAI")
                        continuation.resume(returning: result as? String ?? "")
                    }, rejecter: { code, message, error in
                        print("❌ NativeChatView: EdgeAI rejected with code: \(code ?? "nil"), message: \(message ?? "nil")")
                        continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
                    })
                }
                
                print("💬 NativeChatView: Reply received, length: \(reply.count)")
                DispatchQueue.main.async {
                    self.isGenerating = false
                    let text = reply.isEmpty ? "(No response)" : reply
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                }
            } catch {
                print("❌ NativeChatView: Caught error: \(error)")
                DispatchQueue.main.async {
                    self.isGenerating = false
                    self.messages.append(ChatMessage(role: "assistant", text: "Error: \(error.localizedDescription)", date: Date()))
                }
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

private func formatMarkdownText(_ text: String) -> AttributedString {
    var processedText = text
    
    // Convert markdown lists to bullet points
    processedText = processedText.replacingOccurrences(of: "* ", with: "• ")
    
    // Fix malformed bold markdown: **text* → **text**
    let malformedBoldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*(?!\\*)", options: [])
    processedText = malformedBoldRegex.stringByReplacingMatches(in: processedText, options: [], range: NSRange(location: 0, length: processedText.count), withTemplate: "**$1**")
    
    // Preserve double newlines for paragraphs
    processedText = processedText.replacingOccurrences(of: "\n\n", with: "\n\n")
    
    // Create AttributedString with markdown support
    do {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let attributedString = try AttributedString(markdown: processedText, options: options)
        return attributedString
    } catch {
        // Fallback to plain text if markdown parsing fails
        return AttributedString(processedText)
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

struct PDFViewRepresentable: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(data: data)
        pdfView.autoScales = false  // Disable auto scaling to control it manually
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.backgroundColor = UIColor.systemBackground
        
        // Set initial scale to fit width
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            pdfView.scaleFactor = fitScale
            pdfView.minScaleFactor = fitScale * 0.9  // Allow slight zoom out
            pdfView.maxScaleFactor = fitScale * 4.0  // Allow zoom in up to 4x
        }
        
        return pdfView
    }
    
    func updateUIView(_ pdfView: PDFView, context: Context) {
        // Ensure proper scaling is maintained
        DispatchQueue.main.async {
            let fitScale = pdfView.scaleFactorForSizeToFit
            if pdfView.scaleFactor < fitScale * 0.9 {
                pdfView.scaleFactor = fitScale
            }
            // Update min scale factor in case view size changed
            pdfView.minScaleFactor = fitScale * 0.9
            pdfView.maxScaleFactor = fitScale * 4.0
        }
    }
}

// MARK: - QuickLook Document Preview
struct DocumentPreviewView: UIViewControllerRepresentable {
    let url: URL
    let document: Document?
    let onAISummary: (() -> Void)?
    
    init(url: URL, document: Document? = nil, onAISummary: (() -> Void)? = nil) {
        self.url = url
        self.document = document
        self.onAISummary = onAISummary
    }
    
    func makeUIViewController(context: Context) -> UIViewController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        
        // Create a container view controller to add floating buttons
        let containerController = UIViewController()
        containerController.addChild(previewController)
        containerController.view.addSubview(previewController.view)
        previewController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            previewController.view.topAnchor.constraint(equalTo: containerController.view.topAnchor),
            previewController.view.leadingAnchor.constraint(equalTo: containerController.view.leadingAnchor),
            previewController.view.trailingAnchor.constraint(equalTo: containerController.view.trailingAnchor),
            previewController.view.bottomAnchor.constraint(equalTo: containerController.view.bottomAnchor)
        ])
        previewController.didMove(toParent: containerController)
        
        // Add floating buttons
        addFloatingButtons(to: containerController, coordinator: context.coordinator)
        
        return containerController
    }
    
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // Updates handled by coordinator
    }
    
    private func addFloatingButtons(to containerController: UIViewController, coordinator: Coordinator) {
        // AI Button (bottom right)
        let aiButton = UIButton(type: .system)
        // Prefer SF Symbol if available; fallback to emoji title
        if let img = UIImage(systemName: "brain.head.profile") {
            aiButton.setImage(img, for: .normal)
            aiButton.tintColor = .white
            aiButton.imageView?.contentMode = .scaleAspectFit
        } else {
            aiButton.setTitle("🧠", for: .normal)
            aiButton.setTitleColor(.white, for: .normal)
            aiButton.titleLabel?.font = .boldSystemFont(ofSize: 20)
        }
        aiButton.backgroundColor = .systemBlue
        aiButton.layer.cornerRadius = 25
        aiButton.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        aiButton.contentHorizontalAlignment = .center
        aiButton.contentVerticalAlignment = .center
        aiButton.imageEdgeInsets = UIEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        aiButton.addTarget(coordinator, action: #selector(Coordinator.aiButtonTapped), for: .touchUpInside)
        
        containerController.view.addSubview(aiButton)
        aiButton.translatesAutoresizingMaskIntoConstraints = false
        
        NSLayoutConstraint.activate([
            // AI Button - bottom right
            aiButton.trailingAnchor.constraint(equalTo: containerController.view.safeAreaLayoutGuide.trailingAnchor, constant: -20),
            aiButton.bottomAnchor.constraint(equalTo: containerController.view.safeAreaLayoutGuide.bottomAnchor, constant: -20),
            aiButton.widthAnchor.constraint(equalToConstant: 50),
            aiButton.heightAnchor.constraint(equalToConstant: 50)
        ])
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let parent: DocumentPreviewView
        
        init(_ parent: DocumentPreviewView) {
            self.parent = parent
        }
        
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
            return 1
        }
        
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            return parent.url as QLPreviewItem
        }
        
        @objc func aiButtonTapped() {
            parent.onAISummary?()
        }
    }
}

// MARK: - Document Summary View
struct DocumentSummaryView: View {
    let document: Document
    @State private var summary: String = ""
    @State private var isGeneratingSummary = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var documentManager: DocumentManager

    private var currentDoc: Document {
        documentManager.getDocument(by: document.id) ?? document
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Document info
                    VStack(alignment: .leading, spacing: 8) {
                        Text(document.title)
                            .font(.title2)
                            .fontWeight(.bold)
                        
                        Text("Created: \(document.dateCreated, style: .date)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Text("Type: \(document.type.rawValue)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    
                    // Summary section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.orange)
                            Text("Summary")
                                .font(.headline)
                            Spacer()
                            Button("Generate") { generateAISummary() }
                                .disabled(isGeneratingSummary)
                        }
                        
                        if isGeneratingSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating summary...")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical)
                        } else if summary.isEmpty {
                            Text("Tap 'Generate' to create an AI summary of this document.")
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical)
                        } else {
                            Text(formatMarkdownText(summary))
                                .padding()
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                        }
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    
                    // Document content preview
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Document Content")
                            .font(.headline)
                        
                        ScrollView {
                            Text(currentDoc.content)
                                .font(.system(size: 14, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                        }
                        .frame(height: 200)
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(10)
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("Document Summary")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            // Repair Word content if it was previously saved as XML noise
            documentManager.refreshContentIfNeeded(for: document.id)
            // Use saved summary if available; avoid regenerating every time
            self.summary = currentDoc.summary
            if summary.isEmpty || summary == "Processing..." || summary == "Processing summary..." {
                generateAISummary()
            }
        }
    }
    
    private func generateAISummary() {
        print("🧠 DocumentSummaryView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        // Send only a mode marker and the raw source; system preprompt is injected in JS
        let prompt = "<<<SUMMARY_REQUEST>>>\n\(currentDoc.content)"
        
        print("🧠 DocumentSummaryView: Sending summary request, content length: \(currentDoc.content.count)")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🧠 DocumentSummaryView: Got summary result: \(String(describing: result))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                if let result = result as? String, !result.isEmpty {
                    self.summary = result
                    // Persist to the associated document so it isn't regenerated unnecessarily
                    self.documentManager.updateSummary(for: document.id, to: result)
                } else {
                    print("❌ DocumentSummaryView: Empty or nil result")
                    self.summary = "Failed to generate summary: Empty response. Please try again."
                }
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentSummaryView: Summary generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                self.summary = "Failed to generate summary: \(message ?? "Unknown error"). Please try again."
            }
        })
    }
}
