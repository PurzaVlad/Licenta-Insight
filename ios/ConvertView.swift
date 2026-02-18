import SwiftUI
import Foundation
import UIKit
import AVFoundation
import PDFKit
import SSZipArchive
import OSLog

struct ConvertView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @AppStorage("pendingConvertDeepLink") private var pendingConvertDeepLink = ""
    @State private var deepLinkConfig: ConvertDeepLinkConfig?
    @State private var showDeepLinkFlow = false

    var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            ConvertSectionHeader(title: "From PDF")
                            ConvertRow(title: "PDF to DOCX", icon: .pdfToDocx) {
                                ConvertFlowView(
                                    targetFormat: .docx,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PDF to PPTX", icon: .pdfToPptx) {
                                ConvertFlowView(
                                    targetFormat: .pptx,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PDF to XLSX", icon: .pdfToXlsx) {
                                ConvertFlowView(
                                    targetFormat: .xlsx,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PDF to JPG", icon: .pdfToJpg) {
                                ConvertFlowView(
                                    targetFormat: .image,
                                    allowedSourceTypes: [.pdf, .scanned]
                                )
                                .environmentObject(documentManager)
                            }

                            ConvertSectionHeader(title: "To PDF")
                            ConvertRow(title: "DOCX to PDF", icon: .docxToPdf) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.docx]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "PPTX to PDF", icon: .pptxToPdf) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.pptx]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "XLSX to PDF", icon: .xlsxToPdf) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.xlsx]
                                )
                                .environmentObject(documentManager)
                            }
                            ConvertRow(title: "JPG to PDF", icon: .jpgToPdf, showsDivider: false) {
                                ConvertFlowView(
                                    targetFormat: .pdf,
                                    allowedSourceTypes: [.image]
                                )
                                .environmentObject(documentManager)
                            }
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .fill(cardBackground)
                        )
                        .padding(.horizontal, 16)

                        Spacer()
                    }
                    .padding(.top, 8)
                }
                NavigationLink(isActive: $showDeepLinkFlow) {
                    if let config = deepLinkConfig {
                        ConvertFlowView(
                            targetFormat: config.targetFormat,
                            allowedSourceTypes: config.allowedSourceTypes
                        )
                        .environmentObject(documentManager)
                    } else {
                        EmptyView()
                    }
                } label: {
                    EmptyView()
                }
                .hidden()
            }
            .hideScrollBackground()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Convert")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .modifier(SharedSettingsSheetBackgroundModifier())
            }
            .onAppear {
                handlePendingDeepLinkIfNeeded()
            }
            .onChange(of: pendingConvertDeepLink) { _ in
                handlePendingDeepLinkIfNeeded()
            }
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(.secondarySystemGroupedBackground)
            : Color(.systemBackground)
    }

    private struct ConvertDeepLinkConfig {
        let targetFormat: ConversionView.DocumentFormat
        let allowedSourceTypes: Set<Document.DocumentType>
    }

    private func handlePendingDeepLinkIfNeeded() {
        guard !pendingConvertDeepLink.isEmpty else { return }
        guard let config = convertDeepLinkConfig(for: pendingConvertDeepLink) else {
            pendingConvertDeepLink = ""
            return
        }
        pendingConvertDeepLink = ""
        deepLinkConfig = config
        showDeepLinkFlow = false
        DispatchQueue.main.async {
            showDeepLinkFlow = true
        }
    }

    private func convertDeepLinkConfig(for id: String) -> ConvertDeepLinkConfig? {
        switch id {
        case "convert-pdf-docx":
            return ConvertDeepLinkConfig(targetFormat: .docx, allowedSourceTypes: [.pdf, .scanned])
        case "convert-pdf-pptx":
            return ConvertDeepLinkConfig(targetFormat: .pptx, allowedSourceTypes: [.pdf, .scanned])
        case "convert-pdf-xlsx":
            return ConvertDeepLinkConfig(targetFormat: .xlsx, allowedSourceTypes: [.pdf, .scanned])
        case "convert-pdf-jpg":
            return ConvertDeepLinkConfig(targetFormat: .image, allowedSourceTypes: [.pdf, .scanned])
        case "convert-docx-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.docx])
        case "convert-pptx-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.pptx])
        case "convert-xlsx-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.xlsx])
        case "convert-jpg-pdf":
            return ConvertDeepLinkConfig(targetFormat: .pdf, allowedSourceTypes: [.image])
        default:
            return nil
        }
    }
}

