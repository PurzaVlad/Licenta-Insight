import SwiftUI
import SSZipArchive
import OSLog

struct ZipExportView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFolderIds: Set<UUID>
    @State private var selectedDocumentIds: Set<UUID>
    private let targetFolderId: UUID?
    @State private var isZipping = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var showingNamePrompt = false
    @State private var zipName = ""
    @State private var editMode: EditMode = .active
    @State private var searchText = ""
    @State private var didAutoPromptName = false
    private let launchedFromSelection: Bool

    init(preselectedDocumentIds: Set<UUID> = [], preselectedFolderIds: Set<UUID> = [], targetFolderId: UUID? = nil) {
        _selectedDocumentIds = State(initialValue: preselectedDocumentIds)
        _selectedFolderIds = State(initialValue: preselectedFolderIds)
        self.targetFolderId = targetFolderId
        self.launchedFromSelection = !preselectedDocumentIds.isEmpty || !preselectedFolderIds.isEmpty
    }

    var body: some View {
        NavigationView {
            Group {
                if launchedFromSelection {
                    Color.clear
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(selection: selectionBinding) {
                        if filteredItems.isEmpty {
                            Text("No documents or folders available.")
                                .foregroundColor(.secondary)
                        } else {
                            ForEach(filteredItems) { item in
                                switch item.kind {
                                case .folder(let folder):
                                    FolderRowView(
                                        folder: folder,
                                        docCount: documentManager.documents(in: folder.id).count,
                                        isSelected: selectedFolderIds.contains(folder.id),
                                        isSelectionMode: true,
                                        usesNativeSelection: true,
                                        onSelectToggle: {},
                                        onOpen: {},
                                        onRename: {},
                                        onMove: {},
                                        onDelete: {},
                                        isDropTargeted: false
                                    )
                                    .tag(ZipSelectionID.folder(folder.id))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                                case .document(let document):
                                    DocumentRowView(
                                        document: document,
                                        isSelected: selectedDocumentIds.contains(document.id),
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
                                    .tag(ZipSelectionID.document(document.id))
                                    .listRowBackground(Color.clear)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
                                }
                            }
                        }
                    }
                    .environment(\.editMode, $editMode)
                    .listStyle(.plain)
                    .hideScrollBackground()
                    .scrollDismissesKeyboardIfAvailable()
                    .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search documents")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .navigationTitle(launchedFromSelection ? "" : "Zip")
            .toolbar(launchedFromSelection ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                if !launchedFromSelection {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") { dismiss() }
                            .foregroundColor(.primary)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(isZipping ? "Zipping..." : "Create") {
                            if zipName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                showingNamePrompt = true
                            } else {
                                createZip(named: zipName)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color("Primary"))
                        .disabled(!canCreateZip)
                    }
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Clear") {
                            selectedFolderIds.removeAll()
                            selectedDocumentIds.removeAll()
                        }
                        .foregroundColor(.primary)
                        .disabled(!canCreateZip)
                    }
                }
            }
        }
        .onAppear {
            guard launchedFromSelection, !didAutoPromptName, canCreateZip else { return }
            didAutoPromptName = true
            showingNamePrompt = true
        }
        .alert("Create Zip", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .alert("ZIP Name", isPresented: $showingNamePrompt) {
            TextField("Archive name", text: $zipName)
            Button("Create") {
                let trimmed = zipName.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    alertMessage = "Please enter a name."
                    showingAlert = true
                } else {
                    createZip(named: trimmed)
                }
            }
            Button("Cancel", role: .cancel) {
                if launchedFromSelection {
                    dismiss()
                }
            }
        } message: {
            Text("Enter a name for the ZIP file.")
        }
    }

    private var canCreateZip: Bool {
        !isZipping && (!selectedFolderIds.isEmpty || !selectedDocumentIds.isEmpty)
    }

    private var selectionBinding: Binding<Set<ZipSelectionID>> {
        Binding(
            get: {
                Set(selectedFolderIds.map { ZipSelectionID.folder($0) })
                    .union(Set(selectedDocumentIds.map { ZipSelectionID.document($0) }))
            },
            set: { newValue in
                selectedFolderIds = Set(newValue.compactMap { id in
                    if case let .folder(folderId) = id { return folderId }
                    return nil
                })
                selectedDocumentIds = Set(newValue.compactMap { id in
                    if case let .document(docId) = id { return docId }
                    return nil
                })
            }
        )
    }

    private var folderRows: [FolderRow] {
        buildFolderRows(parentId: nil, depth: 0)
    }

    private var sortedDocuments: [Document] {
        documentManager.documents.sorted { lhs, rhs in
            splitDisplayTitle(lhs.title).base.localizedCaseInsensitiveCompare(splitDisplayTitle(rhs.title).base) == .orderedAscending
        }
    }

    private var allItems: [ZipItem] {
        let folders: [ZipItem] = folderRows.map { row in
            ZipItem(
                id: ZipSelectionID.folder(row.folder.id),
                kind: .folder(row.folder),
                name: row.folder.name
            )
        }
        let documents: [ZipItem] = sortedDocuments.map { doc in
            ZipItem(
                id: ZipSelectionID.document(doc.id),
                kind: .document(doc),
                name: splitDisplayTitle(doc.title).base
            )
        }
        return (folders + documents).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    private var filteredItems: [ZipItem] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return allItems }
        let needle = trimmed.lowercased()
        return allItems.filter { $0.name.lowercased().contains(needle) }
    }

    private func buildFolderRows(parentId: UUID?, depth: Int) -> [FolderRow] {
        var rows: [FolderRow] = []
        let children = documentManager.folders(in: parentId)
        for folder in children {
            rows.append(FolderRow(folder: folder, depth: depth))
            rows.append(contentsOf: buildFolderRows(parentId: folder.id, depth: depth + 1))
        }
        return rows
    }

    private func folderPathComponents(for folderId: UUID?) -> [String] {
        guard let folderId else { return [] }
        var components: [String] = []
        var currentId: UUID? = folderId
        while let id = currentId,
              let folder = documentManager.folders.first(where: { $0.id == id }) {
            components.append(folder.name)
            currentId = folder.parentId
        }
        return components.reversed()
    }

    private func createZip(named name: String) {
        isZipping = true

        let selectedDocs = selectedDocumentsToZip()
        if selectedDocs.isEmpty {
            isZipping = false
            alertMessage = "No documents found to zip."
            showingAlert = true
            return
        }

        let workItem = DispatchWorkItem {
            let tempDir = FileManager.default.temporaryDirectory
            let stagingURL = tempDir.appendingPathComponent("zip_export_\(UUID().uuidString)", isDirectory: true)
            let safeName = sanitizedFileName(name)
            let fileName = safeName.isEmpty ? "Identity_Archive_\(shortDateString()).zip" : "\(safeName).zip"
            let zipURL = tempDir.appendingPathComponent(fileName)

            do {
                try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)

                for doc in selectedDocs {
                    let relativePath = relativePathForDocument(doc)
                    let fileURL = stagingURL.appendingPathComponent(relativePath)
                    let folderURL = fileURL.deletingLastPathComponent()
                    try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

                    guard let data = dataForDocument(doc) else { continue }
                    try data.write(to: fileURL, options: [.atomic])
                }

                let ok = SSZipArchive.createZipFile(atPath: zipURL.path, withContentsOfDirectory: stagingURL.path)

                let zipData: Data? = {
                    guard ok else { return nil }
                    do { return try Data(contentsOf: zipURL) } catch {
                        AppLogger.sharing.error("Failed to read zip archive data: \(error.localizedDescription)")
                        return nil
                    }
                }()
                if let zipData {
                    let doc = makeZipDocument(title: fileName, data: zipData, folderId: targetFolderId)
                    DispatchQueue.main.async {
                        documentManager.addDocument(doc)
                        isZipping = false
                        let locationText = targetFolderId == nil ? "Documents" : "this folder"
                        alertMessage = "ZIP archive saved to \(locationText)."
                        showingAlert = true
                        dismiss()
                    }
                } else {
                    DispatchQueue.main.async {
                        isZipping = false
                        alertMessage = "Failed to create ZIP archive."
                        showingAlert = true
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isZipping = false
                    alertMessage = "ZIP creation failed: \(error.localizedDescription)"
                    showingAlert = true
                }
            }

            do { try FileManager.default.removeItem(at: stagingURL) } catch { AppLogger.sharing.warning("Failed to remove staging directory: \(error.localizedDescription)") }
            do { try FileManager.default.removeItem(at: zipURL) } catch { AppLogger.sharing.warning("Failed to remove temporary zip file: \(error.localizedDescription)") }
        }

        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func selectedDocumentsToZip() -> [Document] {
        var ids = selectedDocumentIds

        for folderId in selectedFolderIds {
            let descendantIds = documentManager.descendantFolderIds(of: folderId).union([folderId])
            for doc in documentManager.documents {
                if let docFolderId = doc.folderId, descendantIds.contains(docFolderId) {
                    ids.insert(doc.id)
                }
            }
        }

        return documentManager.documents.filter { ids.contains($0.id) }
    }

    private func relativePathForDocument(_ document: Document) -> String {
        let pathComponents = folderPathComponents(for: document.folderId)
        let fileName = fileNameForDocument(document)
        if pathComponents.isEmpty {
            return fileName
        }
        return pathComponents.joined(separator: "/") + "/" + fileName
    }

    private func fileNameForDocument(_ document: Document) -> String {
        let parts = splitDisplayTitle(document.title)
        let base = sanitizedFileName(parts.base.isEmpty ? "Document" : parts.base)
        let ext = parts.ext.isEmpty ? fileExtension(for: document.type) : parts.ext
        return base + "." + ext
    }

    private func sanitizedFileName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    private func dataForDocument(_ document: Document) -> Data? {
        if let data = documentManager.anyFileData(for: document.id) { return data }
        return document.content.data(using: .utf8)
    }
}

private enum ZipSelectionID: Hashable {
    case folder(UUID)
    case document(UUID)
}

private enum ZipItemKind {
    case folder(DocumentFolder)
    case document(Document)
}

private struct ZipItem: Identifiable {
    let id: ZipSelectionID
    let kind: ZipItemKind
    let name: String
}

struct FolderRow: Identifiable {
    let id = UUID()
    let folder: DocumentFolder
    let depth: Int
}

private func makeZipDocument(title: String, data: Data, folderId: UUID?) -> Document {
    Document(
        title: title,
        content: "ZIP archive",
        summary: "ZIP archive",
        dateCreated: Date(),
        folderId: folderId,
        type: .zip,
        imageData: nil,
        pdfData: nil,
        originalFileData: data
    )
}

private func shortDateString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return formatter.string(from: Date())
}
