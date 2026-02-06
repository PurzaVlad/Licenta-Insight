import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void
    let onExit: () -> Void

    @State private var query = ""
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

    private var matches: [Document] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()
        return documentManager.documents.filter { doc in
            let title = doc.title.lowercased()
            if title.hasPrefix(q) { return true }
            let base = splitDisplayTitle(doc.title).base.lowercased()
            return base.hasPrefix(q)
        }
        .sorted { a, b in
            a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    var body: some View {
        NavigationView {
            searchList
                .focused($isSearchFocused)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(.systemGroupedBackground).ignoresSafeArea())
                .overlay {
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
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .onAppear {
                    DispatchQueue.main.async {
                        isSearchPresented = true
                        isSearchFocused = true
                    }
                }
        }
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
                if matches.isEmpty {
                    Text("No matches found.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(matches) { doc in
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
        } else if #available(iOS 16.0, *) {
            baseList
                .searchable(text: $searchText, placement: .automatic, prompt: "Search documents")
        } else {
            baseList
        }
    }

    private var recentsHeader: some View {
        HStack {
            Text("Recents")
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