struct ConvertRow<Destination: View>: View {
    let title: String 
    let icon: ConvertIconType
    let destination: Destination
    let showsDivider: Bool

    init(title: String, icon: ConvertIconType, showsDivider: Bool = true, @ViewBuilder destination: () -> Destination) {
        self.title = title
        self.icon = icon
        self.destination = destination()
        self.showsDivider = showsDivider
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                ConvertIcon(type: icon)

                Text(title)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundColor(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color("Primary"))
            }
            .padding(.vertical, 6)
        }
        if showsDivider {
            Divider()
        }
    }
}

private struct ConvertFlowView: View {
    let targetFormat: ConversionView.DocumentFormat
    let allowedSourceTypes: Set<Document.DocumentType>
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedId: UUID? = nil
    @State private var selectionSet: Set<UUID> = []
    @State private var isAdjustingSelection = false
    @State private var isConverting = false
    @State private var isGlobalLoadingActive = false
    @State private var searchText = ""
    @State private var showScannedPDFChoice = false
    @State private var pendingScannedChoiceDocument: Document? = nil

    private var documents: [Document] {
        documentManager.documents.filter { allowedSourceTypes.contains($0.type) }
    }

    private var filteredDocuments: [Document] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return documents }
        let needle = trimmed.lowercased()
        return documents.filter { doc in
            splitDisplayTitle(doc.title).base.lowercased().contains(needle)
        }
    }

    private var selectedDocument: Document? {
        guard let selectedId else { return nil }
        return documentManager.getDocument(by: selectedId)
    }

    var body: some View {
        List(selection: $selectionSet) {
            if filteredDocuments.isEmpty {
                Text("No documents available.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredDocuments) { document in
                    DocumentRowView(
                        document: document,
                        isSelected: selectionSet.contains(document.id),
                        isSelectionMode: true,
                        usesNativeSelection: true,
                        onSelectToggle: {},
                        onOpen: {},
                        onRename: {},
                        onMoveToFolder: {},
                        onDelete: {},
                        onConvert: {},
                        onShare: {}
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                }
            }
        }
        .listStyle(.plain)
        .hideScrollBackground()
        .scrollDismissesKeyboardIfAvailable()
        .environment(\.editMode, .constant(.active))
        .navigationTitle("Select Document")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search documents")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Convert") {
                    startConversion()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedId == nil || isConverting)
            }
        }
        .onAppear {
            selectionSet = selectedId.map { [$0] } ?? []
        }
        .onChange(of: selectionSet) { newSet in
            if isAdjustingSelection { return }
            isAdjustingSelection = true
            defer { isAdjustingSelection = false }

            if let first = newSet.first {
                selectionSet = [first]
                selectedId = first
            } else {
                selectedId = nil
            }
        }
        .onDisappear {
            if isGlobalLoadingActive {
                GlobalLoadingBridge.setOperationLoading(false)
                isGlobalLoadingActive = false
            }
        }
        .alert("Scanned PDF Detected", isPresented: $showScannedPDFChoice, presenting: pendingScannedChoiceDocument) { _ in
            Button("Extracted OCR (editable)") {
                if let doc = pendingScannedChoiceDocument {
                    pendingScannedChoiceDocument = nil
                    beginConversion(for: doc, mode: .ocrEditable)
                }
            }
            Button("Visual quality (non-editable)") {
                if let doc = pendingScannedChoiceDocument {
                    pendingScannedChoiceDocument = nil
                    beginConversion(for: doc, mode: .visualImage)
                }
            }
            Button("Cancel", role: .cancel) {
                pendingScannedChoiceDocument = nil
            }
        } message: { _ in
            Text("This PDF comes from a scanned document. Choose conversion mode:\n\n• Extracted OCR (lower visual quality, editable text)\n• Visual quality (higher fidelity, image-based, non-editable text)")
        }
    }

    private func startConversion() {
        guard let document = selectedDocument else { return }
        let sourceFormat = conversionFormatFromDocumentType(document.type)

        if sourceFormat == .pdf,
           isOfficeTarget(targetFormat),
           isScannedPDFSource(document) {
            pendingScannedChoiceDocument = document
            showScannedPDFChoice = true
            return
        }

        beginConversion(for: document, mode: .ocrEditable)
    }

    private func beginConversion(for document: Document, mode: PDFToOfficeMode) {
        isConverting = true
        if !isGlobalLoadingActive {
            GlobalLoadingBridge.setOperationLoading(true)
            isGlobalLoadingActive = true
        }

        let sourceFormat = conversionFormatFromDocumentType(document.type)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = convertDocument(
                documentManager: documentManager,
                document: document,
                from: sourceFormat,
                to: targetFormat,
                pdfToOfficeMode: mode
            )
            DispatchQueue.main.async {
                isConverting = false
                if result.success {
                    saveConversionResult(
                        result: result,
                        documentManager: documentManager,
                        sourceFormat: sourceFormat,
                        sourceDocument: document
                    ) {
                        GlobalLoadingBridge.showOperationSuccess()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
                            if isGlobalLoadingActive {
                                GlobalLoadingBridge.setOperationLoading(false)
                                isGlobalLoadingActive = false
                            }
                            dismiss()
                        }
                    }
                } else {
                    if isGlobalLoadingActive {
                        GlobalLoadingBridge.setOperationLoading(false)
                        isGlobalLoadingActive = false
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func isScannedPDFSource(_ document: Document) -> Bool {
        var current: Document? = document
        var visited = Set<UUID>()
        while let doc = current, !visited.contains(doc.id) {
            visited.insert(doc.id)
            if doc.type == .scanned {
                return true
            }
            guard let sourceId = doc.sourceDocumentId,
                  let next = documentManager.getDocument(by: sourceId) else {
                break
            }
            current = next
        }
        return false
    }

    private func isOfficeTarget(_ format: ConversionView.DocumentFormat) -> Bool {
        format == .docx || format == .pptx || format == .xlsx
    }
}

enum ConvertIconType {
    case pdfToDocx
    case pdfToPptx
    case pdfToXlsx
    case pdfToJpg
    case docxToPdf
    case pptxToPdf
    case xlsxToPdf
    case jpgToPdf
}

struct ConvertIcon: View {
    let type: ConvertIconType

    var body: some View {
        switch type {
        case .pdfToDocx:
            pdfToDocxIcon
        case .pdfToPptx:
            pdfToPptxIcon
        case .pdfToXlsx:
            pdfToXlsxIcon
        case .pdfToJpg:
            pdfToJpgIcon
        case .docxToPdf:
            docxToPdfIcon
        case .pptxToPdf:
            pptxToPdfIcon
        case .xlsxToPdf:
            xlsxToPdfIcon
        case .jpgToPdf:
            jpgToPdfIcon
        }
    }

    private var pdfToDocxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "doc.text")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 8, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToPptxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "play.rectangle")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToXlsxIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "tablecells")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pdfToJpgIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "photo")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 6, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "richtext.page.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var docxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "doc.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var pptxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 14, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var xlsxToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 20, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "tablecells.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
    private var jpgToPdfIcon: some View {
        ZStack(alignment: .bottomLeading) {
            Image(systemName: "richtext.page")
                .font(.system(size: 18))
                .foregroundStyle(Color("Primary"))
                .offset(x: 10, y: 8)
            RoundedRectangle(cornerRadius: 4)
                .fill(.background)
                .frame(width: 20, height: 18)
                .offset(x: 3, y: -2)
            Image(systemName: "photo.fill")
                .font(.system(size: 18))
                .foregroundColor(Color("Primary"))
        }
        .frame(width: 24, height: 24, alignment: .center)
    }
}

