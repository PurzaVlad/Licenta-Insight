import SwiftUI
import UIKit
import Foundation
import Vision
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import QuickLook

// No need for TempDocumentManager - using DocumentManager.swift

struct Document: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let title: String
    let content: String
    let summary: String
    let category: DocumentCategory
    let keywordsResume: String
    let dateCreated: Date
    let folderId: UUID?
    let sortOrder: Int
    let type: DocumentType
    let imageData: [Data]?
    let pdfData: Data?
    let originalFileData: Data?

    enum DocumentCategory: String, CaseIterable, Codable {
        case general = "General"
        case resume = "Resume"
        case legal = "Legal"
        case finance = "Finance"
        case medical = "Medical"
        case identity = "Identity"
        case notes = "Notes"
        case receipts = "Receipts"
    }

    enum DocumentType: String, CaseIterable, Codable {
        case pdf
        case docx
        case ppt
        case pptx
        case xls
        case xlsx
        case image
        case scanned
        case text
    }

    init(
        id: UUID = UUID(),
        title: String,
        content: String,
        summary: String,
        category: DocumentCategory = .general,
        keywordsResume: String = "",
        dateCreated: Date = Date(),
        folderId: UUID? = nil,
        sortOrder: Int = 0,
        type: DocumentType,
        imageData: [Data]?,
        pdfData: Data?,
        originalFileData: Data? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.summary = summary
        self.category = category
        self.keywordsResume = keywordsResume
        self.dateCreated = dateCreated
        self.folderId = folderId
        self.sortOrder = sortOrder
        self.type = type
        self.imageData = imageData
        self.pdfData = pdfData
        self.originalFileData = originalFileData
    }
}

struct DocumentFolder: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let name: String
    let dateCreated: Date
    let parentId: UUID?
    let sortOrder: Int

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case dateCreated
        case parentId
        case sortOrder
    }

    init(name: String, parentId: UUID? = nil, sortOrder: Int = 0) {
        self.id = UUID()
        self.name = name
        self.dateCreated = Date()
        self.parentId = parentId
        self.sortOrder = sortOrder
    }

    init(id: UUID, name: String, dateCreated: Date, parentId: UUID? = nil, sortOrder: Int = 0) {
        self.id = id
        self.name = name
        self.dateCreated = dateCreated
        self.parentId = parentId
        self.sortOrder = sortOrder
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.dateCreated = try container.decode(Date.self, forKey: .dateCreated)
        self.parentId = try container.decodeIfPresent(UUID.self, forKey: .parentId)
        self.sortOrder = try container.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
    }
}

private func splitDisplayTitle(_ title: String) -> (base: String, ext: String) {
    let u = URL(fileURLWithPath: title)
    let ext = u.pathExtension
    let base = ext.isEmpty ? title : u.deletingPathExtension().lastPathComponent
    return (base: base, ext: ext)
}

private func fileExtension(for type: Document.DocumentType) -> String {
    switch type {
    case .pdf: return "pdf"
    case .docx: return "docx"
    case .ppt: return "ppt"
    case .pptx: return "pptx"
    case .xls: return "xls"
    case .xlsx: return "xlsx"
    case .image: return "png"
    case .scanned: return "pdf"
    case .text: return "txt"
    }
}

private func fileTypeLabel(documentType: Document.DocumentType, titleParts: (base: String, ext: String)) -> String {
    if !titleParts.ext.isEmpty {
        return titleParts.ext.uppercased()
    }
    switch documentType {
    case .scanned: return "PDF"
    case .image: return "IMG"
    case .text: return "TXT"
    case .pdf: return "PDF"
    case .docx: return "DOCX"
    case .ppt: return "PPT"
    case .pptx: return "PPTX"
    case .xls: return "XLS"
    case .xlsx: return "XLSX"
    }
}

private enum DocumentLayoutMode {
    case list
    case grid
}

struct TabContainerView: View {
    var body: some View {
        TabView {
            DocumentsView()
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("Documents")
                }
            
            NativeChatView()
                .tabItem {
                    Image(systemName: "message")
                    Text("Chat")
                }
        }
    }
}

struct DocumentsView: View {
    @StateObject private var documentManager = DocumentManager()
    @State private var showingDocumentPicker = false
    @State private var showingScanner = false
    @State private var isProcessing = false
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText = ""
    @State private var pendingCategory: Document.DocumentCategory = .general
    @State private var pendingKeywordsResume: String = ""
    @State private var pendingImportedDocument: Document?
    @State private var pendingImportedQueue: [Document] = []
    @State private var showingDocumentPreview = false
    @State private var previewDocumentURL: URL?
    @State private var currentDocument: Document?
    @State private var showingAISummary = false
    @State private var isOpeningPreview = false
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var documentToRename: Document?
    private var layoutMode: DocumentLayoutMode { documentManager.prefersGridLayout ? .grid : .list }

    @State private var showingNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var showingMoveToFolderSheet = false
    @State private var documentToMove: Document?

    @State private var showingRenameFolderDialog = false
    @State private var renameFolderText = ""
    @State private var folderToRename: DocumentFolder?

    @State private var showingMoveFolderSheet = false
    @State private var folderToMove: DocumentFolder?

    @State private var showingDeleteFolderDialog = false
    @State private var folderToDelete: DocumentFolder?

    @State private var draggingDocumentId: UUID?

    private var rootFolders: [DocumentFolder] { documentManager.folders(in: nil) }
    private var rootDocs: [Document] { documentManager.documents(in: nil) }

