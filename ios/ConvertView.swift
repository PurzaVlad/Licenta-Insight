import SwiftUI

struct ConvertView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        ConvertSectionHeader(title: "From PDF")
                        ConvertRow(title: "PDF to DOCX", icon: .pdfToDocx) {
                            ConvertFlowView(
                                targetFormat: .docx,
                                allowedSourceTypes: [.pdf]
                            )
                            .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PDF to PPTX", icon: .pdfToPptx) {
                            ConvertFlowView(
                                targetFormat: .pptx,
                                allowedSourceTypes: [.pdf]
                            )
                            .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PDF to XLSX", icon: .pdfToXlsx) {
                            ConvertFlowView(
                                targetFormat: .xlsx,
                                allowedSourceTypes: [.pdf]
                            )
                            .environmentObject(documentManager)
                        }
                        ConvertRow(title: "PDF to JPG", icon: .pdfToJpg) {
                            ConvertFlowView(
                                targetFormat: .image,
                                allowedSourceTypes: [.pdf]
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
            }
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(.secondarySystemGroupedBackground)
            : Color(.systemBackground)
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
    @State private var conversionResult: ConversionView.ConversionResult? = nil
    @State private var searchText = ""

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
        .overlay(conversionOverlay)
    }

    @ViewBuilder
    private var conversionOverlay: some View {
        if isConverting || conversionResult != nil {
            ZStack {
                Color.black.opacity(0.25).ignoresSafeArea()
                VStack(spacing: 12) {
                    if let result = conversionResult {
                        Image(systemName: result.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 52))
                            .foregroundColor(result.success ? .green : .red)
                        Text(result.success ? "Conversion Complete" : "Conversion Failed")
                            .font(.headline)
                    } else {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle())
                        Text("Converting…")
                            .font(.headline)
                    }
                }
                .padding(24)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground))
                )
                .shadow(color: Color.black.opacity(0.15), radius: 10, x: 0, y: 6)
            }
        }
    }

    private func startConversion() {
        guard let document = selectedDocument else { return }
        isConverting = true
        conversionResult = nil

        let sourceFormat = conversionFormatFromDocumentType(document.type)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = convertDocument(
                documentManager: documentManager,
                document: document,
                from: sourceFormat,
                to: targetFormat
            )
            DispatchQueue.main.async {
                isConverting = false
                conversionResult = result
                if result.success {
                    saveConversionResult(
                        result: result,
                        documentManager: documentManager,
                        sourceFormat: sourceFormat,
                        sourceDocument: document
                    ) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            dismiss()
                        }
                    }
                } else {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        dismiss()
                    }
                }
            }
        }
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

private extension View {
    @ViewBuilder
    func scrollDismissesKeyboardIfAvailable() -> some View {
        if #available(iOS 16.4, *) {
            scrollDismissesKeyboard(.interactively)
                .scrollBounceBehavior(.always)
        } else if #available(iOS 16.0, *) {
            scrollDismissesKeyboard(.interactively)
        } else {
            self
        }
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
