import SwiftUI
import UIKit
import Foundation

struct ConversionView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var selectedDocument: Document? = nil
    @AppStorage("conversionServerURL") private var conversionServerURL = "http://localhost:8787"
    @AppStorage("conversionEngine") private var conversionEngine = "auto"
    @State private var sourceFormat: DocumentFormat = .pdf
    @State private var selectedTargetFormat: DocumentFormat? = nil
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0.0
    @State private var showingResult = false
    @State private var conversionResult: ConversionResult? = nil
    @State private var showingDocumentPicker = false
    @State private var showingServerEdit = false
    @State private var serverDraft = ""
    
    enum DocumentFormat: String, CaseIterable {
        case pdf = "PDF"
        case docx = "DOCX"
        case image = "JPG"
        case pptx = "PPTX"
        case xlsx = "XLSX"
        
        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .docx: return "docx"
            case .image: return "jpg"
            case .pptx: return "pptx"
            case .xlsx: return "xlsx"
            }
        }
        
        var systemImage: String {
            switch self {
            case .pdf: return "doc.fill"
            case .docx: return "doc.text.fill"
            case .image: return "photo.fill"
            case .pptx: return "rectangle.on.rectangle"
            case .xlsx: return "tablecells"
        }
    }
    }

    enum ConversionEngine: String, CaseIterable, Identifiable {
        case auto = "Auto"
        case adobe = "Adobe"
        case libreoffice = "LibreOffice"

        var id: String { rawValue }

        var headerValue: String {
            switch self {
            case .auto: return "auto"
            case .adobe: return "adobe"
            case .libreoffice: return "libreoffice"
            }
        }
    }
    
    struct ConversionResult {
        let success: Bool
        let outputData: Data?
        let filename: String
        let message: String
    }
    
    var body: some View {
        NavigationView {
            GeometryReader { proxy in
                ScrollView {
                    VStack(spacing: 24) {
                    // Header

                    if selectedDocument == nil {
                        VStack(spacing: 16) {
                            Text("Select Document")
                                .font(.headline)
                            Button(action: { showingDocumentPicker = true }) {
                                HStack {
                                    Image(systemName: "doc.badge.plus")
                                        .font(.system(size: 28, weight: .semibold))
                                    Text("Choose Document")
                                        .font(.headline)
                                    Image(systemName: "chevron.right")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 18)
                                .padding(.vertical, 14)
                                .background(Color(.secondarySystemBackground))
                                .cornerRadius(12)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
                    } else {
                        let panelHeight: CGFloat = 220

                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .firstTextBaseline) {
                                Text("Selected Document")
                                    .font(.headline)
                                Spacer()
                                Text("Convert To")
                                    .font(.headline)
                            }

                            HStack(alignment: .center, spacing: 16) {
                                // Document Selection
                                VStack(alignment: .leading, spacing: 12) {
                                    if let document = selectedDocument {
                                        DocumentSelectionCard(document: document) {
                                            selectedDocument = nil
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)

                                // Conversion Icon
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.title2)
                                    .foregroundColor(.blue)
                                    .frame(height: panelHeight)

                                // Target Format (only)
                                VStack(alignment: .leading, spacing: 12) {
                                    ScrollView {
                                        VStack(spacing: 10) {
                                            if allowedTargetFormats.isEmpty {
                                                Text("No available conversions yet.")
                                                    .font(.headline)
                                                    .foregroundColor(.secondary)
                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                            } else {
                                                ForEach(allowedTargetFormats, id: \.self) { format in
                                                    FormatSelectionChip(
                                                        format: format,
                                                        isSelected: selectedTargetFormat == format,
                                                        isDisabled: false
                                                    ) {
                                                        selectedTargetFormat = format
                                                    }
                                                }
                                            }
                                        }
                                    }
                                    .frame(height: panelHeight)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(.horizontal)
                        .frame(maxWidth: .infinity, alignment: .center)
                    }

                    if selectedDocument != nil {
                        HStack {
                            Text("Server:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(conversionServerURL) {
                                serverDraft = conversionServerURL
                                showingServerEdit = true
                            }
                            .lineLimit(1)
                        }
                        .font(.footnote)
                        .padding(.horizontal)

                        HStack {
                            Text("Engine:")
                                .foregroundColor(.secondary)
                            Spacer()
                            Picker("Engine", selection: $conversionEngine) {
                                ForEach(ConversionEngine.allCases) { engine in
                                    Text(engine.rawValue).tag(engine.headerValue)
                                }
                            }
                            .pickerStyle(.segmented)
                            .frame(maxWidth: 240)
                        }
                        .font(.footnote)
                        .padding(.horizontal)
                    }
                    
                    if selectedDocument != nil {
                        // Conversion Button
                        VStack(spacing: 16) {
                            if isConverting {
                                VStack(spacing: 12) {
                                    ProgressView(value: conversionProgress)
                                        .progressViewStyle(LinearProgressViewStyle(tint: .blue))
                                    Text("Converting... \(Int(conversionProgress * 100))%")
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)
                            } else {
                                Button(action: performConversion) {
                                    HStack {
                                        Image(systemName: "arrow.triangle.2.circlepath")
                                        Text("Convert Document")
                                            .fontWeight(.semibold)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(canConvert ? Color.blue : Color.gray)
                                    .foregroundColor(.white)
                                    .cornerRadius(12)
                                }
                                .disabled(!canConvert)
                                .padding(.horizontal)
                            }
                        }
                    }
                    
                    Spacer(minLength: 12)
                    }
                    .frame(minHeight: proxy.size.height, alignment: .center)
                    .frame(maxWidth: .infinity)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" Convert ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPickerSheet(selectedDocument: $selectedDocument, documentManager: documentManager)
        }
        .sheet(isPresented: $showingResult) {
            if let result = conversionResult {
                ConversionResultSheet(
                    result: result,
                    documentManager: documentManager,
                    sourceFormat: sourceFormat,
                    sourceDocument: selectedDocument,
                    onDismiss: {
                    showingResult = false
                    conversionResult = nil
                })
            }
        }
        .alert("Conversion Server", isPresented: $showingServerEdit) {
            TextField("http://host:8787", text: $serverDraft)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
            Button("Save") {
                let trimmed = serverDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    conversionServerURL = trimmed
                }
                showingServerEdit = false
            }
            Button("Cancel", role: .cancel) {
                showingServerEdit = false
            }
        } message: {
            Text("Set the LibreOffice server URL.")
        }
        .onChange(of: selectedDocument) { document in
            if let document = document {
                if document.type == .docx {
                    documentManager.refreshContentIfNeeded(for: document.id)
                }
                sourceFormat = formatFromDocumentType(document.type)
                selectedTargetFormat = nil
            } else {
                selectedTargetFormat = nil
            }
        }
    }
    
    private var canConvert: Bool {
        guard selectedDocument != nil, let target = selectedTargetFormat else { return false }
        return allowedTargetFormats.contains(target) && !isConverting
    }

    private var allowedTargetFormats: [DocumentFormat] {
        switch sourceFormat {
        case .pdf:
            return [.docx, .xlsx, .pptx, .image]
        case .docx, .xlsx, .pptx, .image:
            return [.pdf]
        }
    }
    
    private func formatFromDocumentType(_ type: Document.DocumentType) -> DocumentFormat {
        switch type {
        case .pdf: return .pdf
        case .docx: return .docx
        case .image: return .image
        case .scanned: return .pdf
        case .ppt, .pptx: return .pptx
        case .xls, .xlsx: return .xlsx
        default: return .pdf
        }
    }
    
    private func performConversion() {
        guard let document = selectedDocument else { return }
        guard let target = selectedTargetFormat else { return }

        isConverting = true
        conversionProgress = 0.0
        
        // Simulate progress updates
        let timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if conversionProgress < 0.9 {
                conversionProgress += 0.05
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = convertDocument(document, from: sourceFormat, to: target)
            
            DispatchQueue.main.async {
                timer.invalidate()
                conversionProgress = 1.0
                
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    isConverting = false
                    conversionResult = result
                    showingResult = true
                }
            }
        }
    }
    
    private func convertDocument(_ document: Document, from sourceFormat: DocumentFormat, to targetFormat: DocumentFormat) -> ConversionResult {
        let latestDocument = documentManager.getDocument(by: document.id) ?? document
        let baseName = normalizedBaseName(latestDocument.title)
        let filename = "\(baseName.replacingOccurrences(of: " ", with: "_")).\(targetFormat.fileExtension)"
        
        do {
            let outputData: Data?
            var serverError: String? = nil
            
            switch (sourceFormat, targetFormat) {
            case (.docx, .pdf):
                let result = convertViaServer(document: latestDocument, to: targetFormat)
                outputData = result.data
                serverError = result.error

            case (.pptx, .pdf), (.xlsx, .pdf):
                let result = convertViaServer(document: latestDocument, to: targetFormat)
                outputData = result.data
                serverError = result.error

            case (.image, .pdf):
                if let imageData = latestDocument.imageData {
                    let images = imageData.compactMap { UIImage(data: $0) }
                    outputData = convertImagesToPDF(images)
                } else {
                    outputData = convertToPDF(content: latestDocument.content, title: latestDocument.title)
                }

            case (.pdf, .docx):
                let result = convertViaServer(document: latestDocument, to: targetFormat)
                outputData = result.data
                serverError = result.error

            case (.pdf, .xlsx), (.pdf, .pptx):
                let result = convertViaServer(document: latestDocument, to: targetFormat)
                outputData = result.data
                serverError = result.error

            case (.pdf, .image):
                outputData = convertToImage(content: latestDocument.content)
                serverError = nil

            default:
                throw ConversionError.unsupportedConversion
            }
            
            guard let data = outputData else {
                if let serverError {
                    throw ConversionError.serverFailure(serverError)
                }
                throw ConversionError.conversionFailed
            }
            
            // Save converted file to documents directory
            let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            let fileURL = documentsPath.appendingPathComponent(filename)
            try data.write(to: fileURL)
            
            return ConversionResult(
                success: true,
                outputData: data,
                filename: filename,
                message: "Successfully converted to \(targetFormat.rawValue)"
            )
            
        } catch {
            return ConversionResult(
                success: false,
                outputData: nil,
                filename: filename,
                message: "Conversion failed: \(error.localizedDescription)"
            )
        }
    }

    private func convertViaServer(document: Document, to targetFormat: DocumentFormat) -> (data: Data?, error: String?) {
        let trimmed = conversionServerURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let baseURL = URL(string: trimmed) else { return (nil, nil) }
        guard let inputData = document.originalFileData ?? document.pdfData ?? document.imageData?.first else { return (nil, nil) }

        let engineHeader = ConversionEngine.allCases.first(where: { $0.headerValue == conversionEngine })?.headerValue ?? "auto"
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/convert"
        components?.queryItems = [URLQueryItem(name: "target", value: targetFormat.fileExtension)]

        guard let url = components?.url else { return (nil, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(document.title, forHTTPHeaderField: "X-Filename")
        request.setValue(fileExtension(for: document.type), forHTTPHeaderField: "X-File-Ext")
        request.setValue(engineHeader, forHTTPHeaderField: "X-Conversion-Engine")
        request.timeoutInterval = 180
        let semaphore = DispatchSemaphore(value: 0)
        var resultData: Data?
        var errorMessage: String?

        request.httpBody = inputData

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }
            if let error {
                errorMessage = error.localizedDescription
                return
            }
            guard let http = response as? HTTPURLResponse else {
                errorMessage = "No response from server."
                return
            }
            if http.statusCode == 200 {
                resultData = data
                return
            }
            if let data, data.isEmpty == false, let text = String(data: data, encoding: .utf8) {
                errorMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
                return
            }
            errorMessage = "Server error (HTTP \(http.statusCode))."
        }
        task.resume()
        _ = semaphore.wait(timeout: .now() + 180)

        if resultData == nil && errorMessage == nil {
            errorMessage = "No response from server (timeout or network issue)."
        }
        return (resultData, errorMessage)
    }
    
    enum ConversionError: Error {
        case unsupportedConversion
        case conversionFailed
        case serverFailure(String)
        
        var localizedDescription: String {
            switch self {
            case .unsupportedConversion:
                return "This conversion is not supported yet"
            case .conversionFailed:
                return "Failed to convert document"
            case .serverFailure(let message):
                return message
            }
        }
    }
    
    // MARK: - Conversion Helper Functions

    private func normalizedBaseName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Converted_Document" }
        let knownExts: Set<String> = ["pdf","docx","doc","ppt","pptx","xls","xlsx","txt","rtf","png","jpg","jpeg","heic","html"]
        var base = (trimmed as NSString).deletingPathExtension
        let ext = (trimmed as NSString).pathExtension.lowercased()
        if !ext.isEmpty && !knownExts.contains(ext) {
            base = trimmed
        }
        return base.isEmpty ? "Converted_Document" : base
    }
    
    private func convertToPDF(content: String, title: String) -> Data? {
        let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // Letter size
        let margin: CGFloat = 54
        let contentRect = pageRect.insetBy(dx: margin, dy: margin)

        let titleText = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyText = content.trimmingCharacters(in: .whitespacesAndNewlines)

        let titleFont = UIFont.systemFont(ofSize: 18, weight: .bold)
        let bodyFont = UIFont.systemFont(ofSize: 12)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8

        let attributed = NSMutableAttributedString()
        if !titleText.isEmpty {
            attributed.append(NSAttributedString(string: "\(titleText)\n\n", attributes: [
                .font: titleFont,
                .foregroundColor: UIColor.black
            ]))
        }
        attributed.append(NSAttributedString(string: bodyText, attributes: [
            .font: bodyFont,
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]))

        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        var currentRange = CFRange(location: 0, length: 0)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let data = renderer.pdfData { context in
            while currentRange.location < attributed.length {
                context.beginPage()
                let path = CGMutablePath()
                path.addRect(contentRect)
                let frame = CTFramesetterCreateFrame(framesetter, currentRange, path, nil)
                CTFrameDraw(frame, context.cgContext)
                let visibleRange = CTFrameGetVisibleStringRange(frame)
                if visibleRange.length == 0 { break }
                currentRange.location += visibleRange.length
                currentRange.length = 0
            }
        }

        return data
    }
    
    
    private func convertToImage(content: String) -> Data? {
        let size = CGSize(width: 600, height: 800)
        let renderer = UIGraphicsImageRenderer(size: size)
        
        let image = renderer.image { context in
            // White background
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            
            // Draw text
            let textRect = CGRect(x: 20, y: 20, width: size.width - 40, height: size.height - 40)
            let font = UIFont.systemFont(ofSize: 14)
            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: UIColor.black
            ]
            
            content.draw(in: textRect, withAttributes: attributes)
        }
        
        return image.jpegData(compressionQuality: 0.8)
    }
    
    private func convertImagesToPDF(_ images: [UIImage]) -> Data? {
        let filtered = images.filter { $0.size.width > 0 && $0.size.height > 0 }
        guard !filtered.isEmpty else { return nil }

        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: filtered[0].size))
        return renderer.pdfData { context in
            for image in filtered {
                let rect = CGRect(origin: .zero, size: image.size)
                context.beginPage(withBounds: rect, pageInfo: [:])
                image.draw(in: rect)
            }
        }
    }
}