    @ViewBuilder
    private var emptyStateView: some View {
        VStack(spacing: 20) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 60))
                .foregroundColor(.secondary)

            Text("No Documents Yet")
                .font(.title2)
                .fontWeight(.medium)

            Text("Import documents or scan with OCR to get started")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 12) {
                Button("Scan Document") {
                    showingScanner = true
                }
                .buttonStyle(.borderedProminent)

                Button("Import Files") {
                    showingDocumentPicker = true
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var rootListView: AnyView {
        AnyView(
            List {
                if !rootFolders.isEmpty {
                    Section {
                        ForEach(rootFolders) { folder in
                            FolderRowView(
                                folder: folder,
                                docCount: documentManager.documents(in: folder.id).count,
                                onOpen: { documentManager.activeFolderNavigationId = folder.id },
                                onRename: {
                                    folderToRename = folder
                                    renameFolderText = folder.name
                                    showingRenameFolderDialog = true
                                },
                                onMove: {
                                    folderToMove = folder
                                    showingMoveFolderSheet = true
                                },
                                onDelete: {
                                    folderToDelete = folder
                                    showingDeleteFolderDialog = true
                                }
                            )
                            .background(
                                NavigationLink(
                                    destination: FolderDocumentsView(folder: folder).environmentObject(documentManager),
                                    tag: folder.id,
                                    selection: $documentManager.activeFolderNavigationId
                                ) { EmptyView() }
                                .opacity(0)
                            )
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                handleFolderDrop(providers: providers, folderId: folder.id)
                            }
                        }
                    }
                }

                ForEach(rootDocs, id: \.id) { document in
                    DocumentRowView(
                        document: document,
                        onOpen: { openDocumentPreview(document: document) },
                        onRename: { renameDocument(document) },
                        onMoveToFolder: {
                            documentToMove = document
                            showingMoveToFolderSheet = true
                        },
                        onDelete: { deleteDocument(document) },
                        onConvert: { convertDocument(document) }
                    )
                    .listRowBackground(Color.clear)
                    .onDrag {
                        draggingDocumentId = document.id
                        return NSItemProvider(object: document.id.uuidString as NSString)
                    }
                    .onDrop(of: [UTType.text], delegate: DocumentReorderDropDelegate(
                        targetDocumentId: document.id,
                        folderId: nil,
                        draggingDocumentId: $draggingDocumentId,
                        documentManager: documentManager
                    ))
                }
                .onDelete { offsets in
                    for i in offsets {
                        guard i < rootDocs.count else { continue }
                        documentManager.deleteDocument(rootDocs[i])
                    }
                }
            }
            .listStyle(.plain)
        )
    }

    private var rootGridView: AnyView {
        AnyView(
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    ForEach(rootFolders) { folder in
                        FolderGridItemView(
                            folder: folder,
                            docCount: documentManager.documents(in: folder.id).count,
                            onOpen: { documentManager.activeFolderNavigationId = folder.id },
                            onRename: {
                                folderToRename = folder
                                renameFolderText = folder.name
                                showingRenameFolderDialog = true
                            },
                            onMove: {
                                folderToMove = folder
                                showingMoveFolderSheet = true
                            },
                            onDelete: {
                                folderToDelete = folder
                                showingDeleteFolderDialog = true
                            }
                        )
                        .background(
                            NavigationLink(
                                destination: FolderDocumentsView(folder: folder).environmentObject(documentManager),
                                tag: folder.id,
                                selection: $documentManager.activeFolderNavigationId
                            ) { EmptyView() }
                            .opacity(0)
                        )
                        .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                            handleFolderDrop(providers: providers, folderId: folder.id)
                        }
                    }

                    ForEach(rootDocs, id: \.id) { document in
                        DocumentGridItemView(
                            document: document,
                            onOpen: { openDocumentPreview(document: document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
                                showingMoveToFolderSheet = true
                            },
                            onDelete: { deleteDocument(document) },
                            onConvert: { convertDocument(document) }
                        )
                        .onDrag {
                            draggingDocumentId = document.id
                            return NSItemProvider(object: document.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: DocumentReorderDropDelegate(
                            targetDocumentId: document.id,
                            folderId: nil,
                            draggingDocumentId: $draggingDocumentId,
                            documentManager: documentManager
                        ))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 24)
            }
        )
    }

    @ViewBuilder
    private var rootBrowserView: some View {
        ZStack {
            rootListView
                .opacity(layoutMode == .list ? 1 : 0)
                .allowsHitTesting(layoutMode == .list)

            rootGridView
                .opacity(layoutMode == .grid ? 1 : 0)
                .allowsHitTesting(layoutMode == .grid)

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
    }

    private var processingOverlayView: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(.all)
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Processing document...")
                    .font(.headline)
                    .foregroundColor(.primary)
            }
        }
    }

    @ViewBuilder
    private var documentsMainStack: some View {
        ZStack {
            VStack {
                if documentManager.documents.isEmpty && !isProcessing {
                    emptyStateView
                } else {
                    rootBrowserView
                }
            }

            if isProcessing {
                processingOverlayView
            }
        }
    }
    
    var body: some View {
        NavigationView {
            documentsMainStack
                .navigationTitle("Documents")
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        Button {
                            documentManager.setPrefersGridLayout(false)
                        } label: {
                            Image(systemName: "list.bullet")
                                .font(.system(size: 16, weight: layoutMode == .list ? .semibold : .regular))
                        }
                        .foregroundColor(layoutMode == .list ? .primary : .secondary)

                        Button {
                            documentManager.setPrefersGridLayout(true)
                        } label: {
                            Image(systemName: layoutMode == .grid ? "square.grid.3x3.fill" : "square.grid.3x3")
                                .font(.system(size: 16, weight: layoutMode == .grid ? .semibold : .regular))
                        }
                        .foregroundColor(layoutMode == .grid ? .primary : .secondary)

                        Menu {
                            Button("New Folder") {
                                newFolderName = ""
                                showingNewFolderDialog = true
                            }

                            Button("Scan Document") {
                                showingScanner = true
                            }
                            Button("Import Files") {
                                showingDocumentPicker = true
                            }
                        } label: {
                            Image(systemName: "plus")
                        }
                    }
                }
        }
        .alert("New Folder", isPresented: $showingNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                documentManager.createFolder(name: newFolderName)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the folder")
        }
        .alert("Rename Folder", isPresented: $showingRenameFolderDialog) {
            TextField("Folder name", text: $renameFolderText)
            Button("Rename") {
                guard let folder = folderToRename else { return }
                documentManager.renameFolder(folderId: folder.id, to: renameFolderText)
                folderToRename = nil
            }
            Button("Cancel", role: .cancel) { folderToRename = nil }
        } message: {
            Text("Enter a new name for the folder")
        }
        .confirmationDialog("Delete Folder", isPresented: $showingDeleteFolderDialog, presenting: folderToDelete) { folder in
            Button("Delete all items", role: .destructive) {
                documentManager.deleteFolder(folderId: folder.id, mode: .deleteAllItems)
                folderToDelete = nil
            }

            let parentName = documentManager.folderName(for: folder.parentId) ?? "On My iPhone"
            Button("Move items to \"\(parentName)\"", role: .destructive) {
                documentManager.deleteFolder(folderId: folder.id, mode: .moveItemsToParent)
                folderToDelete = nil
            }

            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: { folder in
            Text("Choose what to do with items inside \"\(folder.name)\".")
        }
        .sheet(isPresented: $showingMoveFolderSheet) {
            if let folder = folderToMove {
                let invalid = documentManager.descendantFolderIds(of: folder.id).union([folder.id])
                MoveFolderSheet(
                    folder: folder,
                    folders: documentManager.folders.filter { !invalid.contains($0.id) },
                    currentParentId: folder.parentId,
                    onSelectParent: { parentId in
                        documentManager.moveFolder(folderId: folder.id, toParent: parentId)
                        folderToMove = nil
                        showingMoveFolderSheet = false
                    },
                    onCancel: {
                        folderToMove = nil
                        showingMoveFolderSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingMoveToFolderSheet) {
            if let doc = documentToMove {
                MoveToFolderSheet(
                    document: doc,
                    folders: documentManager.folders,
                    currentFolderName: documentManager.folderName(for: doc.folderId),
                    onSelectFolder: { folderId in
                        documentManager.moveDocument(documentId: doc.id, toFolder: folderId)
                        documentToMove = nil
                        showingMoveToFolderSheet = false
                    },
                    onCancel: {
                        documentToMove = nil
                        showingMoveToFolderSheet = false
                    }
                )
            }
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in
                processImportedFiles(urls)
            }
        }
        .sheet(isPresented: $showingScanner) {
            if VNDocumentCameraViewController.isSupported {
                DocumentScannerView { scannedImages in
                    self.scannedImages = scannedImages
                    self.prepareNamingDialog(for: scannedImages)
                }
            } else {
                SimpleCameraView { scannedText in
                    processScannedText(scannedText)
                }
            }
        }
        .alert("Name Document", isPresented: $showingNamingDialog) {
            TextField("Document name", text: $customName)
            
            Button("Use Suggested") {
                finalizePendingDocument(with: suggestedName)
            }
            
            Button("Use Custom") {
                finalizePendingDocument(with: customName.isEmpty ? suggestedName : customName)
            }
            
            Button("Cancel", role: .cancel) {
                if pendingImportedDocument != nil {
                    pendingImportedDocument = nil
                    suggestedName = ""
                    customName = ""
                    pendingCategory = .general
                    pendingKeywordsResume = ""
                    if !pendingImportedQueue.isEmpty {
                        startNextImportedNaming()
                    } else {
                        isProcessing = false
                    }
                } else {
                    scannedImages.removeAll()
                    extractedText = ""
                }
            }
        } message: {
            Text("Suggested name: \"\(suggestedName)\"\n\nWould you like to use this name or enter a custom one?")
        }
        .alert("Rename Document", isPresented: $showingRenameDialog) {
            TextField("Document name", text: $renameText)
            
            Button("Rename") {
                guard let document = documentToRename else { return }
                let typed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !typed.isEmpty else { return }

                if let idx = documentManager.documents.firstIndex(where: { $0.id == document.id }) {
                    let old = documentManager.documents[idx]

                    // Preserve the original extension (file type) if the old title had one.
                    let oldParts = splitDisplayTitle(old.title)

                    // Prevent users from changing file type by typing an extension.
                    let typedURL = URL(fileURLWithPath: typed)
                    let typedExt = typedURL.pathExtension.lowercased()
                    let knownExts: Set<String> = ["pdf", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "png", "jpg", "jpeg", "heic"]
                    let sanitizedBase = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : typed

                    let newTitle = oldParts.ext.isEmpty ? sanitizedBase : "\(sanitizedBase).\(oldParts.ext)"

                    let updated = Document(
                        id: old.id,
                        title: newTitle,
                        content: old.content,
                        summary: old.summary,
                        category: old.category,
                        keywordsResume: old.keywordsResume,
                        dateCreated: old.dateCreated,
                        folderId: old.folderId,
                        sortOrder: old.sortOrder,
                        type: old.type,
                        imageData: old.imageData,
                        pdfData: old.pdfData,
                        originalFileData: old.originalFileData
                    )
                    documentManager.documents[idx] = updated

                    // Persist via an existing public save-triggering method.
                    documentManager.updateSummary(for: updated.id, to: updated.summary)
                }

                documentToRename = nil
            }
            
            Button("Cancel", role: .cancel) {
                documentToRename = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for the document")
        }
        .fullScreenCover(isPresented: $showingDocumentPreview, onDismiss: { isOpeningPreview = false }) {
            if let url = previewDocumentURL, let document = currentDocument {
                DocumentPreviewContainerView(url: url, document: document, onAISummary: {
                    showingDocumentPreview = false
                    showingAISummary = true
                })
            }
        }
        .sheet(isPresented: $showingAISummary) {
            if let document = currentDocument {
                DocumentSummaryView(document: document)
                    .environmentObject(documentManager)
            }
        }
    }

    
    
    private func deleteDocuments(offsets: IndexSet) {
        let rootDocs = documentManager.documents(in: nil)
        for index in offsets {
            guard index < rootDocs.count else { continue }
            documentManager.deleteDocument(rootDocs[index])
        }
    }
    
    // Menu actions
    private func renameDocument(_ document: Document) {
        documentToRename = document
        renameText = splitDisplayTitle(document.title).base
        showingRenameDialog = true
    }
    
    private func deleteDocument(_ document: Document) {
        documentManager.deleteDocument(document)
    }
    
    private func convertDocument(_ document: Document) {
        // TODO: Implement document conversion functionality
        print("Convert document: \(document.title)")
    }

    private func handleFolderDrop(providers: [NSItemProvider], folderId: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            let s: String? = {
                if let str = item as? String { return str }
                if let str = item as? NSString { return str as String }
                if let data = item as? Data { return String(data: data, encoding: .utf8) }
                return nil
            }()
            guard let s, let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            DispatchQueue.main.async {
                documentManager.moveDocument(documentId: id, toFolder: folderId)
            }
        }
        return true
    }
    
    private func processImportedFiles(_ urls: [URL]) {
        print("📱 UI: Starting to process \\(urls.count) imported files")
        isProcessing = true
        
        // Process each file synchronously to avoid async issues
        var processedCount = 0
        var docs: [Document] = []
        
        for url in urls {
            print("📱 UI: Processing file: \\(url.lastPathComponent)")
            print("📱 UI: File URL: \\(url.absoluteString)")
            print("📱 UI: File exists: \\(FileManager.default.fileExists(atPath: url.path))")
            
            // Try to access the security scoped resource
            let didStartAccess = url.startAccessingSecurityScopedResource()
            print("📱 UI: Security scoped access: \\(didStartAccess)")
            
            // Even if security access fails, try to process the file
            if let document = documentManager.processFile(at: url) {
                print("📱 UI: ✅ Successfully created document: \\(document.title)")
                print("📱 UI: Document content preview: \\(String(document.content.prefix(100)))...")

                docs.append(document)
                processedCount += 1
            } else {
                print("❌ UI: Failed to create document for: \\(url.lastPathComponent)")
            }
            
            // Stop accessing security scoped resource if we started it
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        print("📱 UI: ✅ Processing complete. Processed \\\(processedCount)/\\\(urls.count) files")

        // Kick off the same naming flow as scanning (name from first 100 chars; keywords from full content).
        DispatchQueue.main.async {
            self.pendingImportedQueue = docs
            self.startNextImportedNaming()
        }
    }

    private func startNextImportedNaming() {
        guard !pendingImportedQueue.isEmpty else {
            isProcessing = false
            return
        }

        let next = pendingImportedQueue.removeFirst()
        pendingImportedDocument = next

        // Background metadata from full extracted text
        let fullTextForKeywords = next.content
        DispatchQueue.global(qos: .utility).async {
            let cat = DocumentManager.inferCategory(title: next.title, content: fullTextForKeywords, summary: next.summary)
            let kw = DocumentManager.makeKeywordsResume(title: next.title, content: fullTextForKeywords, summary: next.summary)
            DispatchQueue.main.async {
                self.pendingCategory = cat
                self.pendingKeywordsResume = kw
            }
        }

        // Name suggestion from only the first 100 chars
        isProcessing = true
        let snippet = String(next.content.prefix(100))
        if snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            suggestedName = next.title
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        } else {
            generateAIDocumentName(from: snippet)
        }
    }

    private func finalizePendingDocument(with name: String) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = finalName.isEmpty ? suggestedName : finalName

        if let imported = pendingImportedDocument {
            let updated = Document(
                id: imported.id,
                title: safeName,
                content: imported.content,
                summary: imported.summary,
                category: pendingCategory,
                keywordsResume: pendingKeywordsResume,
                dateCreated: imported.dateCreated,
                type: imported.type,
                imageData: imported.imageData,
                pdfData: imported.pdfData,
                originalFileData: imported.originalFileData
            )

            documentManager.addDocument(updated)

            pendingImportedDocument = nil
            suggestedName = ""
            customName = ""
            pendingCategory = .general
            pendingKeywordsResume = ""

            if !pendingImportedQueue.isEmpty {
                startNextImportedNaming()
            } else {
                isProcessing = false
            }
            return
        }

        finalizeDocument(with: safeName)
    }
    
    private func processScannedText(_ text: String) {
        isProcessing = true
        
        let document = Document(
            title: "Scanned Document \(documentManager.documents.count + 1)",
            content: text,
            summary: "Processing summary...",
            dateCreated: Date(),
            type: .scanned,
            imageData: nil,
            pdfData: nil
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }
    
    private func prepareNamingDialog(for images: [UIImage]) {
        guard let firstImage = images.first else { return }
        
        isProcessing = true
        
        // Extract text from first image to get content for AI naming
        print("Starting OCR extraction for AI naming...")
        let firstPageText = performOCR(on: firstImage)
        print("First page OCR result: \(firstPageText.prefix(100))...") // Log first 100 chars
        
        // Process all images for full content
        var allText = ""
        for (index, image) in images.enumerated() {
            print("Processing page \(index + 1) for OCR...")
            let pageText = performOCR(on: image)
            allText += "Page \(index + 1):\n\(pageText)\n\n"
            print("Page \(index + 1) OCR completed: \(pageText.count) characters")
        }
        extractedText = allText.trimmingCharacters(in: .whitespacesAndNewlines)
        
        print("Total extracted text: \(extractedText.count) characters")
        
        // In the background, infer category + 50-char keywords from the full OCR.
        // This is stored on the document for fast retrieval later.
        let fullTextForKeywords = extractedText
        DispatchQueue.global(qos: .utility).async {
            let cat = DocumentManager.inferCategory(title: "", content: fullTextForKeywords, summary: "")
            let kw = DocumentManager.makeKeywordsResume(title: "", content: fullTextForKeywords, summary: "")
            DispatchQueue.main.async {
                self.pendingCategory = cat
                self.pendingKeywordsResume = kw
            }
        }

        // Use AI to suggest document name (ONLY first 100 chars from page 1)
        if !firstPageText.isEmpty && firstPageText != "No text found in image" && !firstPageText.contains("OCR failed") {
            print("Using AI to generate document name from OCR text")
            generateAIDocumentName(from: firstPageText)
        } else {
            print("OCR extraction failed or returned no text, using default name")
            // Fallback to default name
            suggestedName = "Scanned Document"
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        }
    }
    
    private func generateAIDocumentName(from text: String) {
        func sanitizeTitle(_ s: String) -> String {
            var name = s
                .replacingOccurrences(of: "\"", with: "")
                .replacingOccurrences(of: "'", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // Replace any non-letter/digit with space to keep readable words
            name = name.replacingOccurrences(of: "[^A-Za-z0-9]+", with: " ", options: .regularExpression)
            // Collapse whitespace and trim
            name = name.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            return name.isEmpty ? "Scanned Document" : name
        }
        func titleCase(_ s: String) -> String {
            return s.split(separator: " ").map { w in
                let lw = w.lowercased()
                return lw.prefix(1).uppercased() + lw.dropFirst()
            }.joined(separator: " ")
        }
        func heuristicName(from text: String) -> String {
            // Extract first few meaningful words
            let stop: Set<String> = ["the","a","an","and","or","of","to","for","in","on","by","with","from","at","as","is","are","was","were","be","been","being"]
            let tokens = text
                .replacingOccurrences(of: "[^A-Za-z0-9 ]+", with: " ", options: .regularExpression)
                .lowercased()
                .split(separator: " ")
                .filter { !$0.isEmpty && $0.count > 2 && !stop.contains(String($0)) }
            let words = Array(tokens.prefix(3))
            if words.isEmpty { return "Scanned Document" }
            return titleCase(words.joined(separator: " "))
        }
        // Prompt: ONLY use the first 100 OCR chars for naming.
        let prompt = """
        <<<NAME_REQUEST>>>Create a short document title using ONLY the provided OCR snippet (do not guess beyond it).
        
        STRICT REQUIREMENTS:
        - Exactly 2-4 words maximum
        - Use Title Case (First Letter Of Each Word Capitalized)
        - Prefer proper nouns in the snippet (clinic/company/person) if present
        - No generic words like "Document", "Text", "File"
        - No file extensions
        
        Examples of good names:
        - "Meeting Notes"
        - "Invoice Receipt"
        - "Lab Report"
        - "Contract Agreement"
        
        OCR Snippet (first 100 chars):
        \(text.prefix(100))
        
        Response format: Just the title, nothing else.
        """
        
        print("🏷️ DocumentsView: Generating AI document name from OCR text")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🏷️ DocumentsView: Got name suggestion result: \(String(describing: result))")
            DispatchQueue.main.async {
                if let result = result as? String, !result.isEmpty {
                    // Clean up the AI response, keep up to 3 words, then sanitize for filesystem
                    let cleanResult = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let words = cleanResult.components(separatedBy: .whitespacesAndNewlines)
                        .filter { !$0.isEmpty }
                        .prefix(3)
                    let joined = words.joined(separator: " ")
                    let friendly = titleCase(sanitizeTitle(joined))
                    self.suggestedName = friendly.isEmpty ? heuristicName(from: text) : friendly
                } else {
                    print("❌ DocumentsView: Empty or nil name suggestion result")
                    self.suggestedName = heuristicName(from: text)
                }
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentsView: Name generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.suggestedName = heuristicName(from: text)
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        })
    }
    
    private func finalizeDocument(with name: String) {
        guard !scannedImages.isEmpty else { return }
        
        isProcessing = true
        
        var imageDataArray: [Data] = []
        for image in scannedImages {
            if let imageData = image.jpegData(compressionQuality: 0.95) {
                imageDataArray.append(imageData)
            }
        }
        
        // Generate PDF from images
        let pdfData = createPDF(from: scannedImages)
        
        let document = Document(
            title: name,
            content: extractedText,
            summary: "Processing summary...",
            category: pendingCategory,
            keywordsResume: pendingKeywordsResume,
            dateCreated: Date(),
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            documentManager.addDocument(document)
            isProcessing = false
            
            // Clear temporary data
            scannedImages.removeAll()
            extractedText = ""
            suggestedName = ""
            customName = ""
            pendingCategory = .general
            pendingKeywordsResume = ""
        }
    }
    
    private func processScannedImages(_ images: [UIImage]) {
        isProcessing = true
        
        var allText = ""
        var imageDataArray: [Data] = []
        
        for (index, image) in images.enumerated() {
            let text = performOCR(on: image)
            allText += "Page \(index + 1):\n\(text)\n\n"
            
            // Save image data with high quality
            if let imageData = image.jpegData(compressionQuality: 0.95) {
                imageDataArray.append(imageData)
            }
        }
        
        // Generate PDF from images
        let pdfData = createPDF(from: images)
        
        let document = Document(
            title: "Scanned Document \(documentManager.documents.count + 1)",
            content: allText.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: "Processing summary...",
            dateCreated: Date(),
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }
    
    private func createPDF(from images: [UIImage]) -> Data? {
        let pdfData = NSMutableData()
        
        guard let dataConsumer = CGDataConsumer(data: pdfData) else { return nil }
        
        // Use standard US Letter page size (8.5 x 11 inches at 72 DPI)
        let pageWidth: CGFloat = 612  // 8.5 * 72
        let pageHeight: CGFloat = 792  // 11 * 72
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var mediaBox = pageRect
        
        guard let pdfContext = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) else { return nil }
        
        for image in images {
            pdfContext.beginPDFPage(nil)
            
            if let cgImage = image.cgImage {
                // Calculate scaling to fit image within page while maintaining aspect ratio
                let imageSize = image.size
                let imageAspectRatio = imageSize.width / imageSize.height
                let pageAspectRatio = pageWidth / pageHeight
                
                var drawRect: CGRect
                
                if imageAspectRatio > pageAspectRatio {
                    // Image is wider - fit to page width
                    let scaledHeight = pageWidth / imageAspectRatio
                    let yOffset = (pageHeight - scaledHeight) / 2
                    drawRect = CGRect(x: 0, y: yOffset, width: pageWidth, height: scaledHeight)
                } else {
                    // Image is taller - fit to page height
                    let scaledWidth = pageHeight * imageAspectRatio
                    let xOffset = (pageWidth - scaledWidth) / 2
                    drawRect = CGRect(x: xOffset, y: 0, width: scaledWidth, height: pageHeight)
                }
                
                pdfContext.draw(cgImage, in: drawRect)
            }
            
            pdfContext.endPDFPage()
        }
        
        pdfContext.closePDF()
        return pdfData as Data
    }
    
    private func performOCR(on image: UIImage) -> String {
        // Ensure image is properly oriented and processed
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            print("OCR: Failed to process image")
            return "Could not process image"
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        
        // Set supported languages (add more if needed)
        request.recognitionLanguages = ["en-US"]
        
        var recognizedText = ""
        let semaphore = DispatchSemaphore(value: 0)
        
        do {
            try requestHandler.perform([request])
            
            if let results = request.results {
                // Get all text observations and sort by position
                let textObservations = results.compactMap { observation -> (String, CGRect)? in
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    return (topCandidate.string, observation.boundingBox)
                }
                
                // Sort by Y position (top to bottom) then X position (left to right)
                let sortedObservations = textObservations.sorted { first, second in
                    let yDiff = abs(first.1.minY - second.1.minY)
                    if yDiff < 0.02 { // Same line threshold
                        return first.1.minX < second.1.minX
                    }
                    return first.1.minY > second.1.minY // Flip Y because Vision uses bottom-left origin
                }
                
                recognizedText = sortedObservations.map { $0.0 }.joined(separator: " ")
                
                // Clean up the text
                recognizedText = recognizedText
                    .replacingOccurrences(of: "\n\n+", with: "\n", options: .regularExpression)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    
                print("OCR: Successfully extracted \(recognizedText.count) characters")
            } else {
                print("OCR: No results returned")
            }
        } catch {
            print("OCR Error: \(error.localizedDescription)")
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }
        
        return recognizedText.isEmpty ? "No text found in image" : recognizedText
    }
    
    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        // Ensure proper orientation and size for OCR
        guard let cgImage = image.cgImage else { return nil }
        
        let targetSize: CGFloat = 2048 // Good balance between quality and performance
        let imageSize = image.size
        let maxDimension = max(imageSize.width, imageSize.height)
        
        // Only resize if image is too large
        if maxDimension > targetSize {
            let scale = targetSize / maxDimension
            let newSize = CGSize(
                width: imageSize.width * scale,
                height: imageSize.height * scale
            )
            
            UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
            image.draw(in: CGRect(origin: .zero, size: newSize))
            let resizedImage = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()
            
            return resizedImage
        }
        
        return image
    }
    
    private func openDocumentPreview(document: Document) {
        isOpeningPreview = true
        let tempDirectory = FileManager.default.temporaryDirectory
        let fileExt = getFileExtension(for: document.type)
        let tempURL = tempDirectory.appendingPathComponent("preview_\(document.id).\(fileExt)")
        
        func present(url: URL) {
            self.previewDocumentURL = url
            self.currentDocument = document
            self.showingDocumentPreview = true
        }
        
        // Prefer original file, then PDF, then first image fallback
        if let data = document.originalFileData ?? document.pdfData ?? document.imageData?.first {
            do {
                try data.write(to: tempURL)
                present(url: tempURL)
            } catch {
                print("Error creating temp file: \(error)")
                isOpeningPreview = false
            }
        } else {
            // Fallback: show content in a simple text preview via summary sheet
            self.currentDocument = document
            self.showingAISummary = true
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
        case .scanned:
            return "pdf"
        case .image:
            return "jpg"
        }
    }
}

