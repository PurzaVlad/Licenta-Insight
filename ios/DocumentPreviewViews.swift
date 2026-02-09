import SwiftUI
import UIKit
import PDFKit
import QuickLook
import Foundation

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
                        HStack() {
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
                    HStack(alignment: .top) {
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
                if document.type != .image {
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
            }
            .padding()
        }
        .sheet(isPresented: $showingDocumentPreview) {
            if let url = documentURL {
                DocumentPreviewContainerView(url: url, document: document)
                    .applySquareSheetCorners()
            }
        }
    }
    
    private func generateAISummary() {
        print("🧠 DocumentRowView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document in English only. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
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
        case .ppt:
            return "ppt"
        case .pptx:
            return "pptx"
        case .xls:
            return "xls"
        case .xlsx:
            return "xlsx"
        case .text:
            return "txt"
        case .scanned:
            return "pdf"  // Scanned documents are typically saved as PDF
        case .image:
            return "jpg"
        case .zip:
            return "zip"
        }
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
                    
                    if document.type != .image {
                        Button("Generate AI Summary") {
                            generateAISummary()
                        }
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
                        InfoRow(label: "Tags", value: tagsText)
                        
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
            Group {
                // AI Summary Button
                if document.type != .image {
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
            }
            .padding()
        }
    }
    
    private func generateAISummary() {
        print("🧠 OldDocumentPreviewView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document in English only. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
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

    private var tagsText: String {
        let tags = document.tags
        if tags.isEmpty { return "None" }
        return tags.joined(separator: ", ")
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
struct DocumentPreviewContainerView: View {
    let url: URL
    let document: Document?
    let onAISummary: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    @State private var showingInfo = false
    @State private var showingSearchSheet = false
    @State private var previewController: CustomQLPreviewController?

    init(url: URL, document: Document? = nil, onAISummary: (() -> Void)? = nil) {
        self.url = url
        self.document = document
        self.onAISummary = onAISummary
    }

    // Match navigation-style dismissal: edge swipe from left to right only.
    private var edgeSwipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 20)
            .onEnded { value in
                let fromLeftEdge = value.startLocation.x <= 28
                let horizontalMove = value.translation.width
                let verticalMove = abs(value.translation.height)
                let isRightSwipe = horizontalMove > 90
                let isMostlyHorizontal = verticalMove < 60 && abs(horizontalMove) > verticalMove

                if fromLeftEdge && isRightSwipe && isMostlyHorizontal {
                    dismiss()
                }
            }
    }

    var body: some View {
        ZStack {
            // Full screen PDF preview
            DocumentPreviewNavControllerView(
                url: url,
                title: document.map { splitDisplayTitle($0.title).base } ?? "Preview",
                onDismiss: { dismiss() },
                onControllerReady: { controller in
                    previewController = controller
                }
            )
            .ignoresSafeArea()

            // Top overlay with title and buttons
            VStack {
                ZStack(alignment: .top) {
                    HStack(alignment: .top) {
                        // Back button
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.black.opacity(0.6))
                                .clipShape(Circle())
                        }
                        .padding(.leading, 20)
                        
                        Spacer()
                        
                        // Search button
                        VStack(spacing: 10) {
                            Button {
                                if document != nil {
                                    showingSearchSheet = true
                                } else {
                                    // Fallback to QuickLook search when no document context exists.
                                    triggerSearch()
                                }
                            } label: {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }

                            Button {
                                shareCurrent()
                            } label: {
                                Image(systemName: "square.and.arrow.up")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.black.opacity(0.6))
                                    .clipShape(Circle())
                            }
                        }
                        .padding(.trailing, 20)
                    }

                    // Document title
                    Text(document.map { splitDisplayTitle($0.title).base } ?? "Preview")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .padding(.top, 10)
                
                Spacer()
            }

            // Bottom buttons
            ZStack {
                if document != nil {
                    Button {
                        showingInfo = true
                    } label: {
                        Image(systemName: "info.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 54, height: 54)
                            .background(Color(.systemGray))
                            .clipShape(Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                    .padding(.leading, 20)
                    .padding(.bottom, 8)
                }

                if onAISummary != nil {
                    Button {
                        onAISummary?()
                    } label: {
                        Image(systemName: "brain.head.profile")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 50, height: 50)
                            .background(Color(.systemBlue))
                            .clipShape(Circle())
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 20)
                    .padding(.bottom, 8)
                }
            }
        }
        .interactiveDismissDisabled(true)
        .simultaneousGesture(edgeSwipeToDismiss)
        .sheet(isPresented: $showingInfo) {
            if let doc = document {
                DocumentInfoView(document: doc, fileURL: url)
            }
        }
        .sheet(isPresented: $showingSearchSheet) {
            if let doc = document {
                SearchInDocumentSheet(document: doc)
            }
        }
    }
    
    private func triggerSearch() {
        // Directly trigger search on the preview controller if available
        previewController?.triggerSearchDirectly()
    }

    private func shareCurrent() {
        let item = shareURLForCurrent() ?? url
        let activity = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        guard let root = topMostViewController() else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = root.view
            popover.sourceRect = CGRect(x: root.view.bounds.midX, y: root.view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(activity, animated: true)
    }

    private func shareURLForCurrent() -> URL? {
        guard let document else { return nil }
        let parts = splitDisplayTitle(document.title)
        let safeBase = parts.base.replacingOccurrences(of: "/", with: "-")
        let base = safeBase.isEmpty ? "Document" : safeBase
        let ext = parts.ext.isEmpty ? fallbackExtension(for: document) : parts.ext
        let filename = parts.ext.isEmpty ? "\(base).\(ext)" : "\(base).\(parts.ext)"
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(filename)

        if let data = document.originalFileData ?? document.pdfData ?? document.imageData?.first {
            try? data.write(to: tempURL)
            return tempURL
        }

        if let data = try? Data(contentsOf: url) {
            try? data.write(to: tempURL)
            return tempURL
        }

        if !document.content.isEmpty, let data = document.content.data(using: .utf8) {
            try? data.write(to: tempURL)
            return tempURL
        }

        return nil
    }

    private func fallbackExtension(for document: Document) -> String {
        switch document.type {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .ppt: return "ppt"
        case .pptx: return "pptx"
        case .xls: return "xls"
        case .xlsx: return "xlsx"
        case .text: return "txt"
        case .scanned: return "pdf"
        case .image: return "jpg"
        case .zip: return "zip"
        }
    }

    private func topMostViewController() -> UIViewController? {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return nil }
        guard let window = scene.windows.first(where: { $0.isKeyWindow }) else { return nil }
        var controller = window.rootViewController
        while let presented = controller?.presentedViewController {
            controller = presented
        }
        return controller
    }

}

struct SearchInDocumentSheet: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [String] = []

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextField("Search text", text: $query)
                    .textInputAutocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal)

                if document.content.isEmpty {
                    Text("No text content available for this document.")
                        .foregroundColor(.secondary)
                        .padding()
                } else if results.isEmpty && !query.isEmpty {
                    Text("No matches found.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    List(results, id: \.self) { snippet in
                        Text(snippet)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    .listStyle(.plain)
                }

                Spacer()
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: query) { _ in
                results = searchSnippets(in: document.content, query: query)
            }
            .onAppear {
                results = searchSnippets(in: document.content, query: query)
            }
        }
    }

    private func searchSnippets(in text: String, query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lowerText = text.lowercased()
        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        let searchTerms = tokens.isEmpty ? [trimmed.lowercased()] : tokens
        let window = 80
        var snippets: [String] = []

        for term in searchTerms.prefix(4) {
            var searchStart = lowerText.startIndex
            while snippets.count < 10,
                  let range = lowerText.range(of: term, range: searchStart..<lowerText.endIndex) {
                let start = lowerText.index(range.lowerBound, offsetBy: -window, limitedBy: lowerText.startIndex) ?? lowerText.startIndex
                let end = lowerText.index(range.upperBound, offsetBy: window, limitedBy: lowerText.endIndex) ?? lowerText.endIndex
                let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                snippets.append(snippet)
                searchStart = range.upperBound
            }
            if snippets.count >= 10 { break }
        }

        let unique = Array(NSOrderedSet(array: snippets)) as? [String] ?? snippets
        return Array(unique.prefix(10))
    }
}

struct DocumentPreviewNavControllerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onDismiss: () -> Void
    let onControllerReady: (CustomQLPreviewController) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let previewController = CustomQLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        
        // Notify that controller is ready
        DispatchQueue.main.async {
            self.onControllerReady(previewController)
        }
        
        return previewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
        let url: URL
        let onDismiss: () -> Void

        init(url: URL, onDismiss: @escaping () -> Void) {
            self.url = url
            self.onDismiss = onDismiss
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
        
        // Allow search but disable editing modes
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            return .disabled
        }
        
        // Block external app opening but allow internal actions like search
        func previewController(_ controller: QLPreviewController, shouldOpen url: URL, for item: QLPreviewItem) -> Bool {
            return false
        }
        
        // Remove specific unwanted toolbar items but allow search
        func previewController(_ controller: QLPreviewController, frameFor item: QLPreviewItem, inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>) -> CGRect {
            return CGRect.zero
        }

        @objc func handleBack() {
            onDismiss()
        }
    }
}

// Custom QLPreviewController to remove unwanted UI elements
class CustomQLPreviewController: QLPreviewController {
    
    func triggerSearchDirectly() {
        // Use the standard iOS search functionality
        becomeFirstResponder()
        let searchCommand = #selector(UIResponder.find(_:))
        if canPerformAction(searchCommand, withSender: self) {
            perform(searchCommand, with: self)
        }
    }
    