// MARK: - Conversion View Components

struct DocumentSelectionCard: View {
    let document: Document
    let onRemove: () -> Void
    
    var body: some View {
        let titleParts = splitDisplayTitle(document.title)
        let typeLabel = fileTypeLabel(documentType: document.type, titleParts: titleParts)

        HStack {
            Image(systemName: iconForDocumentType(document.type))
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(typeLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .cornerRadius(12)
        .frame(minHeight: 72)
    }
}

struct FormatSelectionChip: View {
    let format: ConversionView.DocumentFormat
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: format.systemImage)
                    .font(.system(size: 20, weight: .semibold))
                Text(format.rawValue)
                    .font(.headline)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.blue)
                }
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 12)
            .background(isSelected ? Color.blue.opacity(0.15) : Color(.tertiarySystemBackground))
            .foregroundColor(isDisabled ? .secondary : .primary)
            .cornerRadius(10)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(PlainButtonStyle())
        .disabled(isDisabled)
        .frame(height: 52)
    }
}

struct DocumentPickerSheet: View {
    @Binding var selectedDocument: Document?
    let documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                let supportedTypes: Set<Document.DocumentType> = [.pdf, .docx, .ppt, .pptx, .xls, .xlsx, .image, .scanned]
                let supportedDocuments = documentManager.documents.filter { supportedTypes.contains($0.type) }