struct DocumentReorderDropDelegate: DropDelegate {
    let targetDocumentId: UUID
    let folderId: UUID?
    @Binding var draggingDocumentId: UUID?
    let documentManager: DocumentManager

    func dropEntered(info: DropInfo) {
        guard let dragged = draggingDocumentId else { return }
        if dragged != targetDocumentId {
            documentManager.reorderDocuments(in: folderId, draggedId: dragged, targetId: targetDocumentId)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingDocumentId = nil
        return true
    }
}

struct DocumentRowView: View {
    let document: Document
    @State private var isGeneratingSummary = false

    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void
    
    var body: some View {
        let parts = splitDisplayTitle(document.title)

        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: iconForDocumentType(document.type))
                        .foregroundColor(.blue)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(parts.base)
                            .font(.headline)
                            .lineLimit(2)
                        Text("\(DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .none)) • \(fileTypeLabel(documentType: document.type, titleParts: parts))")
                            .font(.caption)
                            .foregroundColor(Color(.tertiaryLabel))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 34)
            }
            .buttonStyle(PlainButtonStyle())

            Menu {
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                Button(action: onMoveToFolder) { Label("Move to folder", systemImage: "folder") }
                Button(action: onConvert) { Label("Convert", systemImage: "arrow.2.circlepath") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
    }
    
    private func generateAISummary() {
        print("🧠 DocumentRowView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
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
                        rootViewController.present(alert, animated: true)
                    }
                } else {
                    print("🧠 DocumentRowView: Invalid or empty summary result")
                }
            }
        }, rejecter: { code, message, error in
            print("🧠 DocumentRowView: Summary generation failed - Code: \(String(describing: code)), Message: \(String(describing: message)), Error: \(String(describing: error))")
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
}