    private func findAndActivateSearch() {
        // Look for search functionality in the view hierarchy
        func findSearchController(in view: UIView) -> UISearchController? {
            if let searchController = view as? UISearchController {
                return searchController
            }
            for subview in view.subviews {
                if let found = findSearchController(in: subview) {
                    return found
                }
            }
            return nil
        }
        
        // Try to activate search through menu system
        let menuController = UIMenuController.shared
        menuController.showMenu(from: self.view, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Hide navigation bar and toolbar
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Force hide all bars and remove unwanted buttons
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
        
        // Remove share button and action button
        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil
        toolbarItems = []
        
        // Remove the dropdown button by searching through subviews
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.removeUnwantedButtons()
        }
    }
    
    private func removeUnwantedButtons() {
        // Recursively search for and hide share/action buttons
        func hideShareButtons(in view: UIView) {
            for subview in view.subviews {
                if let button = subview as? UIButton {
                    // Hide share/action buttons but keep search
                    if button.accessibilityIdentifier?.contains("share") == true ||
                       button.accessibilityIdentifier?.contains("action") == true {
                        button.isHidden = true
                    }
                }
                hideShareButtons(in: subview)
            }
        }
        hideShareButtons(in: self.view)
    }
    
    override var canBecomeFirstResponder: Bool {
        return true
    }
}

private func topSafeAreaInset() -> CGFloat {
    guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
          let window = scene.windows.first else {
        return 0
    }
    return window.safeAreaInsets.top
}

private extension View {
    @ViewBuilder
    func applySquareSheetCorners() -> some View {
        self.presentationCornerRadius(0)
    }
}

struct DocumentInfoView: View {
    let document: Document
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                Section {
                    infoRow("Name", splitDisplayTitle(document.title).base)
                    infoRow("Size", formattedSize)
                    infoRow("Source", sourceLabel)
                    infoRow("Extension", fileExtension)
                    infoRow("Date Added", dateAdded)
                    infoRow("Tags", tagsText)
                }

                Section("Extracted OCR") {
                    if ocrText.isEmpty {
                        Text("No OCR text available.")
                            .foregroundColor(.secondary)
                    } else {
                        Text(ocrText)
                            .font(.footnote)
                            .textSelection(.enabled)
                            .foregroundColor(.primary)
                    }
                }

            }
            .navigationTitle("Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
    }

    private var sourceLabel: String {
        document.type == .scanned ? "Scanned" : "Imported"
    }

    private var fileExtension: String {
        // Prefer the actual file URL extension when present.
        let ext = fileURL.pathExtension.lowercased()
        if !ext.isEmpty { return ext }

        switch document.type {
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .ppt: return "ppt"
        case .pptx: return "pptx"
        case .xls: return "xls"
        case .xlsx: return "xlsx"
        case .image: return "jpg"
        case .scanned: return "pdf"
        case .text: return "txt"
        case .zip: return "zip"
        }
    }

    private var formattedSize: String {
        let bytes: Int = {
            if let d = document.originalFileData { return d.count }
            if let d = document.pdfData { return d.count }
            if let imgs = document.imageData { return imgs.reduce(0) { $0 + $1.count } }
            return document.content.utf8.count
        }()

        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    private var dateAdded: String {
        DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .short)
    }

    private var tagsText: String {
        let tags = document.tags
        if tags.isEmpty { return "None" }
        return tags.joined(separator: ", ")
    }

    private var ocrText: String {
        guard let pages = document.ocrPages, !pages.isEmpty else { return "" }
        return buildStructuredText(from: pages, includePageLabels: true)
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
}

