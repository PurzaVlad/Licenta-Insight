import SwiftUI

struct SearchView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void

    @State private var query = ""
    @State private var isOpeningPreview = false
    @State private var isSearchExpanded = false
    @State private var showingSettings = false
    @FocusState private var isSearchFocused: Bool

    private var matches: [Document] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
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
            Group {
                if query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 40, weight: .regular))
                        Text("Search")
                            .font(.title2.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("Find documents, chats, tools, and more.")
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    List {
                        if matches.isEmpty {
                            Text("No matches found.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(matches) { doc in
                                Button {
                                    openDocumentPreview(document: doc)
                                } label: {
                                    HStack {
                                        Image(systemName: iconForDocumentType(doc.type))
                                            .foregroundColor(.blue)
                                        Text(doc.title)
                                            .lineLimit(1)
                                        Spacer()
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .hideScrollBackground()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground))
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
            .navigationTitle("Search")
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
            .safeAreaInset(edge: .bottom) {
                searchBar
            }
            .animation(.easeInOut(duration: 0.2), value: isSearchExpanded)
            .onAppear {
                if !isSearchExpanded {
                    isSearchExpanded = true
                    DispatchQueue.main.async {
                        isSearchFocused = true
                    }
                }
            }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            if isSearchExpanded {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search documents", text: $query)
                        .focused($isSearchFocused)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                    if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color(.systemBackground))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 1)
                        )
                )

                Button("Cancel") {
                    query = ""
                    isSearchExpanded = false
                    isSearchFocused = false
                }
                .foregroundColor(Color("Primary"))
            } else {
                Button {
                    isSearchExpanded = true
                    DispatchQueue.main.async {
                        isSearchFocused = true
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Search")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color(.systemBackground))
                            .overlay(
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(Color(.systemGray4).opacity(0.5), lineWidth: 1)
                            )
                    )
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
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