struct DocumentGridItemView: View {
    let document: Document
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void

    var body: some View {
        let parts = splitDisplayTitle(document.title)

        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.clear)

                        Group {
                            if let pdfData = document.pdfData {
                                PDFThumbnailView(data: pdfData)
                            } else if let imageDataArray = document.imageData,
                                      !imageDataArray.isEmpty,
                                      let firstImageData = imageDataArray.first,
                                      let uiImage = UIImage(data: firstImageData) {
                                Image(uiImage: uiImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fill)
                            } else {
                                Image(systemName: iconForDocumentType(document.type))
                                    .font(.system(size: 34))
                                    .foregroundColor(.blue)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    }
                    .aspectRatio(0.75, contentMode: .fit)
                    .cornerRadius(10)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(parts.base)
                            .font(.subheadline)
                            .foregroundColor(.primary)
                            .lineLimit(1)
                        Text("\(fileTypeLabel(documentType: document.type, titleParts: parts))")
                            .font(.caption2)
                            .foregroundColor(Color(.tertiaryLabel))
                            .lineLimit(1)
                    }
                    .padding(.trailing, 18)
                }
            }
            .buttonStyle(PlainButtonStyle())

            Menu {
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                Button(action: onMoveToFolder) { Label("Move to folder", systemImage: "folder") }
                Button(action: onConvert) { Label("Convert", systemImage: "arrow.2.circlepath") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 4)
            .padding(.trailing, 0)
        }
    }
}

struct FolderRowView: View {
    let folder: DocumentFolder
    let docCount: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(systemName: "folder")
                        .foregroundColor(.blue)
                        .frame(width: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(folder.name)
                            .font(.headline)
                        Text("\(docCount) item\(docCount == 1 ? "" : "s")")
                            .font(.caption)
                            .foregroundColor(Color(.tertiaryLabel))
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 34)
            }
            .buttonStyle(PlainButtonStyle())

            Menu {
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                Button(action: onMove) { Label("Move to folder", systemImage: "folder") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 28, height: 28)
                    .foregroundColor(.secondary)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
    }
}

struct FolderGridItemView: View {
    let folder: DocumentFolder
    let docCount: Int
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.clear)
                        Image(systemName: "folder.fill")
                            .font(.system(size: 34))
                            .foregroundColor(.blue)
                    }
                    .aspectRatio(0.75, contentMode: .fit)
                    .cornerRadius(10)

                    Text(folder.name)
                        .font(.subheadline)
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    Text("\(docCount) item\(docCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .foregroundColor(Color(.tertiaryLabel))
                }
                .padding(.trailing, 18)
            }
            .buttonStyle(PlainButtonStyle())

            Menu {
                Button(action: onRename) { Label("Rename", systemImage: "pencil") }
                Button(action: onMove) { Label("Move to folder", systemImage: "folder") }
                Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 24, height: 24)
                    .foregroundColor(.secondary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PlainButtonStyle())
            .padding(.top, 4)
        }
    }
}

struct FolderDocumentsView: View {
    let folder: DocumentFolder
    @EnvironmentObject private var documentManager: DocumentManager
    private var layoutMode: DocumentLayoutMode { documentManager.prefersGridLayout ? .grid : .list }
    @State private var showingMoveToFolderSheet = false
    @State private var documentToMove: Document?

    @State private var activeSubfolderId: UUID?

    @State private var showingRenameFolderDialog = false
    @State private var renameFolderText = ""
    @State private var folderToRename: DocumentFolder?

    @State private var showingMoveFolderSheet = false
    @State private var folderToMove: DocumentFolder?

    @State private var showingDeleteFolderDialog = false
    @State private var folderToDelete: DocumentFolder?

    @State private var showingDocumentPreview = false
    @State private var previewDocumentURL: URL?
    @State private var currentDocument: Document?
    @State private var isOpeningPreview = false

    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var documentToRename: Document?

    @State private var draggingDocumentId: UUID?