struct ConvertSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

#Preview {
  ConvertView()
}

// MARK: - Conversion Core

enum PDFToOfficeMode {
    case ocrEditable
    case visualImage
}

enum ConversionView {
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
    }

    struct ConversionResult {
        let success: Bool
        let outputData: Data?
        let filename: String
        let message: String
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
}

// MARK: - Conversion Helpers (Shared)

func conversionFormatFromDocumentType(_ type: Document.DocumentType) -> ConversionView.DocumentFormat {
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

func convertDocument(
    documentManager: DocumentManager,
    document: Document,
    from sourceFormat: ConversionView.DocumentFormat,
    to targetFormat: ConversionView.DocumentFormat,
    pdfToOfficeMode: PDFToOfficeMode = .ocrEditable
) -> ConversionView.ConversionResult {
    let latestDocument = documentManager.getDocument(by: document.id) ?? document
    let baseName = normalizedConversionBaseName(latestDocument.title)
    let canonicalFilename = conversionOutputFilename(
        sourceBaseName: baseName,
        targetExtension: targetFormat.fileExtension
    )
    let fallbackFilename = canonicalFilename

    do {
        let outputData: Data?
        var serverError: String? = nil

        switch (sourceFormat, targetFormat) {
        case (.docx, .pdf):
            let result = convertViaServer(document: latestDocument, to: targetFormat, documentManager: documentManager)
            outputData = result.data
            serverError = result.error

        case (.pptx, .pdf), (.xlsx, .pdf):
            let result = convertViaServer(document: latestDocument, to: targetFormat, documentManager: documentManager)
            outputData = result.data
            serverError = result.error

        case (.image, .pdf):
            if let imageData = documentManager.imageData(for: latestDocument.id) {
                let images = imageData.compactMap { UIImage(data: $0) }
                outputData = conversionConvertImagesToPDF(images)
            } else {
                outputData = conversionConvertToPDF(content: latestDocument.content, title: latestDocument.title)
            }

        case (.pdf, .docx):
            switch pdfToOfficeMode {
            case .ocrEditable:
                let result = convertViaServer(document: latestDocument, to: targetFormat, mode: .ocrEditable, documentManager: documentManager)
                outputData = result.data
                serverError = result.error
            case .visualImage:
                outputData = conversionConvertPDFToImageDOCX(document: latestDocument, baseName: baseName, documentManager: documentManager)
                serverError = outputData == nil ? "Failed to build image DOCX." : nil
            }

        case (.pdf, .xlsx), (.pdf, .pptx):
            let serverMode: ServerConversionMode = (pdfToOfficeMode == .visualImage) ? .visualImage : .ocrEditable
            let result = convertViaServer(document: latestDocument, to: targetFormat, mode: serverMode, documentManager: documentManager)
            outputData = result.data
            serverError = result.error

        case (.pdf, .image):
            outputData = conversionConvertToImage(content: latestDocument.content)
            serverError = nil

        default:
            throw ConversionView.ConversionError.unsupportedConversion
        }

        guard let data = outputData else {
            if let serverError {
                throw ConversionView.ConversionError.serverFailure(serverError)
            }
            throw ConversionView.ConversionError.conversionFailed
        }

        let filename = canonicalFilename

        let documentsPath = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let fileURL = documentsPath.appendingPathComponent(filename)
        try data.write(to: fileURL)

        return ConversionView.ConversionResult(
            success: true,
            outputData: data,
            filename: filename,
            message: "Successfully converted to \(targetFormat.rawValue)"
        )
    } catch {
        return ConversionView.ConversionResult(
            success: false,
            outputData: nil,
            filename: fallbackFilename,
            message: "Conversion failed: \(error.localizedDescription)"
        )
    }
}

private func conversionOutputFilename(sourceBaseName: String, targetExtension: String) -> String {
    let normalizedBase = sourceBaseName
        .replacingOccurrences(of: " ", with: "_")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    let safeBase = normalizedBase.isEmpty ? "converted" : normalizedBase
    let safeExt = targetExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let ext = safeExt.isEmpty ? "bin" : safeExt
    return "\(safeBase)_\(ext).\(ext)"
}

func saveConversionResult(
    result: ConversionView.ConversionResult,
    documentManager: DocumentManager,
    sourceFormat: ConversionView.DocumentFormat,
    sourceDocument: Document?,
    completion: @escaping () -> Void
) {
    guard result.success, let outputData = result.outputData else {
        DispatchQueue.main.async { completion() }
        return
    }

    DispatchQueue.global(qos: .userInitiated).async {
        let documentType = conversionDocumentType(from: result.filename)
        let latestSourceDocument = sourceDocument.flatMap { documentManager.getDocument(by: $0.id) } ?? sourceDocument
        var content = conversionExtractContent(from: outputData, type: documentType)
        if sourceFormat == .pdf, documentType == .docx {
            if let source = latestSourceDocument {
                let sourceText = source.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sourceText.isEmpty {
                    content = sourceText
                }
            }
        }

        let inheritedOCRPages = latestSourceDocument?.ocrPages
        let ocrPages: [OCRPage]?
        if let inheritedOCRPages, !inheritedOCRPages.isEmpty {
            ocrPages = inheritedOCRPages
        } else if documentType == .image || documentType == .xlsx {
            ocrPages = nil
        } else if documentType == .pdf {
            ocrPages = documentManager.buildVisionOCRPages(from: outputData, type: documentType)
                ?? buildPseudoOCRPagesFromText(content)
        } else {
            ocrPages = buildPseudoOCRPagesFromText(content)
        }

        let inheritedSummary = latestSourceDocument?.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let summaryText: String
        if let inheritedSummary, !inheritedSummary.isEmpty {
            summaryText = inheritedSummary
        } else {
            summaryText = "Processing summary..."
        }
        let inheritedTags = latestSourceDocument?.tags ?? []

        let cleanedTitle = normalizedConversionTitle(from: result.filename)
        let document = Document(
            title: cleanedTitle,
            content: content,
            summary: summaryText,
            ocrPages: ocrPages,
            category: .general,
            keywordsResume: "",
            tags: inheritedTags,
            sourceDocumentId: nil,
            dateCreated: Date(),
            type: documentType,
            imageData: documentType == .image ? [outputData] : nil,
            pdfData: documentType == .pdf ? outputData : nil,
            originalFileData: outputData
        )

        DispatchQueue.main.async {
            documentManager.addDocument(document)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                documentManager.objectWillChange.send()
            }
            completion()
        }
    }
}

