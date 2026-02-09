import SwiftUI
import SSZipArchive

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

    init(preselectedDocumentIds: Set<UUID> = [], preselectedFolderIds: Set<UUID> = [], targetFolderId: UUID? = nil) {
        _selectedDocumentIds = State(initialValue: preselectedDocumentIds)
        _selectedFolderIds = State(initialValue: preselectedFolderIds)
        self.targetFolderId = targetFolderId
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Folders")) {
                    if folderRows.isEmpty {
                        Text("No folders available.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(folderRows) { row in
                            Button {
                                toggleFolder(row.folder.id)
                            } label: {
                                HStack {
                                    Text(row.folder.name)
                                        .padding(.leading, CGFloat(row.depth) * 12)
                                    Spacer()
                                    if selectedFolderIds.contains(row.folder.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Documents")) {
                    if documentRows.isEmpty {
                        Text("No documents available.")
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(documentRows) { row in
                            Button {
                                toggleDocument(row.document.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(row.document.title)
                                            .lineLimit(1)
                                        if !row.path.isEmpty {
                                            Text(row.path)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedDocumentIds.contains(row.document.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" Zip ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(isZipping ? "Zipping..." : "Create") {
                        if zipName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            showingNamePrompt = true
                        } else {
                            createZip(named: zipName)
                        }
                    }
                    .disabled(!canCreateZip)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
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
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the ZIP file.")
        }
    }

    private var canCreateZip: Bool {
        !isZipping && (!selectedFolderIds.isEmpty || !selectedDocumentIds.isEmpty)
    }

    private var folderRows: [FolderRow] {
        buildFolderRows(parentId: nil, depth: 0)
    }

    private var documentRows: [DocumentRow] {
        documentManager.documents.map { doc in
            let path = folderPathString(for: doc.folderId)
            return DocumentRow(document: doc, path: path)
        }
        .sorted { $0.document.title.localizedCaseInsensitiveCompare($1.document.title) == .orderedAscending }
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

    private func folderPathString(for folderId: UUID?) -> String {
        guard let folderId else { return "" }
        let parts = folderPathComponents(for: folderId)
        return parts.joined(separator: "/")
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

    private func toggleFolder(_ id: UUID) {
        if selectedFolderIds.contains(id) {
            selectedFolderIds.remove(id)
        } else {
            selectedFolderIds.insert(id)
        }
    }

    private func toggleDocument(_ id: UUID) {
        if selectedDocumentIds.contains(id) {
            selectedDocumentIds.remove(id)
        } else {
            selectedDocumentIds.insert(id)
        }
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

                if ok, let zipData = try? Data(contentsOf: zipURL) {
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

            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: zipURL)
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
        if let original = document.originalFileData { return original }
        if let pdf = document.pdfData { return pdf }
        if let img = document.imageData?.first { return img }
        return document.content.data(using: .utf8)
    }
}

struct FolderRow: Identifiable {
    let id = UUID()
    let folder: DocumentFolder
    let depth: Int
}

struct DocumentRow: Identifiable {
    let id = UUID()
    let document: Document
    let path: String
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