    var body: some View {
        let docs = documentManager.documents(in: folder.id)
        let subfolders = documentManager.folders(in: folder.id)

        Group {
            if layoutMode == .list {
                List {
                    if !subfolders.isEmpty {
                        Section {
                            ForEach(subfolders) { sub in
                                FolderRowView(
                                    folder: sub,
                                    docCount: documentManager.documents(in: sub.id).count,
                                    onOpen: { activeSubfolderId = sub.id },
                                    onRename: {
                                        folderToRename = sub
                                        renameFolderText = sub.name
                                        showingRenameFolderDialog = true
                                    },
                                    onMove: {
                                        folderToMove = sub
                                        showingMoveFolderSheet = true
                                    },
                                    onDelete: {
                                        folderToDelete = sub
                                        showingDeleteFolderDialog = true
                                    }
                                )
                                .background(
                                    NavigationLink(
                                        destination: FolderDocumentsView(folder: sub).environmentObject(documentManager),
                                        tag: sub.id,
                                        selection: $activeSubfolderId
                                    ) { EmptyView() }
                                    .opacity(0)
                                )
                                .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                    handleFolderDrop(providers: providers, folderId: sub.id)
                                }
                            }
                        }
                    }

                    ForEach(docs, id: \ .id) { document in
                        DocumentRowView(
                            document: document,
                            onOpen: { openDocumentPreview(document: document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
                                showingMoveToFolderSheet = true
                            },
                            onDelete: { documentManager.deleteDocument(document) },
                            onConvert: { }
                        )
                        .listRowBackground(Color.clear)
                        .onDrag {
                            draggingDocumentId = document.id
                            return NSItemProvider(object: document.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: DocumentReorderDropDelegate(
                            targetDocumentId: document.id,
                            folderId: folder.id,
                            draggingDocumentId: $draggingDocumentId,
                            documentManager: documentManager
                        ))
                    }
                }
                .listStyle(.plain)
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        ForEach(subfolders) { sub in
                            FolderGridItemView(
                                folder: sub,
                                docCount: documentManager.documents(in: sub.id).count,
                                onOpen: { activeSubfolderId = sub.id },
                                onRename: {
                                    folderToRename = sub
                                    renameFolderText = sub.name
                                    showingRenameFolderDialog = true
                                },
                                onMove: {
                                    folderToMove = sub
                                    showingMoveFolderSheet = true
                                },
                                onDelete: {
                                    folderToDelete = sub
                                    showingDeleteFolderDialog = true
                                }
                            )
                            .background(
                                NavigationLink(
                                    destination: FolderDocumentsView(folder: sub).environmentObject(documentManager),
                                    tag: sub.id,
                                    selection: $activeSubfolderId
                                ) { EmptyView() }
                                .opacity(0)
                            )
                            .onDrop(of: [UTType.text], isTargeted: nil) { providers in
                                handleFolderDrop(providers: providers, folderId: sub.id)
                            }
                        }

                        ForEach(docs, id: \ .id) { document in
                            DocumentGridItemView(
                                document: document,
                                onOpen: { openDocumentPreview(document: document) },
                                onRename: { renameDocument(document) },
                                onMoveToFolder: {
                                    documentToMove = document
                                    showingMoveToFolderSheet = true
                                },
                                onDelete: { documentManager.deleteDocument(document) },
                                onConvert: { }
                            )
                            .onDrag {
                                draggingDocumentId = document.id
                                return NSItemProvider(object: document.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: DocumentReorderDropDelegate(
                                targetDocumentId: document.id,
                                folderId: folder.id,
                                draggingDocumentId: $draggingDocumentId,
                                documentManager: documentManager
                            ))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                Button {
                    documentManager.setPrefersGridLayout(false)
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 16, weight: layoutMode == .list ? .semibold : .regular))
                }
                .foregroundColor(layoutMode == .list ? .primary : .secondary)

                Button {
                    documentManager.setPrefersGridLayout(true)
                } label: {
                    Image(systemName: layoutMode == .grid ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .font(.system(size: 16, weight: layoutMode == .grid ? .semibold : .regular))
                }
                .foregroundColor(layoutMode == .grid ? .primary : .secondary)
            }
        }
        .sheet(isPresented: $showingMoveToFolderSheet) {
            if let doc = documentToMove {
                MoveToFolderSheet(
                    document: doc,
                    folders: documentManager.folders,
                    currentFolderName: documentManager.folderName(for: doc.folderId),
                    onSelectFolder: { folderId in
                        documentManager.moveDocument(documentId: doc.id, toFolder: folderId)
                        documentToMove = nil
                        showingMoveToFolderSheet = false
                    },
                    onCancel: {
                        documentToMove = nil
                        showingMoveToFolderSheet = false
                    }
                )
            }
        }
        .alert("Rename Document", isPresented: $showingRenameDialog) {
            TextField("Document name", text: $renameText)
            Button("Rename") {
                guard let document = documentToRename else { return }
                let typed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !typed.isEmpty else { return }

                if let idx = documentManager.documents.firstIndex(where: { $0.id == document.id }) {
                    let old = documentManager.documents[idx]
                    let oldParts = splitDisplayTitle(old.title)

                    let typedURL = URL(fileURLWithPath: typed)
                    let typedExt = typedURL.pathExtension.lowercased()
                    let knownExts: Set<String> = ["pdf", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "png", "jpg", "jpeg", "heic"]
                    let sanitizedBase = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : typed
                    let newTitle = oldParts.ext.isEmpty ? sanitizedBase : "\(sanitizedBase).\(oldParts.ext)"

                    documentManager.documents[idx] = Document(
                        id: old.id,
                        title: newTitle,
                        content: old.content,
                        summary: old.summary,
                        category: old.category,
                        keywordsResume: old.keywordsResume,
                        dateCreated: old.dateCreated,
                        folderId: old.folderId,
                        sortOrder: old.sortOrder,
                        type: old.type,
                        imageData: old.imageData,
                        pdfData: old.pdfData,
                        originalFileData: old.originalFileData
                    )

                    // Trigger persistence
                    documentManager.updateSummary(for: old.id, to: old.summary)
                }

                documentToRename = nil
            }
            Button("Cancel", role: .cancel) {
                documentToRename = nil
                renameText = ""
            }
        } message: {
            Text("Enter a new name for the document")
        }
        .alert("Rename Folder", isPresented: $showingRenameFolderDialog) {
            TextField("Folder name", text: $renameFolderText)
            Button("Rename") {
                guard let folder = folderToRename else { return }
                documentManager.renameFolder(folderId: folder.id, to: renameFolderText)
                folderToRename = nil
            }
            Button("Cancel", role: .cancel) { folderToRename = nil }
        } message: {
            Text("Enter a new name for the folder")
        }
        .confirmationDialog("Delete Folder", isPresented: $showingDeleteFolderDialog, presenting: folderToDelete) { folder in
            Button("Delete all items", role: .destructive) {
                documentManager.deleteFolder(folderId: folder.id, mode: .deleteAllItems)
                folderToDelete = nil
            }

            let parentName = documentManager.folderName(for: folder.parentId) ?? "On My iPhone"
            Button("Move items to \"\(parentName)\"", role: .destructive) {
                documentManager.deleteFolder(folderId: folder.id, mode: .moveItemsToParent)
                folderToDelete = nil
            }

            Button("Cancel", role: .cancel) { folderToDelete = nil }
        } message: { folder in
            Text("Choose what to do with items inside \"\(folder.name)\".")
        }
        .sheet(isPresented: $showingMoveFolderSheet) {
            if let folder = folderToMove {
                let invalid = documentManager.descendantFolderIds(of: folder.id).union([folder.id])
                MoveFolderSheet(
                    folder: folder,
                    folders: documentManager.folders.filter { !invalid.contains($0.id) },
                    currentParentId: folder.parentId,
                    onSelectParent: { parentId in
                        documentManager.moveFolder(folderId: folder.id, toParent: parentId)
                        folderToMove = nil
                        showingMoveFolderSheet = false
                    },
                    onCancel: {
                        folderToMove = nil
                        showingMoveFolderSheet = false
                    }
                )
            }
        }
        .fullScreenCover(isPresented: $showingDocumentPreview, onDismiss: { isOpeningPreview = false }) {
            if let url = previewDocumentURL, let document = currentDocument {
                DocumentPreviewContainerView(url: url, document: document, onAISummary: nil)
            }
        }
    }

    private func handleFolderDrop(providers: [NSItemProvider], folderId: UUID) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { item, _ in
            let s: String? = {
                if let str = item as? String { return str }
                if let str = item as? NSString { return str as String }
                if let data = item as? Data { return String(data: data, encoding: .utf8) }
                return nil
            }()
            guard let s, let id = UUID(uuidString: s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            DispatchQueue.main.async {
                documentManager.moveDocument(documentId: id, toFolder: folderId)
            }
        }
        return true
    }

    private func renameDocument(_ document: Document) {
        documentToRename = document
        renameText = splitDisplayTitle(document.title).base
        showingRenameDialog = true
    }

    private func openDocumentPreview(document: Document) {
        isOpeningPreview = true
        currentDocument = document
        // The root view builds a temporary URL; replicate minimal logic here by reusing existing helper.
        if let url = buildPreviewURL(for: document) {
            previewDocumentURL = url
            showingDocumentPreview = true
        }
        isOpeningPreview = false
    }

    private func buildPreviewURL(for document: Document) -> URL? {
        // Prefer an in-memory original file when available.
        let tempDir = FileManager.default.temporaryDirectory
        let baseName = "doc_\(document.id.uuidString)"
        let extFromTitle = splitDisplayTitle(document.title).ext
        let ext = !extFromTitle.isEmpty ? extFromTitle : fileExtension(for: document.type)
        let url = tempDir.appendingPathComponent(baseName).appendingPathExtension(ext)

        if let data = document.originalFileData {
            try? data.write(to: url, options: [.atomic])
            return url
        }
        if let pdf = document.pdfData {
            try? pdf.write(to: url, options: [.atomic])
            return url
        }
        if let imgs = document.imageData, let first = imgs.first {
            try? first.write(to: url, options: [.atomic])
            return url
        }
        return nil
    }
}

struct MoveToFolderSheet: View {
    let document: Document
    let folders: [DocumentFolder]
    let currentFolderName: String?
    let onSelectFolder: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                Button {
                    onSelectFolder(nil)
                } label: {
                    HStack {
                        Text("On My iPhone")
                        Spacer()
                        if currentFolderName == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }

                ForEach(folders) { folder in
                    Button {
                        onSelectFolder(folder.id)
                    } label: {
                        HStack {
                            Text(folder.name)
                            Spacer()
                            if currentFolderName == folder.name {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

struct MoveFolderSheet: View {
    let folder: DocumentFolder
    let folders: [DocumentFolder]
    let currentParentId: UUID?
    let onSelectParent: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                Button {
                    onSelectParent(nil)
                } label: {
                    HStack {
                        Text("On My iPhone")
                        Spacer()
                        if currentParentId == nil {
                            Image(systemName: "checkmark")
                                .foregroundColor(.blue)
                        }
                    }
                }

                ForEach(folders.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { dest in
                    Button {
                        onSelectParent(dest.id)
                    } label: {
                        HStack {
                            Text(dest.name)
                            Spacer()
                            if currentParentId == dest.id {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Move")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
    }
}

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
                        HStack {
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
                    HStack {
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
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
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
        }
    }
}

// MARK: - Helper Functions
private func iconForDocumentType(_ type: Document.DocumentType) -> String {
    switch type {
    case .pdf:
        return "doc.richtext"
    case .docx:
        return "doc.text"
    case .ppt, .pptx:
        return "play.rectangle.on.rectangle"
    case .xls, .xlsx:
        return "tablecells"
    case .image:
        return "photo"
    case .scanned:
        return "doc.viewfinder"
    case .text:
        return "doc.plaintext"
    }
}

struct PDFThumbnailView: UIViewRepresentable {
    let data: Data
    
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        
        // Generate thumbnail from PDF
        if let document = PDFDocument(data: data),
           let firstPage = document.page(at: 0) {
            let pageRect = firstPage.bounds(for: .mediaBox)
            let thumbnail = firstPage.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
            imageView.image = thumbnail
        }
        
        return imageView
    }
    
    func updateUIView(_ uiView: UIImageView, context: Context) {
        // Update if needed
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
                    
                    Button("Generate AI Summary") {
                        generateAISummary()
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
            // AI Summary Button
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
            .padding()
            .disabled(isGeneratingSummary)
        }
    }
    
    private func generateAISummary() {
        print("🧠 OldDocumentPreviewView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        let prompt = "<<<SUMMARY_REQUEST>>>Please provide a comprehensive summary of this document. Focus on the main topics, key points, and important details:\n\n\(document.content)"
        
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

struct DocumentPicker: UIViewControllerRepresentable {
    let completion: ([URL]) -> Void
    
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [
            .pdf, .rtf, .plainText, .image, .jpeg, .png, .heic,
            UTType("com.microsoft.word.doc")!,
            UTType("org.openxmlformats.wordprocessingml.document")!,
            UTType("com.microsoft.powerpoint.ppt")!,
            UTType("org.openxmlformats.presentationml.presentation")!,
            UTType("com.microsoft.excel.xls")!,
            UTType("org.openxmlformats.spreadsheetml.sheet")!,
            .spreadsheet,
            .json,
            .xml
        ], asCopy: true)
        
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker
        
        init(_ parent: DocumentPicker) {
            self.parent = parent
        }
        
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            parent.completion(urls)
        }
    }
}

struct DocumentScannerView: UIViewControllerRepresentable {
    let completion: ([UIImage]) -> Void
    
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }
    
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScannerView
        
        init(_ parent: DocumentScannerView) {
            self.parent = parent
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            var scannedImages: [UIImage] = []
            
            for pageIndex in 0..<scan.pageCount {
                // Get the processed, cropped image from the scanner
                let image = scan.imageOfPage(at: pageIndex)
                scannedImages.append(image)
            }
            
            parent.completion(scannedImages)
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            controller.dismiss(animated: true)
        }
        
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            print("Document scanning failed: \(error.localizedDescription)")
            controller.dismiss(animated: true)
        }
    }
}

struct SimpleCameraView: UIViewControllerRepresentable {
    let completion: (String) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        
        // Check if camera is available
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            // Fallback to photo library if camera not available (simulator)
            picker.sourceType = .photoLibrary
        }
        
        picker.allowsEditing = false
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: SimpleCameraView
        
        init(_ parent: SimpleCameraView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                let recognizedText = performOCR(on: image)
                parent.completion(recognizedText)
            }
            picker.dismiss(animated: true)
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true)
        }
        
        private func performOCR(on image: UIImage) -> String {
            guard let cgImage = image.cgImage else {
                return "Could not process image"
            }
            
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            
            var recognizedText = ""
            
            do {
                try requestHandler.perform([request])
                if let results = request.results {
                    recognizedText = results.compactMap { result in
                        result.topCandidates(1).first?.string
                    }.joined(separator: "\n")
                }
            } catch {
                recognizedText = "OCR failed: \(error.localizedDescription)"
            }
            
            return recognizedText.isEmpty ? "No text found in image" : recognizedText
        }
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: String // "user" or "assistant"
    let text: String
    let date: Date
}

struct NativeChatView: View {
        @State private var activeDocsForChat: [Document] = []
        @State private var lastDocScopedQuestion: String = ""
    @State private var input: String = ""
    @State private var messages: [ChatMessage] = []
    @State private var isGenerating: Bool = false
    @State private var isThinkingPulseOn: Bool = false
    @State private var pendingDocConfirmation: PendingDocConfirmation? = nil
    @FocusState private var isFocused: Bool
    @StateObject private var documentManager = DocumentManager()

    private struct PendingDocConfirmation {
        let question: String
        let candidates: [Document]
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 12) {
                            if messages.isEmpty {
                                Text("Model Ready.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity)
                                    .padding(.top, 24)
                            }

                            ForEach(messages) { msg in
                                MessageRow(msg: msg)
                                    .id(msg.id)
                            }

                            if isGenerating {
                                ThinkingRow(isPulseOn: $isThinkingPulseOn)
                                    .id("thinking")
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    .onChange(of: messages) { newValue in
                        if let last = newValue.last {
                            withAnimation(.easeOut(duration: 0.2)) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }

                Divider()

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        HStack(spacing: 8) {
                            TextField("Message", text: $input)
                                .focused($isFocused)
                                .disabled(isGenerating)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                        }
                        .background(Color(.tertiarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .stroke(Color(.separator), lineWidth: 0.33)
                        )

                        Button {
                            send()
                        } label: {
                            Image(systemName: isGenerating ? "stop.circle.fill" : "arrow.up.circle.fill")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating ? .secondary : .white)
                                .background(
                                    Circle()
                                        .fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating ? Color(.systemFill) : Color.accentColor)
                                )
                        }
                        .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
            }
            .navigationTitle("VaultAI")
            .navigationBarTitleDisplayMode(.large)
        }
    }

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        print("💬 NativeChatView: Sending message: '\(trimmed)'")
        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        // If we previously asked the user to confirm a document, only treat this message as the
        // selection when it matches a selection pattern (number/name/all/cancel). Otherwise allow
        // the user to keep chatting and answer later.
        if let pending = pendingDocConfirmation {
            if tryConsumeDocConfirmationReply(trimmed, pending: pending) {
                return
            }
        }

        // Allow basic/small-talk chat without forcing document selection.
        if isSmallTalk(trimmed) {
            runLLMAnswer(question: trimmed, docsToSearch: [])
            return
        }

        // Step 1: retrieve relevant docs and ask for confirmation only if needed.
        // Only proceed to the model once we know which document(s) to search.
        if documentManager.documents.isEmpty {
            print("💬 NativeChatView: No documents available for context")
            pendingDocConfirmation = nil
            // Fall back to sending question as-is.
            runLLMAnswer(question: trimmed, docsToSearch: [])
            return
        }

        // If this doesn't look like a document question, treat it as normal chat.
        if !isDocumentQuery(trimmed) {
            runLLMAnswer(question: trimmed, docsToSearch: [])
            return
        }

        // If the user is asking a follow-up and we already have an active document scope,
        // keep using the same document(s) unless they explicitly mention a different one.
        if !activeDocsForChat.isEmpty,
           !mentionsExplicitDifferentDocument(trimmed),
           looksLikeFollowUpQuestion(trimmed) {
            print("💬 NativeChatView: Using active document scope for follow-up")
            lastDocScopedQuestion = trimmed
            runLLMAnswer(question: trimmed, docsToSearch: activeDocsForChat)
            return
        }

        // Stage A (fast): metadata-only ranking (keywordsResume + category + title)
        let rankedMeta = selectRelevantDocumentsByMetadata(for: trimmed, maxDocs: 5)
        var ranked = rankedMeta
        var candidates = ranked.map { $0.doc }

        // If metadata is inconclusive, Stage B: include summaries + first ~200 chars of OCR/content.
        let metaTop = ranked.first?.score ?? 0
        let metaSecond = ranked.dropFirst().first?.score ?? 0
        let metaConfident = candidates.count == 1 || (metaTop >= 10 && metaTop >= (metaSecond + 4))
        if !metaConfident {
            let rankedFull = selectRelevantDocumentsWithScores(for: trimmed, maxDocs: 5)
            if !rankedFull.isEmpty {
                ranked = rankedFull
                candidates = ranked.map { $0.doc }
            }
        }

        if candidates.isEmpty {
            messages.append(ChatMessage(
                role: "assistant",
                text: "I couldn't find a relevant document based on your question. Is this supposed to be part of a specific document? If yes, tell me the document name (or paste a unique phrase).",
                date: Date()
            ))
            pendingDocConfirmation = PendingDocConfirmation(question: trimmed, candidates: [])
            isGenerating = false
            return
        }

        // First, try to auto-pick using local snippet evidence (fast and reliable, no LLM).
        if let evidencePick = pickDocumentBySnippetEvidence(question: trimmed, docs: candidates) {
            print("💬 NativeChatView: Auto-selected by snippet evidence: \(evidencePick.title)")
            activeDocsForChat = [evidencePick]
            lastDocScopedQuestion = trimmed
            runLLMAnswer(question: trimmed, docsToSearch: [evidencePick])
            return
        }

        // Otherwise, auto-pick when the top match is clearly better; else ask.
        let topScore = ranked.first?.score ?? 0
        let secondScore = ranked.dropFirst().first?.score ?? 0
        let confident = candidates.count == 1 || (topScore >= 8 && topScore >= (secondScore + 3))

        if confident, let topDoc = ranked.first?.doc {
            print("💬 NativeChatView: Auto-selected document: \(topDoc.title) (score \(topScore), second \(secondScore))")
            activeDocsForChat = [topDoc]
            lastDocScopedQuestion = trimmed
            runLLMAnswer(question: trimmed, docsToSearch: [topDoc])
        } else {
            let preview = buildCandidatePreview(candidates)
            if !preview.isEmpty {
                messages.append(ChatMessage(role: "assistant", text: preview, date: Date()))
            }
            messages.append(ChatMessage(
                role: "assistant",
                text: "Which document should I use? Reply with a number (1-\(candidates.count)), the document name, or 'all'.",
                date: Date()
            ))
            pendingDocConfirmation = PendingDocConfirmation(question: trimmed, candidates: candidates)
            isGenerating = false
        }

        // Model call is triggered by runLLMAnswer(...)
    }

    private func tryConsumeDocConfirmationReply(_ reply: String, pending: PendingDocConfirmation) -> Bool {
        let normalized = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = normalized.lowercased()

        if lower == "cancel" || lower == "stop" {
            pendingDocConfirmation = nil
            isGenerating = false
            messages.append(ChatMessage(role: "assistant", text: "Okay — cancelled.", date: Date()))
            return true
        }

        // Accept "doc 1" / "#1" / "1" etc.
        if let idx = extractFirstInt(from: lower) {
            if !pending.candidates.isEmpty, idx >= 1, idx <= pending.candidates.count {
                let doc = pending.candidates[idx - 1]
                pendingDocConfirmation = nil
                activeDocsForChat = [doc]
                lastDocScopedQuestion = pending.question
                runLLMAnswer(question: pending.question, docsToSearch: [doc])
                return true
            }
        }

        // If we had no candidates, treat the reply as a document name hint.
        if pending.candidates.isEmpty {
            let matches = bestTitleMatches(for: lower, within: documentManager.documents)
            if matches.isEmpty {
                return false
            }
            pendingDocConfirmation = nil
            activeDocsForChat = Array(matches.prefix(3))
            lastDocScopedQuestion = pending.question
            runLLMAnswer(question: pending.question, docsToSearch: Array(matches.prefix(3)))
            return true
        }

        if lower == "all" {
            pendingDocConfirmation = nil
            activeDocsForChat = pending.candidates
            lastDocScopedQuestion = pending.question
            runLLMAnswer(question: pending.question, docsToSearch: pending.candidates)
            return true
        }

        // Name match (try candidates first, then fall back to all documents)
        if let doc = bestTitleMatches(for: lower, within: pending.candidates).first {
            pendingDocConfirmation = nil
            activeDocsForChat = [doc]
            lastDocScopedQuestion = pending.question
            runLLMAnswer(question: pending.question, docsToSearch: [doc])
            return true
        }
        if let doc = bestTitleMatches(for: lower, within: documentManager.documents).first {
            pendingDocConfirmation = nil
            activeDocsForChat = [doc]
            lastDocScopedQuestion = pending.question
            runLLMAnswer(question: pending.question, docsToSearch: [doc])
            return true
        }
        return false
    }

    private func looksLikeFollowUpQuestion(_ query: String) -> Bool {
        let s = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }

        // Short, referential questions are commonly follow-ups.
        if s.count <= 120 {
            let starters = ["what", "which", "when", "where", "who", "how", "did", "was", "were", "is", "are", "do", "does"]
            if starters.contains(where: { s.hasPrefix($0 + " ") || s == $0 }) {
                return true
            }
        }

        // Pronoun-heavy or continuation-style phrasing.
        let pronouns = ["it", "they", "them", "this", "that", "those", "these", "there", "he", "she"]
        if pronouns.contains(where: { s.contains(" \($0) ") || s.hasPrefix($0 + " ") }) {
            return true
        }

        // If we recently had a doc-scoped question, bias toward treating as follow-up.
        if !lastDocScopedQuestion.isEmpty {
            return true
        }

        return false
    }

    private func mentionsExplicitDifferentDocument(_ query: String) -> Bool {
        // If the user mentions a specific document title (or CV/resume/etc), allow switching.
        let lower = query.lowercased()
        if lower.contains("use ") && (lower.contains("document") || lower.contains("doc")) {
            return true
        }

        if bestTitleMatches(for: lower, within: documentManager.documents).first != nil {
            // If they name a document, treat it as an explicit target (i.e., can switch).
            return true
        }
        return false
    }

    private func extractFirstInt(from s: String) -> Int? {
        let digits = s.split(whereSeparator: { !$0.isNumber })
        for d in digits {
            if let n = Int(d) { return n }
        }
        return nil
    }

    private func bestTitleMatches(for query: String, within docs: [Document]) -> [Document] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }

        let tokens = q
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        func score(_ title: String) -> Int {
            let t = title.lowercased()
            var s = 0
            if t.contains(q) { s += 50 }
            for tok in tokens {
                if t.contains(tok) { s += 8 }
            }
            // Special synonyms for common cases
            if (q.contains("cv") || q.contains("resume")) && (t.contains("cv") || t.contains("resume")) { s += 30 }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0.title)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return scored.map { $0.doc }
    }