                if supportedDocuments.isEmpty {
                    Text("No supported documents yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(supportedDocuments) { document in
                        let titleParts = splitDisplayTitle(document.title)
                        let typeLabel = fileTypeLabel(documentType: document.type, titleParts: titleParts)
                        Button(action: {
                            selectedDocument = document
                            dismiss()
                        }) {
                            HStack {
                                Image(systemName: iconForDocumentType(document.type))
                                    .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(typeLabel)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }

                                Spacer()

                                Text(formattedSize(for: document))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("Select Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
    
    private func formattedSize(for document: Document) -> String {
        let bytes: Int = {
            if let d = document.originalFileData { return d.count }
            if let d = document.pdfData { return d.count }
            if let imgs = document.imageData { return imgs.reduce(0) { $0 + $1.count } }
            return document.content.utf8.count
        }()
        
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
}

struct ConversionResultSheet: View {
    let result: ConversionView.ConversionResult
    let documentManager: DocumentManager
    let sourceFormat: ConversionView.DocumentFormat
    let sourceDocument: Document?
    let onDismiss: () -> Void
    @State private var isSaving = false
    @State private var saveSuccess = false
    @State private var didAutoSave = false
    
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                .font(.system(size: 60))
                .foregroundColor(result.success ? .green : .red)

            Text(result.success ? "Conversion Complete" : "Conversion Failed")
                .font(.title2)
                .fontWeight(.bold)

            if result.success {
                VStack(spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: iconForDocumentType(getDocumentType(from: result.filename)))
                            .font(.system(size: 24, weight: .semibold))
                            .foregroundColor(.blue)
                        Text(result.filename)
                            .font(.headline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Spacer()
                    }
                    .padding()
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)

                    if saveSuccess {
                        Text("Saved to Documents")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Text(result.message)
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .onAppear {
            if result.success && !didAutoSave {
                didAutoSave = true
                saveToDocuments()
            } else if !result.success {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    onDismiss()
                }
            }
        }
    }
    
    private func saveToDocuments() {
        guard let outputData = result.outputData else { return }
        
        isSaving = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            // Determine document type from file extension
            let documentType = self.getDocumentType(from: self.result.filename)
            
            // Extract content based on type
            var content = self.extractContent(from: outputData, type: documentType)
            if self.sourceFormat == .pdf, documentType == .docx {
                if let source = self.sourceDocument {
                    let sourceText = source.content.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !sourceText.isEmpty {
                        content = sourceText
                    }
                }
            }
            
            // Create the document
            let cleanedTitle = normalizedTitle(from: self.result.filename)
            let document = Document(
                title: cleanedTitle,
                content: content,
                summary: "Converted document - Processing summary...",
                category: .general,
                keywordsResume: "",
                dateCreated: Date(),
                type: documentType,
                imageData: documentType == .image ? [outputData] : nil,
                pdfData: documentType == .pdf ? outputData : nil,
                originalFileData: outputData
            )
            
            DispatchQueue.main.async {
                // Add to document manager and force UI update
                self.documentManager.addDocument(document)
                
                // Force refresh of the documents list
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.documentManager.objectWillChange.send()
                }
                
                self.isSaving = false
                self.saveSuccess = true
                
                // Auto dismiss after 2 seconds
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.onDismiss()
                }
            }
        }
    }
    
    private func getDocumentType(from filename: String) -> Document.DocumentType {
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return .pdf
        case "docx", "doc": return .docx
        case "ppt", "pptx": return .pptx
        case "xls", "xlsx": return .xlsx
        case "txt": return .text
        case "jpg", "jpeg", "png": return .image
        case "zip": return .zip
        default: return .text
        }
    }