// MARK: - Document Summary View
struct DocumentSummaryView: View {
    let document: Document
    @State private var summary: String = ""
    @State private var isGeneratingSummary = false
    @State private var hasCanceledCurrent = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var documentManager: DocumentManager

    private var currentDoc: Document {
        documentManager.getDocument(by: document.id) ?? document
    }

    private var supportsAISummary: Bool {
        document.type != .image
    }

    private var hasLiveSource: Bool {
        if let sourceId = currentDoc.sourceDocumentId,
           documentManager.getDocument(by: sourceId) != nil {
            return true
        }
        return false
    }

    private var isSummaryUnavailable: Bool {
        hasLiveSource && (summary.isEmpty || summary == DocumentManager.summaryUnavailableMessage || isSummaryPlaceholder(summary))
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Summary section
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Image(systemName: "brain.head.profile")
                                .foregroundColor(.orange)
                            Text("Summary")
                                .font(.headline)
                            Spacer()
                            if supportsAISummary {
                                if isGeneratingSummary {
                                    Button("Cancel") { cancelSummary() }
                                } else if hasUsableSummary {
                                    Button("Regenerate") { generateAISummary(force: true) }
                                } else if isSummaryUnavailable {
                                    Button("Generate Anyway") { generateAISummary(force: true) }
                                } else {
                                    Button("Generate") { generateAISummary(force: false) }
                                }
                            }
                        }
                        
                        if !supportsAISummary {
                            Text("Summaries are unavailable for image files.")
                                .foregroundColor(.secondary)
                                .padding(.vertical)
                        } else if isGeneratingSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating summary...")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical)
                        } else if isSummaryUnavailable {
                            Text(DocumentManager.summaryUnavailableMessage)
                                .foregroundColor(.secondary)
                                .padding(.vertical)
                        } else if summary.isEmpty {
                            Text("No summary.")
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
            self.isGeneratingSummary = supportsAISummary && isSummaryPlaceholder(self.summary)
        }
        .onChange(of: currentDoc.summary) { newValue in
            if summary != newValue {
                summary = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryGenerationStatus"))) { notification in
            guard let userInfo = notification.userInfo,
                  let idString = userInfo["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }
            guard docId == document.id else { return }
            if let active = userInfo["isActive"] as? Bool {
                if active {
                    if !hasCanceledCurrent {
                        isGeneratingSummary = true
                    }
                } else {
                    isGeneratingSummary = false
                    hasCanceledCurrent = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CancelDocumentSummary"))) { notification in
            guard let idString = notification.userInfo?["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }
            guard docId == document.id else { return }
            hasCanceledCurrent = true
            isGeneratingSummary = false
        }
    }

    private var hasUsableSummary: Bool {
        !isSummaryPlaceholder(summary) && !isSummaryUnavailable
    }

    private func isSummaryPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary..."
    }
    
    private func generateAISummary(force: Bool) {
        print("🧠 DocumentSummaryView: Requesting AI summary for '\(document.title)'")
        isGeneratingSummary = true
        documentManager.generateSummary(for: currentDoc, force: force)
    }

    private func cancelSummary() {
        hasCanceledCurrent = true
        isGeneratingSummary = false
        NotificationCenter.default.post(
            name: NSNotification.Name("CancelDocumentSummary"),
            object: nil,
            userInfo: ["documentId": document.id.uuidString]
        )
    }
}

// MARK: - Conversion View