    private func pickDocumentBySnippetEvidence(question: String, docs: [Document]) -> Document? {
        // If we can find actual snippet hits in a document, that's strong evidence.
        // This avoids asking the user "which document" for obvious cases like CV/experience.
        guard !docs.isEmpty else { return nil }

        let q = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let tokens = q
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        if tokens.isEmpty { return nil }

        func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
            for n in needles where haystack.contains(n) {
                return true
            }
            return false
        }

        let cvTitleTokens = ["cv", "resume", "résumé", "curriculum", "vitae"]
        let cvQuestionTokens = ["experience", "work", "employment", "skills", "education", "projects", "profile", "summary"]

        func countOccurrences(_ token: String, in text: String, maxCount: Int) -> Int {
            guard !token.isEmpty else { return 0 }
            var count = 0
            var searchStart = text.startIndex
            while count < maxCount, let r = text.range(of: token, range: searchStart..<text.endIndex) {
                count += 1
                searchStart = r.upperBound
            }
            return count
        }

        var bestDoc: Document?
        var bestScore = 0
        var secondBestScore = 0

        for doc in docs {
            let title = doc.title.lowercased()
            let summary = doc.summary.lowercased()
            let contentPrefix = String(doc.content.prefix(12_000)).lowercased()

            var score = 0

            // Strong boosts for CV/resume flows.
            if containsAny(q, cvQuestionTokens) && containsAny(title, cvTitleTokens) {
                score += 40
            }
            if containsAny(q, cvTitleTokens) && containsAny(title, cvTitleTokens) {
                score += 30
            }

            // Lightweight evidence from title/summary token matches.
            for t in tokens.prefix(8) {
                if title.contains(t) { score += 10 }
                if summary.contains(t) { score += 6 }
            }

            // Evidence from content (prefix only for speed). Cap per-token counts.
            for t in tokens.prefix(6) {
                let c = countOccurrences(t, in: contentPrefix, maxCount: 6)
                if c > 0 { score += min(c, 6) }
            }

            // If local snippet extraction finds something, that's extra confirmation.
            let snippetBlocks = localSearchSnippets(question: question, docs: [doc], maxSnippetsPerDoc: 3, window: 120)
            if !snippetBlocks.isEmpty { score += 12 }

            if score > bestScore {
                secondBestScore = bestScore
                bestScore = score
                bestDoc = doc
            } else if score > secondBestScore {
                secondBestScore = score
            }
        }

