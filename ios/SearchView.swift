import SwiftUI
import UIKit

struct SearchView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void
    let onExit: () -> Void
    let onOpenTools: (String) -> Void
    let onOpenConvert: (String) -> Void

    @State private var isOpeningPreview = false
    @FocusState private var isSearchFocused: Bool
    @State private var searchText = ""
    @State private var isSearchPresented = false

    private var recentDocuments: [Document] {
        documentManager.documents.sorted {
            let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
            let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
            if a != b { return a > b }
            return $0.dateCreated > $1.dateCreated
        }
    }

    private enum SearchDocMatchKind {
        case title
        case fileExtension
        case ocr
    }

    private struct SearchDocumentResult: Identifiable {
        let id: UUID
        let document: Document
        let kind: SearchDocMatchKind
    }

    private enum SearchFeatureKind {
        case tool
        case convert
    }

    private struct SearchFeatureResult: Identifiable {
        let id: String
        let title: String
        let keywords: [String]
        let kind: SearchFeatureKind
        let systemIcon: String?
        let convertIcon: ConvertIconType?

        var searchableText: String {
            ([title] + keywords).joined(separator: " ").lowercased()
        }
    }

    private var documentResults: [SearchDocumentResult] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()

        let nameMatches = documentManager.documents.filter { doc in
            let parts = splitDisplayTitle(doc.title)
            let base = parts.base.lowercased()
            return base.contains(q)
        }
        .sorted { a, b in
            let aBase = splitDisplayTitle(a.title).base.lowercased()
            let bBase = splitDisplayTitle(b.title).base.lowercased()
            let aStarts = aBase.hasPrefix(q)
            let bStarts = bBase.hasPrefix(q)
            if aStarts != bStarts { return aStarts }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        let nameIds = Set(nameMatches.map(\.id))
        let textMatches = documentManager.documents.filter { doc in
            guard !nameIds.contains(doc.id) else { return false }
            let ocrText = (doc.ocrPages ?? [])
                .flatMap(\.blocks)
                .map(\.text)
                .joined(separator: " ")
                .lowercased()
            if ocrText.contains(q) { return true }
            return doc.content.lowercased().contains(q)
        }
        .sorted { a, b in
            a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        let excludedIds = nameIds.union(textMatches.map(\.id))
        let extensionMatches = documentManager.documents.filter { doc in
            guard !excludedIds.contains(doc.id) else { return false }
            let ext = splitDisplayTitle(doc.title).ext.lowercased()
            return !ext.isEmpty && ext.contains(q)
        }
        .sorted { a, b in
            a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        let name = nameMatches.map { SearchDocumentResult(id: $0.id, document: $0, kind: .title) }
        let text = textMatches.map { SearchDocumentResult(id: $0.id, document: $0, kind: .ocr) }
        let ext = extensionMatches.map { SearchDocumentResult(id: $0.id, document: $0, kind: .fileExtension) }
        return name + text + ext
    }

    private var featureResults: [SearchFeatureResult] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()

        let features: [SearchFeatureResult] = [
            SearchFeatureResult(id: "tool-merge", title: "Merge PDF", keywords: ["tool", "organize", "combine", "merge"], kind: .tool, systemIcon: "rectangle.portrait.on.rectangle.portrait.fill", convertIcon: nil),
            SearchFeatureResult(id: "tool-split", title: "Split PDF", keywords: ["tool", "organize", "split"], kind: .tool, systemIcon: "rectangle.split.2x1.fill", convertIcon: nil),
            SearchFeatureResult(id: "tool-arrange", title: "Arrange PDF", keywords: ["tool", "organize", "arrange", "reorder"], kind: .tool, systemIcon: "line.3.horizontal.decrease", convertIcon: nil),
            SearchFeatureResult(id: "tool-rotate", title: "Rotate PDF", keywords: ["tool", "modify", "rotate"], kind: .tool, systemIcon: "rectangle.portrait.rotate", convertIcon: nil),
            SearchFeatureResult(id: "tool-compress", title: "Compress PDF", keywords: ["tool", "modify", "compress", "reduce size"], kind: .tool, systemIcon: "arrow.down.right.and.arrow.up.left", convertIcon: nil),
            SearchFeatureResult(id: "tool-sign", title: "Sign PDF", keywords: ["tool", "protect", "sign", "signature"], kind: .tool, systemIcon: "signature", convertIcon: nil),

            SearchFeatureResult(id: "convert-pdf-docx", title: "PDF to DOCX", keywords: ["convert", "pdf", "docx", "word"], kind: .convert, systemIcon: nil, convertIcon: .pdfToDocx),
            SearchFeatureResult(id: "convert-pdf-pptx", title: "PDF to PPTX", keywords: ["convert", "pdf", "pptx", "powerpoint"], kind: .convert, systemIcon: nil, convertIcon: .pdfToPptx),
            SearchFeatureResult(id: "convert-pdf-xlsx", title: "PDF to XLSX", keywords: ["convert", "pdf", "xlsx", "excel"], kind: .convert, systemIcon: nil, convertIcon: .pdfToXlsx),
            SearchFeatureResult(id: "convert-pdf-jpg", title: "PDF to JPG", keywords: ["convert", "pdf", "jpg", "image"], kind: .convert, systemIcon: nil, convertIcon: .pdfToJpg),
            SearchFeatureResult(id: "convert-docx-pdf", title: "DOCX to PDF", keywords: ["convert", "docx", "pdf", "word"], kind: .convert, systemIcon: nil, convertIcon: .docxToPdf),
            SearchFeatureResult(id: "convert-pptx-pdf", title: "PPTX to PDF", keywords: ["convert", "pptx", "pdf", "powerpoint"], kind: .convert, systemIcon: nil, convertIcon: .pptxToPdf),
            SearchFeatureResult(id: "convert-xlsx-pdf", title: "XLSX to PDF", keywords: ["convert", "xlsx", "pdf", "excel"], kind: .convert, systemIcon: nil, convertIcon: .xlsxToPdf),
            SearchFeatureResult(id: "convert-jpg-pdf", title: "JPG to PDF", keywords: ["convert", "jpg", "pdf", "image"], kind: .convert, systemIcon: nil, convertIcon: .jpgToPdf)
        ]

        return features.filter { item in
            item.searchableText.contains(q)
        }
        .sorted { a, b in
            let aStarts = a.title.lowercased().hasPrefix(q)
            let bStarts = b.title.lowercased().hasPrefix(q)
            if aStarts != bStarts { return aStarts }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            searchList
                .focused($isSearchFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    focusSearchField()
                }
        }
        .bindGlobalOperationLoading(isOpeningPreview)
    }

    @ViewBuilder
    private var searchList: some View {
        let baseList = List {
            if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if recentDocuments.isEmpty {
                    Text("No recent documents.")
                        .foregroundColor(.secondary)
                } else {
                    Section(header: recentsHeader) {
                        ForEach(recentDocuments) { doc in
                            DocumentRowView(
                                document: doc,
                                isSelected: false,
                                isSelectionMode: false,
                                usesNativeSelection: false,
                                onSelectToggle: {},
                                onOpen: { openDocumentPreview(document: doc) },
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
            } else {
                if documentResults.isEmpty && featureResults.isEmpty {
                    Text("No matches found.")
                        .foregroundColor(.secondary)
                } else {
                    if !featureResults.isEmpty {
                        Section(header: searchSectionHeader("Features")) {
                            ForEach(featureResults) { item in
                                Button {
                                    if item.kind == .tool {
                                        onOpenTools(item.id)
                                    } else {
                                        onOpenConvert(item.id)
                                    }
                                } label: {
                                    HStack(spacing: 12) {
                                        if let convertIcon = item.convertIcon {
                                            ConvertIcon(type: convertIcon)
                                        } else if let systemIcon = item.systemIcon {
                                            Image(systemName: systemIcon)
                                                .font(.system(size: 18, weight: .semibold))
                                                .frame(width: 24, height: 24)
                                                .foregroundStyle(Color("Primary"))
                                        }

                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.title)
                                                .foregroundColor(.primary)
                                            Text(item.kind == .tool ? "Open in Tools" : "Open in Convert")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 6)
                                }
                                .buttonStyle(.plain)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 16))
                            }
                        }
                    }

                    if !documentResults.isEmpty {
                        Section(header: searchSectionHeader("Documents")) {
                            ForEach(documentResults) { item in
                                searchDocumentRow(item)
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.plain)
        .hideScrollBackground()

        if #available(iOS 17.0, *) {
            baseList
                .listSectionSpacing(0)
                .searchable(
                    text: $searchText,
                    isPresented: $isSearchPresented,
                    placement: .automatic,
                    prompt: "Search documents"
                )
                .onSubmit(of: .search) {
                    dismissSearchKeyboard()
                }
        } else if #available(iOS 16.0, *) {
            baseList
                .searchable(text: $searchText, placement: .automatic, prompt: "Search documents")
                .onSubmit(of: .search) {
                    dismissSearchKeyboard()
                }
        } else {
            baseList
        }
    }

    private var recentsHeader: some View {
        searchSectionHeader("Recents")
    }

    private func searchDocumentRow(_ item: SearchDocumentResult) -> some View {
        let document = item.document
        let parts = splitDisplayTitle(document.title)
        let dateText = DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .none)
        let typeText = fileTypeLabel(documentType: document.type, titleParts: parts)
        let matchText: String
        switch item.kind {
        case .title:
            matchText = "Name match"
        case .fileExtension:
            matchText = "Extension match"
        case .ocr:
            matchText = "Text match"
        }

        return Button {
            openDocumentPreview(document: document)
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Group {
                        if document.type == .zip {
                            ZStack {
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color("Primary"))

                                Image(systemName: zipSymbolName())
                                    .foregroundColor(.white)
                                    .font(.system(size: 20))
                            }
                        } else {
                            DocumentThumbnailView(document: document, size: CGSize(width: 50, height: 50))
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                    .frame(width: 50, height: 50)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(parts.base)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundColor(.primary)
                            .lineLimit(2)

                        HStack(spacing: 4) {
                            Text(dateText)
                            Text("•")
                            Text(typeText)
                            Text("•")
                            Text(matchText)
                        }
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()
                    .padding(.horizontal, 16)
            }
        }
        .buttonStyle(.plain)
    }

    private func searchSectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
            Spacer()
        }
        .padding(.leading, 8)
        .padding(.top, 0)
    }

    private func openDocumentPreview(document: Document) {
        isOpeningPreview = true
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExt = getFileExtension(for: document.type)
        let tempURL = tempDirectory.appendingPathComponent("preview_\(document.id).\(fileExt)")

        func present(url: URL) {
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.onOpenPreview(document, url)
                    self.isOpeningPreview = false
                }
            }
        }

        if let data = document.originalFileData ?? document.pdfData ?? document.imageData?.first {
            do {
                try data.write(to: tempURL)
                present(url: tempURL)
            } catch {
                print("Error creating temp file: \(error)")
                isOpeningPreview = false
            }
        } else {
            self.isOpeningPreview = false
            self.onShowSummary(document)
            isOpeningPreview = false
        }
    }

    private func focusSearchField() {
        DispatchQueue.main.async {
            isSearchPresented = true
            isSearchFocused = true
        }
    }

    private func dismissSearchKeyboard() {
        isSearchFocused = false
        isSearchPresented = false
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
        case .image:
            return "jpg"
        case .scanned:
            return "pdf"
        case .zip:
            return "zip"
        }
    }
}
