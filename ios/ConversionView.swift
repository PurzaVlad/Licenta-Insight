import SwiftUI
import UIKit
import PDFKit
import WebKit
import Foundation
import QuickLookThumbnailing

struct ConversionView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var selectedDocument: Document? = nil
    @State private var sourceFormat: DocumentFormat = .pdf
    @State private var selectedTargetFormat: DocumentFormat? = nil
    @State private var isConverting = false
    @State private var conversionProgress: Double = 0.0
    @State private var showingResult = false
    @State private var conversionResult: ConversionResult? = nil
    @State private var showingDocumentPicker = false
    
    enum DocumentFormat: String, CaseIterable {
        case pdf = "PDF"
        case docx = "Word Document"
        case txt = "Text File"
        case image = "Image (JPEG)"
        case pptx = "PowerPoint (.pptx)"
        case xlsx = "Excel (.xlsx)"
        
        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .docx: return "docx"
            case .txt: return "txt"
            case .image: return "jpg"
            case .pptx: return "pptx"
            case .xlsx: return "xlsx"
            }
        }
        
        var systemImage: String {
            switch self {
            case .pdf: return "doc.fill"
            case .docx: return "doc.text.fill"
            case .txt: return "doc.plaintext.fill"
            case .image: return "photo.fill"
            case .pptx: return "rectangle.on.rectangle"
            case .xlsx: return "tablecells"
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

                    let panelHeight: CGFloat = 220

                    HStack(alignment: .center, spacing: 16) {
                        // Document Selection
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Select Document")
                                .font(.headline)
                            
                            if let document = selectedDocument {
                                DocumentSelectionCard(document: document) {
                                    selectedDocument = nil
                                }
                            } else {
                                Button(action: { showingDocumentPicker = true }) {
                                    HStack {
                                        Image(systemName: "doc.badge.plus")
                                            .font(.system(size: 28, weight: .semibold))
                                        Image(systemName: "chevron.right")
                                            .foregroundColor(.secondary)
                                    }
                                    .padding()
                                    .background(Color(.secondarySystemBackground))
                                    .cornerRadius(12)
                                    .frame(minHeight: 72)
                                }
                                .frame(maxWidth:.infinity, alignment: .center)
                                .foregroundColor(.primary)
                            }
                        }
                        .frame(height: panelHeight, alignment: .center)
                        
                        // Conversion Icon
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .padding(.top,24)
                            .font(.title2)
                            .foregroundColor(.blue)
                            .frame(height: panelHeight)
                        
                        // Target Format (only)
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Convert To")
                                .font(.headline)
                            
                            ScrollView {
                                VStack(spacing: 10) {
                                    ForEach(DocumentFormat.allCases, id: \.self) { format in
                                        let isDisabled = selectedDocument != nil && format == sourceFormat
                                        FormatSelectionChip(
                                            format: format,
                                            isSelected: selectedTargetFormat == format,
                                            isDisabled: isDisabled
                                        ) {
                                            if !isDisabled {
                                                selectedTargetFormat = format
                                            }
                                        }
                                    }
                                }
                            }
                            .frame(height: panelHeight - 32)
                        }
                    }
                    .padding(.horizontal)
                    .frame(maxWidth: .infinity, alignment: .center)
                    
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
                ConversionResultSheet(result: result, documentManager: documentManager, onDismiss: {
                    showingResult = false
                    conversionResult = nil
                })
            }
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
        selectedDocument != nil &&
            selectedTargetFormat != nil &&
            sourceFormat != selectedTargetFormat &&
            !isConverting
    }
    
    private func formatFromDocumentType(_ type: Document.DocumentType) -> DocumentFormat {
        switch type {
        case .pdf: return .pdf
        case .docx: return .docx
        case .text: return .txt
        case .image: return .image
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
            
            switch (sourceFormat, targetFormat) {
            case (.pdf, .txt), (.docx, .txt), (.image, .txt):
                outputData = latestDocument.content.data(using: .utf8)
                
            case (.txt, .pdf), (.image, .pdf):
                outputData = convertToPDF(content: latestDocument.content, title: latestDocument.title)

            case (.docx, .pdf):
                outputData = convertDocxToPDF(document: latestDocument) ?? convertToPDF(content: latestDocument.content, title: latestDocument.title)
                
            case (.pptx, .pdf), (.xlsx, .pdf):
                outputData = convertOfficeToPDF(document: latestDocument)
                
            case (.pdf, .docx), (.txt, .docx):
                outputData = convertToDocx(content: latestDocument.content, title: latestDocument.title)
                
            case (.pdf, .image), (.docx, .image), (.txt, .image), (.pptx, .image), (.xlsx, .image):
                outputData = convertToImage(content: latestDocument.content)
                
            case (.pptx, .txt), (.xlsx, .txt):
                outputData = latestDocument.content.data(using: .utf8)
                
            default:
                throw ConversionError.unsupportedConversion
            }
            
            guard let data = outputData else {
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
    
    enum ConversionError: Error {
        case unsupportedConversion
        case conversionFailed
        
        var localizedDescription: String {
            switch self {
            case .unsupportedConversion:
                return "This conversion is not supported yet"
            case .conversionFailed:
                return "Failed to convert document"
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
    
    private func convertToDocx(content: String, title: String) -> Data? {
        // Create a simple Word-compatible document using HTML format
        // This creates a .docx file that Word can open
        let htmlContent = """
        <html>
        <head>
            <meta charset="UTF-8">
            <title>\(title)</title>
        </head>
        <body>
            <h1>\(title)</h1>
            <div style="font-family: Arial, sans-serif; line-height: 1.6;">
                \(content.replacingOccurrences(of: "\n", with: "<br>"))
            </div>
        </body>
        </html>
        """
        return htmlContent.data(using: .utf8)
    }

    private func convertDocxToPDF(document: Document) -> Data? {
        guard document.type == .docx else { return nil }
        guard let data = document.originalFileData else { return nil }

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_render_\(UUID().uuidString).docx")
        do {
            try data.write(to: tempURL)
        } catch {
            print("📄 Conversion: Failed to write temp docx: \(error.localizedDescription)")
            return nil
        }

        defer { try? FileManager.default.removeItem(at: tempURL) }

        let semaphore = DispatchSemaphore(value: 0)
        var renderedData: Data?
        var renderer: DocxPDFRenderer?

        DispatchQueue.main.async {
            renderer = DocxPDFRenderer(fileURL: tempURL) { data in
                renderedData = data
                semaphore.signal()
                renderer = nil
            }
            renderer?.start()
        }

        _ = semaphore.wait(timeout: .now() + 20)
        return renderedData
    }
    
    private func convertOfficeToPDF(document: Document) -> Data? {
        guard let data = document.originalFileData else { return nil }
        let ext: String = {
            switch document.type {
            case .ppt, .pptx: return "pptx"
            case .xls, .xlsx: return "xlsx"
            default: return document.type.rawValue
            }
        }()
        
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("office_render_\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: tempURL)
        } catch {
            print("📄 Conversion: Failed to write temp office file: \(error.localizedDescription)")
            return convertToPDF(content: document.content, title: document.title)
        }
        
        defer { try? FileManager.default.removeItem(at: tempURL) }
        
        if #available(iOS 13.0, *) {
            if let thumbnail = generateOfficeThumbnail(url: tempURL) {
                if let pdf = convertImageToPDF(thumbnail) {
                    return pdf
                }
            }
        }
        
        return convertToPDF(content: document.content, title: document.title)
    }
    
    @available(iOS 13.0, *)
    private func generateOfficeThumbnail(url: URL) -> UIImage? {
        let size = CGSize(width: 1400, height: 1400)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: size,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )
        
        let generator = QLThumbnailGenerator.shared
        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        
        generator.generateBestRepresentation(for: request) { rep, error in
            if let rep = rep {
                image = rep.uiImage
            } else if let error = error {
                print("📄 Conversion: Thumbnail error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        
        _ = semaphore.wait(timeout: .now() + 8)
        return image
    }
    
    private func convertToRTF(content: String) -> Data? {
        let rtfContent = "{\\\\rtf1\\\\ansi\\\\deff0 {\\\\fonttbl {\\\\f0 Times New Roman;}} \\\\f0\\\\fs24 \\(content.replacingOccurrences(of: \"\\n\", with: \"\\\\par \"))}"
        return rtfContent.data(using: .utf8)
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
    
    private func convertImageToPDF(_ image: UIImage) -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: size))
        return renderer.pdfData { context in
            context.beginPage()
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}

// MARK: - Conversion View Components

struct DocumentSelectionCard: View {
    let document: Document
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: document.type == .pdf ? "doc.fill" : "doc.text.fill")
                .font(.system(size: 32, weight: .semibold))
                .foregroundColor(.blue)
            
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(document.type.rawValue.uppercased())
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

struct FormatSelectionRow: View {
    let title: String
    @Binding var selectedFormat: ConversionView.DocumentFormat
    let isEnabled: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.secondary)
            
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ConversionView.DocumentFormat.allCases, id: \.self) { format in
                        FormatButton(
                            format: format,
                            isSelected: selectedFormat == format,
                            isEnabled: isEnabled
                        ) {
                            selectedFormat = format
                        }
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct FormatButton: View {
    let format: ConversionView.DocumentFormat
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: format.systemImage)
                    .font(.title2)
                Text(format.rawValue)
                    .font(.caption)
                    .fontWeight(.medium)
            }
            .frame(width: 80, height: 70)
            .background(isSelected ? Color.blue.opacity(0.2) : Color(.tertiarySystemBackground))
            .foregroundColor(isSelected ? .blue : (isEnabled ? .primary : .secondary))
            .cornerRadius(12)
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 2)
            )
        }
        .disabled(!isEnabled)
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
                    .font(.headline)
                Text(format.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
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
        .frame(height: 44)
    }
}

struct DocumentPickerSheet: View {
    @Binding var selectedDocument: Document?
    let documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationView {
            List {
                ForEach(documentManager.documents) { document in
                    Button(action: {
                        selectedDocument = document
                        dismiss()
                    }) {
                        HStack {
                            Image(systemName: document.type == .pdf ? "doc.fill" : "doc.text.fill")
                                .foregroundColor(.blue)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(document.title)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                Text(document.type.rawValue.uppercased())
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
    let onDismiss: () -> Void
    @State private var showingShareSheet = false
    @State private var isSaving = false
    @State private var saveSuccess = false
    
    var body: some View {
        NavigationView {
            VStack(spacing: 24) {
                // Result Icon
                Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 60))
                    .foregroundColor(result.success ? .green : .red)
                
                // Result Message
                VStack(spacing: 8) {
                    Text(result.success ? "Conversion Complete" : "Conversion Failed")
                        .font(.title2)
                        .fontWeight(.bold)
                    
                    Text(result.message)
                        .font(.body)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                if result.success {
                    VStack(spacing: 16) {
                        // File Info
                        VStack(spacing: 8) {
                            Text("Generated File")
                                .font(.headline)
                            Text(result.filename)
                                .font(.body)
                                .foregroundColor(.secondary)
                        }
                        .padding()
                        .background(Color(.secondarySystemBackground))
                        .cornerRadius(12)
                        
                        // Success message for save
                        if saveSuccess {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                Text("Saved to Documents")
                                    .foregroundColor(.green)
                                    .fontWeight(.medium)
                            }
                            .padding()
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                        }
                        
                        // Action Buttons
                        VStack(spacing: 12) {
                            // Save to Documents button
                            Button(action: saveToDocuments) {
                                HStack {
                                    if isSaving {
                                        ProgressView()
                                            .scaleEffect(0.8)
                                    } else {
                                        Image(systemName: saveSuccess ? "checkmark.circle.fill" : "folder.badge.plus")
                                    }
                                    Text(saveSuccess ? "Saved to Documents" : "Save in Documents")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(saveSuccess ? Color.green : Color.orange)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            .disabled(isSaving || saveSuccess)
                            
                            Button(action: {
                                showingShareSheet = true
                            }) {
                                HStack {
                                    Image(systemName: "square.and.arrow.up")
                                    Text("Share File")
                                }
                                .frame(maxWidth: .infinity)
                                .padding()
                                .background(Color.blue)
                                .foregroundColor(.white)
                                .cornerRadius(12)
                            }
                            
                            Button(action: onDismiss) {
                                Text("Done")
                                    .frame(maxWidth: .infinity)
                                    .padding()
                                    .background(Color(.secondarySystemBackground))
                                    .foregroundColor(.primary)
                                    .cornerRadius(12)
                            }
                        }
                    }
                } else {
                    Button(action: onDismiss) {
                        Text("OK")
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color(.secondarySystemBackground))
                            .foregroundColor(.primary)
                            .cornerRadius(12)
                    }
                }
                
                Spacer()
            }
            .padding()
            .navigationTitle("Conversion Result")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
        .sheet(isPresented: $showingShareSheet) {
            if let data = result.outputData {
                ShareSheet(items: [data])
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
            let content = self.extractContent(from: outputData, type: documentType)
            
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
        case "txt": return .text
        case "jpg", "jpeg", "png": return .image
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

final class DocxPDFRenderer: NSObject, WKNavigationDelegate {
    private let fileURL: URL
    private let completion: (Data?) -> Void
    private var webView: WKWebView?

    init(fileURL: URL, completion: @escaping (Data?) -> Void) {
        self.fileURL = fileURL
        self.completion = completion
    }

    func start() {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 612, height: 792))
        self.webView = webView
        webView.navigationDelegate = self
        webView.isHidden = true
        webView.loadFileURL(fileURL, allowingReadAccessTo: fileURL.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let contentSize = webView.scrollView.contentSize
        let rect = CGRect(origin: .zero, size: contentSize == .zero ? webView.bounds.size : contentSize)
        let config = WKPDFConfiguration()
        config.rect = rect

        webView.createPDF(configuration: config) { result in
            switch result {
            case .success(let data):
                self.completion(data)
            case .failure(let error):
                print("📄 Conversion: WKWebView PDF render failed: \(error.localizedDescription)")
                self.completion(nil)
            }
        }
    }
}