        // Require both minimum evidence and a margin over the runner-up to avoid wrong auto-picks.
        guard let picked = bestDoc else { return nil }
        if bestScore >= 18 && bestScore >= secondBestScore + 4 {
            return picked
        }
        return nil
    }

    private func isSmallTalk(_ query: String) -> Bool {
        let s = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if s.isEmpty { return false }

        // Fast heuristics for greetings / chit-chat.
        let exact = [
            "hi", "hello", "hey", "yo",
            "thanks", "thank you", "thx",
            "good morning", "good afternoon", "good evening",
            "how are you", "how's it going", "whats up", "what's up"
        ]
        if exact.contains(s) { return true }

        // Short greeting prefixes
        if s.count <= 20 {
            if s.hasPrefix("hi ") || s.hasPrefix("hello ") || s.hasPrefix("hey ") { return true }
        }
        return false
    }

    private func buildCandidatePreview(_ docs: [Document]) -> String {
        // Only show document names (no OCR/summary previews) unless the user explicitly asks.
        let lines: [String] = docs.prefix(5).enumerated().map { (offset, doc) in
            let idx = offset + 1
            return "\(idx)) \(doc.title)"
        }
        return lines.isEmpty ? "" : ("Possible matches:\n" + lines.joined(separator: "\n"))
    }

    private func runLLMAnswer(question: String, docsToSearch: [Document]) {
        isGenerating = true

        let prompt: String
        if docsToSearch.isEmpty {
            prompt = question
        } else {
            // Step 2: locally search full OCR/content and send only matched snippets.
            let snippets = localSearchSnippets(question: question, docs: docsToSearch, maxSnippetsPerDoc: 4, window: 220)
            let snippetsBlock = snippets.isEmpty
                ? buildDocumentContextBlock(for: docsToSearch, detailed: false)
                : snippets.joined(separator: "\n\n")

            prompt = """
            Answer using the user's documents below. If the answer isn't in the excerpts, say you can't find it.

            \(snippetsBlock)

            Question: \(question)
            """
        }

        print("💬 NativeChatView: Final prompt length: \(prompt.count)")

        Task {
            do {
                guard let edgeAI = EdgeAI.shared else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }

                let reply = try await withCheckedThrowingContinuation { continuation in
                    edgeAI.generate(prompt, resolver: { result in
                        continuation.resume(returning: result as? String ?? "")
                    }, rejecter: { _, message, _ in
                        continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
                    })
                }

                DispatchQueue.main.async {
                    self.isGenerating = false
                    let text = reply.isEmpty ? "(No response)" : reply
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                }
            } catch {
                DispatchQueue.main.async {
                    self.isGenerating = false
                    self.messages.append(ChatMessage(role: "assistant", text: "Error: \(error.localizedDescription)", date: Date()))
                }
            }
        }
    }

    private func localSearchSnippets(question: String, docs: [Document], maxSnippetsPerDoc: Int, window: Int) -> [String] {
        let tokens = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        guard !tokens.isEmpty else { return [] }

        func extractWindows(in text: String, token: String) -> [String] {
            let lower = text.lowercased()
            var results: [String] = []
            var searchStart = lower.startIndex

            while results.count < maxSnippetsPerDoc {
                guard let range = lower.range(of: token, range: searchStart..<lower.endIndex) else { break }
                let matchStart = range.lowerBound
                let matchEnd = range.upperBound

                let start = lower.index(matchStart, offsetBy: -window, limitedBy: lower.startIndex) ?? lower.startIndex
                let end = lower.index(matchEnd, offsetBy: window, limitedBy: lower.endIndex) ?? lower.endIndex
                let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                results.append(snippet)

                searchStart = matchEnd
            }

            return results
        }

        var out: [String] = []
        for doc in docs {
            var snippets: [String] = []
            for t in tokens.prefix(4) {
                snippets.append(contentsOf: extractWindows(in: doc.content, token: t))
                if snippets.count >= maxSnippetsPerDoc { break }
            }

            let unique = Array(NSOrderedSet(array: snippets)) as? [String] ?? snippets
            let trimmedSnippets = Array(unique.prefix(maxSnippetsPerDoc))
            if trimmedSnippets.isEmpty { continue }

            let block = """
            Document: \(doc.title)
            Snippets:
            \(trimmedSnippets.enumerated().map { "- \($0.element)…" }.joined(separator: "\n"))
            """
            out.append(block)
        }
        return out
    }

    private func selectRelevantDocumentsWithScores(for query: String, maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func tokenScore(_ doc: Document, tokens: [String]) -> Int {
            let title = doc.title.lowercased()
            let summary = doc.summary.lowercased()
            let contentPrefix = String(doc.content.prefix(200)).lowercased()
            let category = doc.category.rawValue.lowercased()
            let keywords = doc.keywordsResume.lowercased()

            var s = 0
            for t in tokens {
                if title.contains(t) { s += 8 }
                if summary.contains(t) { s += 5 }
                if category.contains(t) { s += 6 }
                if keywords.contains(t) { s += 5 }
                if contentPrefix.contains(t) { s += 2 }
            }
            return s
        }

        // Fast path: if the full query string appears anywhere, boost that doc.
        let directMatches = documentManager.searchDocuments(query: trimmed)

        let allScored: [(doc: Document, score: Int)] = documentManager.documents.map { doc in
            var score = tokenScore(doc, tokens: tokens)
            if !directMatches.isEmpty && directMatches.contains(where: { $0.id == doc.id }) {
                score += 20
            }
            return (doc: doc, score: score)
        }

        let scored = allScored
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func selectRelevantDocumentsByMetadata(for query: String, maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func score(_ doc: Document) -> Int {
            let title = doc.title.lowercased()
            let category = doc.category.rawValue.lowercased()
            let keywords = doc.keywordsResume.lowercased()
            let q = trimmed.lowercased()

            var s = 0
            if title.contains(q) { s += 20 }
            if keywords.contains(q) { s += 18 }
            if category.contains(q) { s += 12 }

            for t in tokens.prefix(8) {
                if title.contains(t) { s += 10 }
                if keywords.contains(t) { s += 6 }
                if category.contains(t) { s += 6 }
            }

            // Special boost: CV/resume questions should bias toward Resume category.
            if (q.contains("experience") || q.contains("skills") || q.contains("education") || q.contains("resume") || q.contains("cv")) && doc.category == .resume {
                s += 16
            }
            return s
        }

        let scored = documentManager.documents
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func buildDocumentContextBlock(for docs: [Document], detailed: Bool) -> String {
        // Keep prompts small even with many documents.
        let maxCharsPerDoc = detailed ? 1800 : 200

        return docs.map { doc in
            let hasUsableSummary = !doc.summary.isEmpty &&
                doc.summary != "Processing..." &&
                doc.summary != "Processing summary..."

            let body: String
            if !detailed {
                let ocrPrefix = String(doc.content.prefix(maxCharsPerDoc))
                if hasUsableSummary {
                    body = "Summary:\n\(doc.summary)\n\nOCR (first 200 chars):\n\(ocrPrefix)"
                } else {
                    body = "OCR (first 200 chars):\n\(ocrPrefix)"
                }
            } else {
                body = String(doc.content.prefix(maxCharsPerDoc))
            }

            return """
            Document: \(doc.title)
            Type: \(doc.type.rawValue)
            Category: \(doc.category.rawValue)
            Keywords: \(doc.keywordsResume)
            Excerpt:\n\(body)
            ---
            """
        }.joined(separator: "\n")
    }

    private struct ThinkingRow: View {
        @Binding var isPulseOn: Bool

        var body: some View {
            HStack(spacing: 8) {
                Text("Thinking…")
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 4)
            .opacity(isPulseOn ? 0.78 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                    isPulseOn = true
                }
            }
            .onDisappear {
                isPulseOn = false
            }
        }
    }
    
    private func isDocumentQuery(_ query: String) -> Bool {
        let lowercaseQuery = query.lowercased()
        
        // Keywords that suggest the user wants document-based information
        let documentKeywords = [
            // Direct document references
            "document", "file", "pdf", "page", "summary", "summarize", "summery",
            
            // Query patterns about content
            "what does", "explain", "according to", "based on", "in the document", 
            "in the file", "tell me about", "what is", "how does", "what are",
            
            // Search and analysis terms  
            "find", "search", "look for", "show me", "content", "text", "information",
            
            // Analysis and interpretation
            "analyze", "review", "extract", "main points", "key points", "details",
            "meaning", "interpretation", "context", "reference", "mentions"
        ]
        
        // Check if query contains any document-related keywords
        let hasDocumentKeywords = documentKeywords.contains { lowercaseQuery.contains($0) }
        
        // Check for question patterns that typically relate to documents
        let questionPatterns = [
            "what", "how", "why", "when", "where", "who", "which"
        ]
        let hasQuestionPattern = questionPatterns.contains { lowercaseQuery.hasPrefix($0) }
        
        // If it's a question and user has documents, it's likely document-related
        // Or if it explicitly contains document keywords
        return hasDocumentKeywords || (hasQuestionPattern && !documentManager.documents.isEmpty)
    }
    
    private func isDetailedDocumentQuery(_ query: String) -> Bool {
        let lowercaseQuery = query.lowercased()
        
        // Keywords that suggest the user wants detailed analysis or specific information
        let detailedKeywords = [
            "detailed", "details", "specific", "exactly", "quote", "extract", "analyze",
            "full text", "complete", "entire", "all", "everything", "comprehensive",
            "step by step", "thorough", "in-depth", "precise", "exact", "word for word"
        ]
        
        return detailedKeywords.contains { lowercaseQuery.contains($0) }
    }
}