func conversionDocumentType(from filename: String) -> Document.DocumentType {
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

func normalizedConversionTitle(from filename: String) -> String {
    let base = (filename as NSString).deletingPathExtension
    let knownExts: Set<String> = ["pdf","docx","doc","ppt","pptx","xls","xlsx","txt","rtf","png","jpg","jpeg","heic","html"]
    let ext = (base as NSString).pathExtension.lowercased()
    let cleaned = knownExts.contains(ext) ? (base as NSString).deletingPathExtension : base
    return cleaned
}

func conversionExtractContent(from data: Data, type: Document.DocumentType) -> String {
    switch type {
    case .text:
        return String(data: data, encoding: .utf8) ?? "Converted text document"
    case .docx:
        if let htmlString = String(data: data, encoding: .utf8) {
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

func buildPseudoOCRPagesFromText(_ text: String) -> [OCRPage]? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return nil }
    let bbox = OCRBoundingBox(x: 0.0, y: 0.0, width: 1.0, height: 1.0)
    let block = OCRBlock(text: trimmed, confidence: 1.0, bbox: bbox, order: 0)
    return [OCRPage(pageIndex: 0, blocks: [block])]
}

func conversionConvertToPDF(content: String, title: String) -> Data? {
    let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792)
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

    let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
    return renderer.pdfData { context in
        context.beginPage()
        attributed.draw(with: contentRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}

func conversionConvertToImage(content: String) -> Data? {
    let size = CGSize(width: 1240, height: 1754)
    let renderer = UIGraphicsImageRenderer(size: size)
    let image = renderer.image { context in
        UIColor.white.setFill()
        context.fill(CGRect(origin: .zero, size: size))

        let textRect = CGRect(x: 40, y: 40, width: size.width - 80, height: size.height - 80)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.paragraphSpacing = 8
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 16),
            .foregroundColor: UIColor.black,
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: content, attributes: attrs)
        attributed.draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
    return image.jpegData(compressionQuality: 0.92)
}

func conversionConvertImagesToPDF(_ images: [UIImage]) -> Data? {
    guard !images.isEmpty else { return nil }
    let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
    return renderer.pdfData { context in
        for image in images {
            let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
            context.beginPage(withBounds: bounds, pageInfo: [:])
            let targetRect = AVMakeRect(aspectRatio: image.size, insideRect: bounds.insetBy(dx: 24, dy: 24))
            image.draw(in: targetRect)
        }
    }
}

private func normalizedConversionBaseName(_ title: String) -> String {
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

private enum ServerConversionMode: String {
    case ocrEditable = "ocr"
    case visualImage = "image"
}

private func convertViaServer(
    document: Document,
    to targetFormat: ConversionView.DocumentFormat,
    mode: ServerConversionMode? = nil,
    documentManager: DocumentManager
) -> (data: Data?, error: String?, filename: String?) {
    guard let inputData = documentManager.anyFileData(for: document.id) else {
        return (nil, "Missing input data.", nil)
    }

    let config: ConversionConfig
    do {
        config = try ConversionConfig.load()
    } catch {
        return (nil, error.localizedDescription, nil)
    }

    var components = URLComponents(url: config.baseURL.appendingPathComponent("convert"), resolvingAgainstBaseURL: false)
    var queryItems = [URLQueryItem(name: "target", value: targetFormat.fileExtension)]
    if let mode {
        queryItems.append(URLQueryItem(name: "mode", value: mode.rawValue))
    }
    components?.queryItems = queryItems

    guard let url = components?.url else { return (nil, "Invalid conversion URL.", nil) }
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
    request.setValue(document.title, forHTTPHeaderField: "X-Filename")
    request.setValue(fileExtension(for: document.type), forHTTPHeaderField: "X-File-Ext")
    if let mode {
        request.setValue(mode.rawValue, forHTTPHeaderField: "X-Conversion-Mode")
    }
    request.timeoutInterval = 180
    let semaphore = DispatchSemaphore(value: 0)
    var resultData: Data?
    var errorMessage: String?
    var responseFilename: String?

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
            if let headerValue = http.allHeaderFields.first(where: { key, _ in
                String(describing: key).lowercased() == "content-disposition"
            })?.value as? String {
                responseFilename = ContentDisposition.filename(from: headerValue)
            }
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
    return (resultData, errorMessage, responseFilename)
}

private func conversionConvertPDFToImageDOCX(document: Document, baseName: String, documentManager: DocumentManager) -> Data? {
    guard let inputData = documentManager.originalFileData(for: document.id) ?? documentManager.pdfData(for: document.id),
          let pdf = PDFDocument(data: inputData),
          pdf.pageCount > 0 else {
        return nil
    }

    let tempRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("docx-image-\(UUID().uuidString)", isDirectory: true)
    let wordDir = tempRoot.appendingPathComponent("word", isDirectory: true)
    let relsDir = tempRoot.appendingPathComponent("_rels", isDirectory: true)
    let wordRelsDir = wordDir.appendingPathComponent("_rels", isDirectory: true)
    let mediaDir = wordDir.appendingPathComponent("media", isDirectory: true)

    do {
        try FileManager.default.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: relsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: wordRelsDir, withIntermediateDirectories: true)
    } catch {
        return nil
    }

    struct DocxImageRef {
        let filename: String
        let widthEMU: Int
        let heightEMU: Int
    }

    var imageRefs: [DocxImageRef] = []
    for idx in 0..<pdf.pageCount {
        guard let page = pdf.page(at: idx) else { continue }
        let pageRect = page.bounds(for: .mediaBox)
        let renderScale: CGFloat = 2.0
        let imageSize = CGSize(
            width: max(1, pageRect.width * renderScale),
            height: max(1, pageRect.height * renderScale)
        )
        let renderer = UIGraphicsImageRenderer(size: imageSize)
        let image = renderer.image { ctx in
            UIColor.white.set()
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            ctx.cgContext.saveGState()
            ctx.cgContext.translateBy(x: 0, y: imageSize.height)
            ctx.cgContext.scaleBy(x: 1.0, y: -1.0)
            ctx.cgContext.scaleBy(x: renderScale, y: renderScale)
            page.draw(with: .mediaBox, to: ctx.cgContext)
            ctx.cgContext.restoreGState()
        }
        guard let imageData = image.jpegData(compressionQuality: 0.92) else { continue }
        let filename = "image\(idx + 1).jpg"
        let imageURL = mediaDir.appendingPathComponent(filename)
        do {
            try imageData.write(to: imageURL)
        } catch {
            continue
        }

        let emuPerPoint = 12700.0
        let widthEMU = Int(pageRect.width * emuPerPoint)
        let heightEMU = Int(pageRect.height * emuPerPoint)
        imageRefs.append(DocxImageRef(filename: filename, widthEMU: widthEMU, heightEMU: heightEMU))
    }

    guard !imageRefs.isEmpty else {
        do { try FileManager.default.removeItem(at: tempRoot) } catch { AppLogger.conversion.warning("Failed to remove temp root: \(error.localizedDescription)") }
        return nil
    }

    let contentTypes = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
      <Default Extension="xml" ContentType="application/xml"/>
      <Default Extension="jpg" ContentType="image/jpeg"/>
      <Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
    </Types>
    """

    let packageRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
      <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
    </Relationships>
    """

    var docRels = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    """
    for (idx, ref) in imageRefs.enumerated() {
        docRels += """
        
          <Relationship Id="rId\(idx + 1)" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/image" Target="media/\(ref.filename)"/>
        """
    }
    docRels += "\n</Relationships>"

    var body = ""
    for (idx, ref) in imageRefs.enumerated() {
        body += """
        
            <w:p>
              <w:r>
                <w:drawing>
                  <wp:inline distT="0" distB="0" distL="0" distR="0" xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing">
                    <wp:extent cx="\(ref.widthEMU)" cy="\(ref.heightEMU)"/>
                    <wp:docPr id="\(idx + 1)" name="Picture \(idx + 1)"/>
                    <a:graphic xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main">
                      <a:graphicData uri="http://schemas.openxmlformats.org/drawingml/2006/picture">
                        <pic:pic xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture">
                          <pic:nvPicPr>
                            <pic:cNvPr id="\(idx + 1)" name="\(ref.filename)"/>
                            <pic:cNvPicPr/>
                          </pic:nvPicPr>
                          <pic:blipFill>
                            <a:blip r:embed="rId\(idx + 1)"/>
                            <a:stretch><a:fillRect/></a:stretch>
                          </pic:blipFill>
                          <pic:spPr>
                            <a:xfrm>
                              <a:off x="0" y="0"/>
                              <a:ext cx="\(ref.widthEMU)" cy="\(ref.heightEMU)"/>
                            </a:xfrm>
                            <a:prstGeom prst="rect"><a:avLst/></a:prstGeom>
                          </pic:spPr>
                        </pic:pic>
                      </a:graphicData>
                    </a:graphic>
                  </wp:inline>
                </w:drawing>
              </w:r>
            </w:p>
        """
    }

    let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document
      xmlns:wpc="http://schemas.microsoft.com/office/word/2010/wordprocessingCanvas"
      xmlns:mc="http://schemas.openxmlformats.org/markup-compatibility/2006"
      xmlns:o="urn:schemas-microsoft-com:office:office"
      xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"
      xmlns:m="http://schemas.openxmlformats.org/officeDocument/2006/math"
      xmlns:v="urn:schemas-microsoft-com:vml"
      xmlns:wp14="http://schemas.microsoft.com/office/word/2010/wordprocessingDrawing"
      xmlns:wp="http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing"
      xmlns:w10="urn:schemas-microsoft-com:office:word"
      xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"
      xmlns:w14="http://schemas.microsoft.com/office/word/2010/wordml"
      xmlns:wpg="http://schemas.microsoft.com/office/word/2010/wordprocessingGroup"
      xmlns:wpi="http://schemas.microsoft.com/office/word/2010/wordprocessingInk"
      xmlns:wne="http://schemas.microsoft.com/office/word/2006/wordml"
      xmlns:wps="http://schemas.microsoft.com/office/word/2010/wordprocessingShape"
      xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"
      xmlns:pic="http://schemas.openxmlformats.org/drawingml/2006/picture"
      mc:Ignorable="w14 wp14">
      <w:body>\(body)
        <w:sectPr>
          <w:pgSz w:w="12240" w:h="15840"/>
          <w:pgMar w:top="720" w:right="720" w:bottom="720" w:left="720" w:header="708" w:footer="708" w:gutter="0"/>
        </w:sectPr>
      </w:body>
    </w:document>
    """

    let contentTypesURL = tempRoot.appendingPathComponent("[Content_Types].xml")
    let packageRelsURL = relsDir.appendingPathComponent(".rels")
    let docRelsURL = wordRelsDir.appendingPathComponent("document.xml.rels")
    let docXMLURL = wordDir.appendingPathComponent("document.xml")

    do {
        try contentTypes.write(to: contentTypesURL, atomically: true, encoding: .utf8)
        try packageRels.write(to: packageRelsURL, atomically: true, encoding: .utf8)
        try docRels.write(to: docRelsURL, atomically: true, encoding: .utf8)
        try documentXML.write(to: docXMLURL, atomically: true, encoding: .utf8)
    } catch {
        do { try FileManager.default.removeItem(at: tempRoot) } catch { AppLogger.conversion.warning("Failed to remove temp root after error: \(error.localizedDescription)") }
        return nil
    }

    let zipURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(baseName)_image.docx")
    do { try FileManager.default.removeItem(at: zipURL) } catch { AppLogger.conversion.warning("Failed to remove pre-existing zip file: \(error.localizedDescription)") }
    let success = SSZipArchive.createZipFile(atPath: zipURL.path, withContentsOfDirectory: tempRoot.path)
    defer {
        do { try FileManager.default.removeItem(at: tempRoot) } catch { AppLogger.conversion.warning("Failed to remove temp root in defer: \(error.localizedDescription)") }
        do { try FileManager.default.removeItem(at: zipURL) } catch { AppLogger.conversion.warning("Failed to remove zip file in defer: \(error.localizedDescription)") }
    }
    guard success else { return nil }
    do {
        return try Data(contentsOf: zipURL)
    } catch {
        AppLogger.conversion.error("Failed to read DOCX zip data: \(error.localizedDescription)")
        return nil
    }
}