    private func normalizedTitle(from filename: String) -> String {
        let base = (filename as NSString).deletingPathExtension
        let knownExts: Set<String> = ["pdf","docx","doc","ppt","pptx","xls","xlsx","txt","rtf","png","jpg","jpeg","heic","html"]
        let ext = (base as NSString).pathExtension.lowercased()
        let cleaned = knownExts.contains(ext) ? (base as NSString).deletingPathExtension : base
        return cleaned.replacingOccurrences(of: "_", with: " ").capitalized
    }
    
    private func extractContent(from data: Data, type: Document.DocumentType) -> String {
        switch type {
        case .text:
            return String(data: data, encoding: .utf8) ?? "Converted text document"
        case .docx:
            // For HTML-based DOCX files, extract basic text content
            if let htmlString = String(data: data, encoding: .utf8) {
                // Simple HTML text extraction - remove HTML tags
                let cleanText = htmlString
                    .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "&nbsp;", with: " ")
                    .replacingOccurrences(of: "&amp;", with: "&")
                    .replacingOccurrences(of: "&lt;", with: "<")
                    .replacingOccurrences(of: "&gt;", with: ">")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return cleanText.isEmpty ? "Converted Word document" : cleanText
            }
            return "Converted Word document"
        case .pdf:
            return "Converted PDF document - \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))"
        case .image:
            return "Converted image document - \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))"
        case .ppt, .pptx:
            return "Converted PowerPoint document - \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))"
        case .xls, .xlsx:
            return "Converted Excel document - \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))"
        case .zip:
            return "ZIP archive - \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))"
        default:
            return "Converted document - \(ByteCountFormatter().string(fromByteCount: Int64(data.count)))"
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