private func formatMarkdownText(_ text: String) -> AttributedString {
    var processedText = text
    
    // Convert markdown lists to bullet points
    processedText = processedText.replacingOccurrences(of: "* ", with: "• ")
    
    // Fix malformed bold markdown: **text* → **text**
    let malformedBoldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*(?!\\*)", options: [])
    processedText = malformedBoldRegex.stringByReplacingMatches(in: processedText, options: [], range: NSRange(location: 0, length: processedText.count), withTemplate: "**$1**")
    
    // Preserve double newlines for paragraphs
    processedText = processedText.replacingOccurrences(of: "\n\n", with: "\n\n")
    
    // Create AttributedString with markdown support
    do {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let attributedString = try AttributedString(markdown: processedText, options: options)
        return attributedString
    } catch {
        // Fallback to plain text if markdown parsing fails
        return AttributedString(processedText)
    }
}

private struct MessageRow: View {
    let msg: ChatMessage

    var body: some View {
        HStack {
            if msg.role == "assistant" {
                bubble
                Spacer(minLength: 40)
            } else {
                Spacer(minLength: 40)
                bubble
            }
        }
    }

    private var bubble: some View {
        Text(formatMarkdownText(msg.text))
            .font(.body)
            .foregroundStyle(msg.role == "user" ? Color.white : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(msg.role == "user" ? Color.accentColor : Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(msg.role == "user" ? Color.clear : Color(.separator), lineWidth: msg.role == "user" ? 0 : 0.5)
            )
    }
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

    init(url: URL, document: Document? = nil, onAISummary: (() -> Void)? = nil) {
        self.url = url
        self.document = document
        self.onAISummary = onAISummary
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color(.systemBackground).ignoresSafeArea()

            VStack(spacing: 0) {
                ZStack {
                    DocumentPreviewNavControllerView(
                        url: url,
                        title: document.map { splitDisplayTitle($0.title).base } ?? "Preview",
                        onDismiss: { dismiss() }
                    )

                // Info button bottom-left (opposite AI)
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
                    .padding(.leading, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }

                // AI button bottom-right
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
                    .padding(.trailing, 20)
                    .padding(.bottom, 20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                }
            }
        }
        .sheet(isPresented: $showingInfo) {
            if let doc = document {
                DocumentInfoView(document: doc, fileURL: url)
            }
        }
    }

}

struct DocumentPreviewNavControllerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let previewController = QLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.navigationItem.title = title
        previewController.navigationItem.largeTitleDisplayMode = .never
        previewController.navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: context.coordinator,
            action: #selector(Coordinator.handleBack)
        )

        let nav = UINavigationController(rootViewController: previewController)
        nav.hidesBarsOnSwipe = true
        nav.navigationBar.prefersLargeTitles = false

        // Style the bar like iOS gray header.
        let appearance = UINavigationBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = UIColor.systemGray6
        appearance.shadowColor = UIColor.separator
        appearance.titleTextAttributes = [
            .font: UIFont.systemFont(ofSize: 17, weight: .semibold)
        ]
        nav.navigationBar.standardAppearance = appearance
        nav.navigationBar.scrollEdgeAppearance = appearance
        nav.navigationBar.compactAppearance = appearance
        nav.navigationBar.tintColor = UIColor.label

        // Round only the top corners of the bar.
        nav.navigationBar.layer.cornerRadius = 16
        nav.navigationBar.layer.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        nav.navigationBar.layer.masksToBounds = true

        return nav
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
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

        @objc func handleBack() {
            onDismiss()
        }
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
      if #available(iOS 16.4, *) {
            self.presentationCornerRadius(0)
        } else {
            self
        }
    }
}

struct DocumentInfoView: View {
    let document: Document
    let fileURL: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                infoRow("Name", splitDisplayTitle(document.title).base)
                infoRow("Size", formattedSize)
                infoRow("Source", sourceLabel)
                infoRow("Extension", fileExtension)
                infoRow("Date Added", dateAdded)
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
        case .image: return "img"
        case .scanned: return document.pdfData != nil ? "pdf" : "img"
        case .text: return "txt"
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
}

// MARK: - Document Summary View
struct DocumentSummaryView: View {
    let document: Document
    @State private var summary: String = ""
    @State private var isGeneratingSummary = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var documentManager: DocumentManager

    private var currentDoc: Document {
        documentManager.getDocument(by: document.id) ?? document
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
                            Button("Generate") { generateAISummary() }
                                .disabled(isGeneratingSummary)
                        }
                        
                        if isGeneratingSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating summary...")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical)
                        } else if summary.isEmpty {
                            Text("Tap 'Generate' to create an AI summary of this document.")
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
                    
                    // OCR
                    VStack(alignment: .leading, spacing: 12) {
                        Text("OCR")
                            .font(.headline)
                        
                        ScrollView {
                            Text(currentDoc.content)
                                .font(.system(size: 14, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding()
                                .background(Color(.tertiarySystemBackground))
                                .cornerRadius(8)
                        }
                        .frame(height: 200)
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
            if summary.isEmpty || summary == "Processing..." || summary == "Processing summary..." {
                generateAISummary()
            }
        }
    }
    
    private func generateAISummary() {
        print("🧠 DocumentSummaryView: Generating AI summary for '\(document.title)'")
        isGeneratingSummary = true
        
        // Send only a mode marker and the raw source; system preprompt is injected in JS
        let prompt = "<<<SUMMARY_REQUEST>>>\n\(currentDoc.content)"
        
        print("🧠 DocumentSummaryView: Sending summary request, content length: \(currentDoc.content.count)")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🧠 DocumentSummaryView: Got summary result: \(String(describing: result))")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                
                if let result = result as? String, !result.isEmpty {
                    self.summary = result
                    // Persist to the associated document so it isn't regenerated unnecessarily
                    self.documentManager.updateSummary(for: document.id, to: result)
                } else {
                    print("❌ DocumentSummaryView: Empty or nil result")
                    self.summary = "Failed to generate summary: Empty response. Please try again."
                }
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentSummaryView: Summary generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.isGeneratingSummary = false
                self.summary = "Failed to generate summary: \(message ?? "Unknown error"). Please try again."
            }
        })
    }
}
