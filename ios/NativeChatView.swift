import SwiftUI
import UIKit
import Foundation
import Vision
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import QuickLook
import CoreText
import WebKit
import AVFoundation

// No need for TempDocumentManager - using DocumentManager.swift

struct Document: Identifiable, Codable, Hashable, Equatable {
    let id: UUID
    let title: String
    let content: String
    let summary: String
    let ocrPages: [OCRPage]?
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
        ocrPages: [OCRPage]? = nil,
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
        self.ocrPages = ocrPages
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

struct OCRBoundingBox: Codable, Hashable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}

struct OCRBlock: Codable, Hashable, Equatable {
    let text: String
    let confidence: Double
    let bbox: OCRBoundingBox
    let order: Int
}

struct OCRPage: Codable, Hashable, Equatable {
    let pageIndex: Int
    let blocks: [OCRBlock]
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

private enum ScannerMode {
    case document
    case simple
}

struct TabContainerView: View {
    @StateObject private var documentManager = DocumentManager()
    @State private var summaryRequestsInFlight: Set<UUID> = []
    @State private var summaryQueue: [SummaryJob] = []
    @State private var isSummarizing = false
    @State private var currentSummaryDocId: UUID? = nil
    @State private var canceledSummaryIds: Set<UUID> = []

    private struct SummaryJob: Equatable {
        let documentId: UUID
        let prompt: String
    }

    var body: some View {
        TabView {
            DocumentsView()
                .environmentObject(documentManager)
                .tabItem {
                    Image(systemName: "doc.text")
                    Text("Documents")
                }
            
            ConversionView()
                .environmentObject(documentManager)
                .tabItem {
                    Image(systemName: "arrow.triangle.2.circlepath")
                    Text("Convert")
                }
            
            NativeChatView()
                .environmentObject(documentManager)
                .tabItem {
                    Image(systemName: "message")
                    Text("Chat")
                }
        }
        .onAppear {
            for doc in documentManager.documents where isSummaryPlaceholder(doc.summary) {
                documentManager.generateSummary(for: doc)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CancelDocumentSummary"))) { notification in
            guard let idString = notification.userInfo?["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }

            // Remove from queue if it hasn't started.
            if let idx = summaryQueue.firstIndex(where: { $0.documentId == docId }) {
                summaryQueue.remove(at: idx)
            }

            // Mark in-flight summaries as canceled so results are ignored.
            if currentSummaryDocId == docId {
                canceledSummaryIds.insert(docId)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("GenerateDocumentSummary"))) { notification in
            guard let userInfo = notification.userInfo,
                  let idString = userInfo["documentId"] as? String,
                  let prompt = userInfo["prompt"] as? String,
                  let docId = UUID(uuidString: idString) else {
                return
            }
            let force = (userInfo["force"] as? Bool) ?? false

            // Skip if we already generated (or are generating) a summary.
            if !force && summaryRequestsInFlight.contains(docId) {
                return
            }
            if !force, let doc = documentManager.getDocument(by: docId),
               !isSummaryPlaceholder(doc.summary) {
                return
            }

            // Ensure we re-queue for regenerate.
            summaryQueue.removeAll { $0.documentId == docId }
            let job = SummaryJob(documentId: docId, prompt: prompt)
            summaryQueue.append(job)
            processNextSummaryIfNeeded()
        }
    }

    private func isSummaryPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary..."
    }

    private func processNextSummaryIfNeeded() {
        guard !isSummarizing else { return }
        guard let next = summaryQueue.first else { return }
        guard let doc = documentManager.getDocument(by: next.documentId),
              isSummaryPlaceholder(doc.summary) else {
            summaryQueue.removeFirst()
            processNextSummaryIfNeeded()
            return
        }

        isSummarizing = true
        currentSummaryDocId = next.documentId
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": true, "documentId": next.documentId.uuidString]
        )
        summaryRequestsInFlight.insert(next.documentId)

        EdgeAI.shared?.generate(next.prompt, resolver: { result in
            DispatchQueue.main.async {
                self.summaryRequestsInFlight.remove(next.documentId)
                if !self.canceledSummaryIds.contains(next.documentId),
                   let summary = result as? String, !summary.isEmpty {
                    self.documentManager.updateSummary(for: next.documentId, to: summary)
                }
                self.finishSummary(for: next.documentId)
            }
        }, rejecter: { _, _, _ in
            DispatchQueue.main.async {
                self.summaryRequestsInFlight.remove(next.documentId)
                self.finishSummary(for: next.documentId)
            }
        })
    }

    private func finishSummary(for documentId: UUID) {
        canceledSummaryIds.remove(documentId)

        if let idx = summaryQueue.firstIndex(where: { $0.documentId == documentId }) {
            summaryQueue.remove(at: idx)
        } else if !summaryQueue.isEmpty {
            summaryQueue.removeFirst()
        }

        isSummarizing = false
        currentSummaryDocId = nil
        NotificationCenter.default.post(
            name: NSNotification.Name("SummaryGenerationStatus"),
            object: nil,
            userInfo: ["isActive": false, "documentId": documentId.uuidString]
        )
        processNextSummaryIfNeeded()
    }
}

struct DocumentsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var showingDocumentPicker = false
    @State private var showingScanner = false
    @State private var scannerMode: ScannerMode = .document
    @State private var showingCameraPermissionAlert = false
    @State private var isProcessing = false
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText = ""
    @State private var pendingOCRPages: [OCRPage] = []
    @State private var pendingCategory: Document.DocumentCategory = .general
    @State private var pendingKeywordsResume: String = ""
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
                    startScan()
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
                                    destination: FolderDocumentsView(folder: folder, onOpenDocument: openDocumentPreview).environmentObject(documentManager),
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
                                    destination: FolderDocumentsView(folder: folder, onOpenDocument: openDocumentPreview).environmentObject(documentManager),
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
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Text(" Documents ")
                            .font(.headline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
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
                                startScan()
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
        .sheet(item: $documentToMove) { doc in
            MoveToFolderSheet(
                document: doc,
                folders: documentManager.folders(in: nil),
                currentFolderName: documentManager.folderName(for: doc.folderId),
                currentContainerName: "Documents",
                allowRootSelection: true,
                onSelectFolder: { folderId in
                    documentManager.moveDocument(documentId: doc.id, toFolder: folderId)
                    documentToMove = nil
                },
                onCancel: {
                    documentToMove = nil
                }
            )
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in
                processImportedFiles(urls)
            }
        }
        .onAppear {
            // Force refresh when the view appears to show newly converted documents
            documentManager.objectWillChange.send()
        }
        .refreshable {
            // Add pull-to-refresh functionality
            documentManager.objectWillChange.send()
        }
        .sheet(isPresented: $showingScanner) {
            if scannerMode == .document, VNDocumentCameraViewController.isSupported {
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
        .alert("Camera Access Needed", isPresented: $showingCameraPermissionAlert) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow camera access to scan documents.")
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
                // Only handle scanned documents now since imported files keep original names
                scannedImages.removeAll()
                extractedText = ""
                suggestedName = ""
                customName = ""
                pendingCategory = .general
                pendingKeywordsResume = ""
                pendingOCRPages = []
                isProcessing = false
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
                        ocrPages: old.ocrPages,
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
                let shouldShowSummary = document.type != .image
                DocumentPreviewContainerView(
                    url: url,
                    document: document,
                    onAISummary: shouldShowSummary ? {
                        showingDocumentPreview = false
                        showingAISummary = true
                        isOpeningPreview = false
                    } : nil
                )
            }
        }
        .sheet(isPresented: $showingAISummary, onDismiss: { isOpeningPreview = false }) {
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
        // Navigate to conversion view with pre-selected document
        // This will be handled by the dedicated Convert tab
        print("Convert document: \(document.title)")
        // Note: Users should use the Convert tab for full conversion functionality
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
        
        for url in urls {
            print("📱 UI: Processing file: \\(url.lastPathComponent)")
            print("📱 UI: File URL: \\(url.absoluteString)")
            print("📱 UI: File exists: \\(FileManager.default.fileExists(atPath: url.path))")
            
            // Try to access the security scoped resource
            let didStartAccess = url.startAccessingSecurityScopedResource()
            print("📱 UI: Security scoped access: \\(didStartAccess)")
            
            // Even if security access fails, try to process the file
            if let document = documentManager.processFile(at: url) {
                print("📱 UI: ✅ Successfully created document with original name: \\(document.title)")
                print("📱 UI: Document content preview: \\(String(document.content.prefix(100)))...")

                // Persist and add to list immediately so it appears in the UI.
                documentManager.addDocument(document)

                // Generate category and keywords in background but keep original filename
                let fullTextForKeywords = document.content
                DispatchQueue.global(qos: .utility).async {
                    let cat = DocumentManager.inferCategory(title: document.title, content: fullTextForKeywords, summary: document.summary)
                    let kw = DocumentManager.makeKeywordsResume(title: document.title, content: fullTextForKeywords, summary: document.summary)
                    
                    DispatchQueue.main.async {
                        // Update the document with category and keywords but keep the original title
                        let updatedDocument = Document(
                            id: document.id,
                            title: document.title, // Keep original name
                            content: document.content,
                            summary: document.summary,
                            ocrPages: document.ocrPages,
                            category: cat,
                            keywordsResume: kw,
                            dateCreated: document.dateCreated,
                            type: document.type,
                            imageData: document.imageData,
                            pdfData: document.pdfData,
                            originalFileData: document.originalFileData
                        )
                        
                        // Update document in the manager
                        if let idx = self.documentManager.documents.firstIndex(where: { $0.id == document.id }) {
                            self.documentManager.documents[idx] = updatedDocument
                        }
                    }
                }
                
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
        
        // No more AI naming queue - files are processed directly with original names
        DispatchQueue.main.async {
            self.isProcessing = false
        }
    }

    private func finalizePendingDocument(with name: String) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = finalName.isEmpty ? suggestedName : finalName

        // This function now only handles scanned documents since imported files keep original names
        finalizeDocument(with: safeName)
    }

    private func startScan() {
        if !VNDocumentCameraViewController.isSupported {
            scannerMode = .simple
            showingScanner = true
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            scannerMode = .document
            showingScanner = true
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        scannerMode = .document
                        showingScanner = true
                    } else {
                        showingCameraPermissionAlert = true
                    }
                }
            }
        case .denied, .restricted:
            showingCameraPermissionAlert = true
        @unknown default:
            showingCameraPermissionAlert = true
        }
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
        let firstPage = performOCRDetailed(on: firstImage, pageIndex: 0)
        let firstPageText = firstPage.text
        print("First page OCR result: \(firstPageText.prefix(100))...") // Log first 100 chars

        // Process all images for full content
        var allText = ""
        var ocrPages: [OCRPage] = []
        for (index, image) in images.enumerated() {
            print("Processing page \(index + 1) for OCR...")
            let page = performOCRDetailed(on: image, pageIndex: index)
            allText += "Page \(index + 1):\n\(page.text)\n\n"
            ocrPages.append(page.page)
            print("Page \(index + 1) OCR completed: \(page.text.count) characters")
        }
        extractedText = buildStructuredText(from: ocrPages, includePageLabels: true)
        pendingOCRPages = ocrPages
        
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

        // Use AI to suggest document name based on first 200 OCR chars
        if !firstPageText.isEmpty && firstPageText != "No text found in image" && !firstPageText.contains("OCR failed") {
            print("Using AI to generate document name from OCR text")
            generateAIDocumentName(from: firstPageText)
        } else {
            print("OCR extraction failed or returned no text, using default name")
            suggestedName = "ScannedDocument"
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        }
    }

    private func generateAIDocumentName(from text: String) {
        let prompt = """
        <<<NAME_REQUEST>>>Generate a given OCR specific 2-3 word title that differentiates this document.

        STRICT OUTPUT:
        - Exactly 2 or 3 words
        - Title Case
        - No punctuation, no numbers, no file extensions

        OCR Snippet (first 200 chars):
        \(text.prefix(200))

        Response format: Just the title, nothing else.
        """

        print("🏷️ DocumentsView: Generating AI document name from OCR text")
        EdgeAI.shared?.generate(prompt, resolver: { result in
            print("🏷️ DocumentsView: Got name suggestion result: \(String(describing: result))")
            DispatchQueue.main.async {
                if let result = result as? String, !result.isEmpty {
                    let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = normalizeSuggestedTitle(clean)
                    self.suggestedName = normalized.isEmpty ? "ScannedDocument" : normalized
                } else {
                    self.suggestedName = "ScannedDocument"
                }
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentsView: Name generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.suggestedName = "ScannedDocument"
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        })
    }

    private func normalizeSuggestedTitle(_ raw: String) -> String {
        let stripped = raw.replacingOccurrences(of: "[^A-Za-z ]+", with: " ", options: .regularExpression)
        let words = stripped
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }

        guard words.count >= 2 else { return "" }
        let limited = Array(words.prefix(3))
        let titleCased = limited.map { word -> String in
            let lower = word.lowercased()
            return lower.prefix(1).uppercased() + lower.dropFirst()
        }
        return titleCased.joined(separator: "")
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
            ocrPages: pendingOCRPages.isEmpty ? nil : pendingOCRPages,
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
            pendingOCRPages = []
        }
    }
    
    private func processScannedImages(_ images: [UIImage]) {
        isProcessing = true
        
        var allText = ""
        var imageDataArray: [Data] = []
        var ocrPages: [OCRPage] = []
        
        for (index, image) in images.enumerated() {
            let page = performOCRDetailed(on: image, pageIndex: index)
            allText += "Page \(index + 1):\n\(page.text)\n\n"
            ocrPages.append(page.page)
            
            // Save image data with high quality
            if let imageData = image.jpegData(compressionQuality: 0.95) {
                imageDataArray.append(imageData)
            }
        }
        
        // Generate PDF from images
        let pdfData = createPDF(from: images)
        
        let document = Document(
            title: "Scanned Document \(documentManager.documents.count + 1)",
            content: buildStructuredText(from: ocrPages, includePageLabels: true),
            summary: "Processing summary...",
            ocrPages: ocrPages.isEmpty ? nil : ocrPages,
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
    
    private func performOCRDetailed(on image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            print("OCR: Failed to process image")
            return ("Could not process image", OCRPage(pageIndex: pageIndex, blocks: []))
        }
        
        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US", "en-GB"]
        
        var blocks: [OCRBlock] = []
        var recognizedText = ""
        
        do {
            try requestHandler.perform([request])
            
            if let results = request.results {
                let observations = results.compactMap { observation -> (String, CGRect, Double)? in
                    guard let topCandidate = observation.topCandidates(1).first else { return nil }
                    return (topCandidate.string, observation.boundingBox, Double(topCandidate.confidence))
                }
                
                let sorted = observations.sorted { first, second in
                    let yDiff = abs(first.1.minY - second.1.minY)
                    if yDiff < 0.02 {
                        return first.1.minX < second.1.minX
                    }
                    return first.1.minY > second.1.minY
                }
                
                for (idx, item) in sorted.enumerated() {
                    let bbox = OCRBoundingBox(
                        x: Double(item.1.origin.x),
                        y: Double(item.1.origin.y),
                        width: Double(item.1.size.width),
                        height: Double(item.1.size.height)
                    )
                    blocks.append(OCRBlock(text: item.0, confidence: item.2, bbox: bbox, order: idx))
                }
                
                recognizedText = sorted.map { $0.0 }.joined(separator: " ")
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
        
        let page = OCRPage(pageIndex: pageIndex, blocks: blocks)
        return (recognizedText.isEmpty ? "No text found in image" : recognizedText, page)
    }

    private func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        guard !pages.isEmpty else { return "" }

        func paragraphize(_ lines: [(text: String, y: Double)]) -> String {
            var output: [String] = []
            var lastY: Double? = nil

            for line in lines {
                if let last = lastY, abs(line.y - last) > 0.04 {
                    output.append("") // paragraph break
                }
                output.append(line.text)
                lastY = line.y
            }

            return output.joined(separator: "\n").replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
        }

        var result: [String] = []
        for page in pages {
            let sorted = page.blocks.sorted { $0.order < $1.order }
            var lines: [(text: String, y: Double)] = []

            for block in sorted {
                if let last = lines.last, abs(block.bbox.y - last.y) < 0.02 {
                    let combined = last.text.isEmpty ? block.text : "\(last.text) \(block.text)"
                    lines[lines.count - 1] = (combined, last.y)
                } else {
                    lines.append((block.text, block.bbox.y))
                }
            }

            let body = paragraphize(lines)
            if includePageLabels {
                result.append("Page \(page.pageIndex + 1):\n\(body)")
            } else {
                result.append(body)
            }
        }

        return result.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        // Ensure proper orientation and size for OCR
        guard let cgImage = image.cgImage else { return nil }
        
        let targetSize: CGFloat = 2560 // Higher detail for OCR while keeping perf reasonable
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
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
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
        let previewHeight: CGFloat = 120

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemBackground))

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
            .frame(height: previewHeight)
            .cornerRadius(10)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .overlay(alignment: .topTrailing) {
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
                .padding(.top, 6)
                .padding(.trailing, 6)
            }

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
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
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
        let previewHeight: CGFloat = 120
        let parts = splitDisplayTitle(folder.name)

        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.tertiarySystemBackground))
                Image(systemName: "folder.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.blue)
            }
            .frame(height: previewHeight)
            .cornerRadius(10)
            .frame(maxWidth: .infinity, alignment: .topTrailing)
            .overlay(alignment: .topTrailing) {
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
                .padding(.top, 6)
                .padding(.trailing, 6)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(parts.base)
                    .font(.subheadline)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(docCount) item\(docCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundColor(Color(.tertiaryLabel))
                    .lineLimit(1)
            }
            .padding(.trailing, 8)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            onOpen()
        }
    }
}

struct FolderDocumentsView: View {
    let folder: DocumentFolder
    let onOpenDocument: (Document) -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    private var layoutMode: DocumentLayoutMode { documentManager.prefersGridLayout ? .grid : .list }
    @State private var documentToMove: Document?

    @State private var activeSubfolderId: UUID?

    @State private var showingRenameFolderDialog = false
    @State private var renameFolderText = ""
    @State private var folderToRename: DocumentFolder?

    @State private var showingMoveFolderSheet = false
    @State private var folderToMove: DocumentFolder?

    @State private var showingDeleteFolderDialog = false
    @State private var folderToDelete: DocumentFolder?

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
                                        destination: FolderDocumentsView(folder: sub, onOpenDocument: onOpenDocument).environmentObject(documentManager),
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
                            onOpen: { onOpenDocument(document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
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
                                destination: FolderDocumentsView(folder: sub, onOpenDocument: onOpenDocument).environmentObject(documentManager),
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
                            onOpen: { onOpenDocument(document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
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
        .sheet(item: $documentToMove) { doc in
            MoveToFolderSheet(
                document: doc,
                folders: documentManager.folders(in: folder.id),
                currentFolderName: documentManager.folderName(for: doc.folderId),
                currentContainerName: folder.name,
                allowRootSelection: true,
                onSelectFolder: { folderId in
                    documentManager.moveDocument(documentId: doc.id, toFolder: folderId)
                    documentToMove = nil
                },
                onCancel: {
                    documentToMove = nil
                }
            )
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
                        ocrPages: old.ocrPages,
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

}

struct MoveToFolderSheet: View {
    let document: Document
    let folders: [DocumentFolder]
    let currentFolderName: String?
    let currentContainerName: String
    let allowRootSelection: Bool
    let onSelectFolder: (UUID?) -> Void
    let onCancel: () -> Void

    var body: some View {
        NavigationView {
            List {
                HStack {
                    Text(currentContainerName)
                        .foregroundColor(.secondary)
                    Spacer()
                }

                if allowRootSelection {
                    Button {
                        onSelectFolder(nil)
                    } label: {
                        HStack {
                            Text("Documents")
                            Spacer()
                            if currentFolderName == nil {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                            }
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
                if document.type != .image {
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
                    
                    if document.type != .image {
                        Button("Generate AI Summary") {
                            generateAISummary()
                        }
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
            Group {
                // AI Summary Button
                if document.type != .image {
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
            }
            .padding()
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
        scanner.modalPresentationStyle = .fullScreen
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
    @State private var showSummaryLoadingWarning = false
    @State private var hasShownSummaryLoadingWarning = false
    @State private var isSummaryGenerationActive = false
    @State private var showingScopePicker = false
    @State private var selectedDocIds: [UUID] = []
    @State private var selectedFolderId: UUID? = nil
    @State private var responseCache: [String: String] = [:]
    @State private var responseCacheOrder: [String] = []
    @State private var activeChatGenerationId: UUID? = nil
    @State private var lastResolvedDocsForChat: [Document] = []
    @State private var lastResolvedDocContext: String = ""
    @State private var lastResolvedDocId: UUID? = nil
    @FocusState private var isFocused: Bool
    @EnvironmentObject private var documentManager: DocumentManager

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
                                .disabled(isGenerating || isSummaryGenerationActive)
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
                                .foregroundColor(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || isSummaryGenerationActive ? .secondary : .white)
                                .background(
                                    Circle()
                                        .fill(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isGenerating || isSummaryGenerationActive ? Color(.systemFill) : Color.accentColor)
                                )
                        }
                        .disabled(isSummaryGenerationActive || (input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isGenerating))
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .background(Color(.systemBackground))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" Chat ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(scopeLabel) {
                        showingScopePicker = true
                    }
                }
            }
        }
        .alert("Some documents are still preparing", isPresented: $showSummaryLoadingWarning) {
            Button("OK") {}
        } message: {
            Text("You can keep chatting now. I’ll answer using the documents that are ready.")
        }
        .sheet(isPresented: $showingScopePicker) {
            ChatScopePickerView(
                selectedDocIds: $selectedDocIds,
                selectedFolderId: $selectedFolderId,
                folders: documentManager.folders,
                documents: documentManager.documents
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryGenerationStatus"))) { notification in
            guard let active = notification.userInfo?["isActive"] as? Bool else { return }
            isSummaryGenerationActive = active
        }
        .onChange(of: selectedDocIds) { _ in
            activeDocsForChat = []
            pendingDocConfirmation = nil
            lastDocScopedQuestion = ""
            lastResolvedDocsForChat = []
            lastResolvedDocContext = ""
            lastResolvedDocId = nil
        }
        .onChange(of: selectedFolderId) { _ in
            activeDocsForChat = []
            pendingDocConfirmation = nil
            lastDocScopedQuestion = ""
            lastResolvedDocsForChat = []
            lastResolvedDocContext = ""
            lastResolvedDocId = nil
        }
    }

    private func send() {
        if isGenerating {
            stopGeneration()
            return
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isSummaryGenerationActive {
            messages.append(ChatMessage(
                role: "assistant",
                text: "I am busy generating a summary. Try again later.",
                date: Date()
            ))
            input = ""
            return
        }

        print("💬 NativeChatView: Sending message: '\(trimmed)'")
        let userMsg = ChatMessage(role: "user", text: trimmed, date: Date())
        messages.append(userMsg)
        input = ""
        isGenerating = true

        let scopedDocs = scopedDocuments()
        activeDocsForChat = scopedDocs
        lastDocScopedQuestion = trimmed
        startGeneration(question: trimmed, docsToSearch: scopedDocs)

        // Model call is triggered by runLLMAnswer(...)
    }

    private func stopGeneration() {
        guard isGenerating else { return }
        isGenerating = false
        activeChatGenerationId = nil
        EdgeAI.shared?.cancelCurrentGeneration()
    }

    private func startGeneration(question: String, docsToSearch: [Document]) {
        let generationId = UUID()
        activeChatGenerationId = generationId
        runLLMAnswer(question: question, docsToSearch: docsToSearch, generationId: generationId)
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

        if pending.candidates.count == 1 {
            if lower == "yes" || lower == "y" || lower == "correct" {
                let doc = pending.candidates[0]
                pendingDocConfirmation = nil
                activeDocsForChat = [doc]
                lastDocScopedQuestion = pending.question
                startGeneration(question: pending.question, docsToSearch: [doc])
                return true
            }
            if lower == "no" || lower == "n" {
                pendingDocConfirmation = nil
                isGenerating = false
                messages.append(ChatMessage(
                    role: "assistant",
                    text: "Got it. Tell me the document name (or paste a unique phrase) and I’ll check it.",
                    date: Date()
                ))
                return true
            }
        }

        // Accept "doc 1" / "#1" / "1" etc.
        if let idx = extractFirstInt(from: lower) {
            if !pending.candidates.isEmpty, idx >= 1, idx <= pending.candidates.count {
                let doc = pending.candidates[idx - 1]
                pendingDocConfirmation = nil
                activeDocsForChat = [doc]
                lastDocScopedQuestion = pending.question
                startGeneration(question: pending.question, docsToSearch: [doc])
                return true
            }
        }

        // If we had no candidates, treat the reply as a document name hint.
        if pending.candidates.isEmpty {
            let matches = bestTitleMatches(for: lower, within: documentsWithReadySummaries(from: scopedDocuments()))
            if matches.isEmpty {
                return false
            }
            pendingDocConfirmation = nil
            activeDocsForChat = Array(matches.prefix(3))
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: Array(matches.prefix(3)))
            return true
        }

        if lower == "all" {
            pendingDocConfirmation = nil
            activeDocsForChat = pending.candidates
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: pending.candidates)
            return true
        }

        // Name match (try candidates first, then fall back to all documents)
        if let doc = bestTitleMatches(for: lower, within: pending.candidates).first {
            pendingDocConfirmation = nil
            activeDocsForChat = [doc]
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: [doc])
            return true
        }
        if let doc = bestTitleMatches(for: lower, within: documentsWithReadySummaries(from: scopedDocuments())).first {
            pendingDocConfirmation = nil
            activeDocsForChat = [doc]
            lastDocScopedQuestion = pending.question
            startGeneration(question: pending.question, docsToSearch: [doc])
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

        if bestTitleMatches(for: lower, within: documentsWithReadySummaries(from: scopedDocuments())).first != nil {
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

    private func shouldReuseLastDocs(for question: String) -> Bool {
        if isSmallTalk(question) { return false }
        if lastResolvedDocsForChat.isEmpty { return false }
        if mentionsExplicitDifferentDocument(question) { return false }
        return looksLikeFollowUpQuestion(question)
    }

    private func buildDocContextSnippet(for doc: Document, maxChars: Int) -> String {
        let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasSummary = !summary.isEmpty && summary != "Processing..." && summary != "Processing summary..."
        let ocr = doc.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let ocrPrefix = String(ocr.prefix(maxChars))
        if hasSummary {
            return "Summary:\n\(summary)\n\nOCR excerpt:\n\(ocrPrefix)"
        }
        return "OCR excerpt:\n\(ocrPrefix)"
    }

    private func buildCandidatePreview(_ docs: [Document]) -> String {
        // Only show document names (no OCR/summary previews) unless the user explicitly asks.
        let lines: [String] = docs.prefix(5).enumerated().map { (offset, doc) in
            let idx = offset + 1
            return "\(idx)) \(doc.title)"
        }
        return lines.isEmpty ? "" : ("Possible matches:\n" + lines.joined(separator: "\n"))
    }

    private func runLLMAnswer(question: String, docsToSearch: [Document], generationId: UUID) {
        isGenerating = true

        Task {
            do {
                if activeChatGenerationId != generationId { return }
                guard let edgeAI = EdgeAI.shared else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: EdgeAI not initialized", date: Date()))
                    }
                    return
                }

                if isSmallTalk(question) {
                    if activeChatGenerationId != generationId { return }
                    let reply = try await callLLM(edgeAI: edgeAI, prompt: question)
                    DispatchQueue.main.async {
                        if self.activeChatGenerationId != generationId { return }
                        self.isGenerating = false
                        let text = reply.isEmpty ? "(No response)" : reply
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                let reuseDocs = shouldReuseLastDocs(for: question)
                let cachedDocs = reuseDocs ? lastResolvedDocsForChat : docsToSearch
                let cacheKey = makeCacheKey(question: question, docs: cachedDocs)
                if let cached = responseCache[cacheKey] {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        let text = cached.isEmpty ? "(No response)" : cached
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                if docsToSearch.isEmpty {
                    if activeChatGenerationId != generationId { return }
                    let reply = try await callLLM(edgeAI: edgeAI, prompt: question)
                    DispatchQueue.main.async {
                        if self.activeChatGenerationId != generationId { return }
                        self.isGenerating = false
                        let text = reply.isEmpty ? "(No response)" : reply
                        self.storeResponseCache(key: cacheKey, value: text)
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                if reuseDocs,
                   let finalDoc = lastResolvedDocsForChat.first,
                   let lastId = lastResolvedDocId,
                   lastId == finalDoc.id,
                   !lastResolvedDocContext.isEmpty {
                    let followUpPrompt = """
                    Cached document context:
                    \(lastResolvedDocContext)

                    Question: \(question)
                    """
                    if activeChatGenerationId != generationId { return }
                    let finalReply = try await callLLM(edgeAI: edgeAI, prompt: followUpPrompt)
                    DispatchQueue.main.async {
                        if self.activeChatGenerationId != generationId { return }
                        self.isGenerating = false
                        let text = finalReply.isEmpty ? "(No response)" : finalReply
                        self.storeResponseCache(key: cacheKey, value: text)
                        self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                    }
                    return
                }

                // Stage 1: titles only -> keep only titles that might match.
                let titlesBlock = buildDocumentTitlesBlock(for: docsToSearch, maxDocs: 60)
                let stage1Prompt = """
                Document Titles:
                \(titlesBlock)

                Question: \(question)

                Return only the titles that might contain the answer.
                Reply with:
                TITLES:
                - <title>
                or:
                NONE
                """
                if activeChatGenerationId != generationId { return }
                let stage1Reply = try await callLLM(edgeAI: edgeAI, prompt: stage1Prompt)

                var stageDocs = parseTitleListReply(stage1Reply, allDocs: docsToSearch)
                // If the model couldn't match titles, fall back to the full set and continue.
                if stageDocs.isEmpty { stageDocs = docsToSearch }

                // Stage 2: summary prefixes for selected (or all if none).
                let summaryPrefixBlock = buildDocumentSummaryPrefixBlock(for: stageDocs, maxDocs: 60, maxChars: 100)
                let stage2Prompt = """
                Summary Prefixes (first 100 chars each):
                \(summaryPrefixBlock)

                Previous stage output:
                \(stage1Reply.trimmingCharacters(in: .whitespacesAndNewlines))

                Question: \(question)

                Return only the titles that still look relevant.
                Reply with:
                TITLES:
                - <title>
                or:
                NONE
                """
                if activeChatGenerationId != generationId { return }
                let stage2Reply = try await callLLM(edgeAI: edgeAI, prompt: stage2Prompt)

                var remainingDocs = parseTitleListReply(stage2Reply, allDocs: stageDocs)
                // If summaries didn't match, keep the previous set and continue.
                if remainingDocs.isEmpty { remainingDocs = stageDocs }

                // Stage 3: full summary if multiple remain, else full OCR for the only doc.
                var stage3Reply = ""
                if remainingDocs.count > 1 {
                    let fullSummaries = buildDocumentFullSummariesBlock(for: remainingDocs, maxDocs: 12)
                    let stage3Prompt = """
                    Full Summaries:
                    \(fullSummaries)

                    Previous stage output:
                    \(stage2Reply.trimmingCharacters(in: .whitespacesAndNewlines))

                    Question: \(question)

                    Return only the titles that still look relevant.
                    Reply with:
                    TITLE: <title>
                    or:
                    NONE
                    """
                    if activeChatGenerationId != generationId { return }
                    stage3Reply = try await callLLM(edgeAI: edgeAI, prompt: stage3Prompt)
                    if let picked = parseSingleTitleReply(stage3Reply, allDocs: remainingDocs) {
                        remainingDocs = [picked]
                    } else if let picked = remainingDocs.first {
                        // If the model can't pick from summaries, default to the first candidate.
                        remainingDocs = [picked]
                    }
                }

                guard let finalDoc = remainingDocs.first else {
                    DispatchQueue.main.async {
                        self.isGenerating = false
                        self.messages.append(ChatMessage(role: "assistant", text: "I couldn't find a relevant document.", date: Date()))
                    }
                    return
                }

                let ocrBlock = buildDocumentOCRBlock(for: finalDoc)
                let stage4Prompt = """
                OCR (full text):
                \(ocrBlock)

                Previous stage output:
                \(stage3Reply.trimmingCharacters(in: .whitespacesAndNewlines))

                Question: \(question)
                """
                if activeChatGenerationId != generationId { return }
                let finalReply = try await callLLM(edgeAI: edgeAI, prompt: stage4Prompt)

                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    let text = finalReply.isEmpty ? "(No response)" : finalReply
                    self.lastResolvedDocsForChat = [finalDoc]
                    self.lastResolvedDocId = finalDoc.id
                    self.lastResolvedDocContext = self.buildDocContextSnippet(for: finalDoc, maxChars: 1800)
                    self.storeResponseCache(key: cacheKey, value: text)
                    self.messages.append(ChatMessage(role: "assistant", text: text, date: Date()))
                }
            } catch {
                DispatchQueue.main.async {
                    if self.activeChatGenerationId != generationId { return }
                    self.isGenerating = false
                    if error.localizedDescription != "CANCELLED" {
                        self.messages.append(ChatMessage(role: "assistant", text: "Error: \(error.localizedDescription)", date: Date()))
                    }
                }
            }
        }
    }

    private func callLLM(edgeAI: EdgeAI, prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            edgeAI.generate("<<<NO_HISTORY>>>" + prompt, resolver: { result in
                continuation.resume(returning: result as? String ?? "")
            }, rejecter: { _, message, _ in
                continuation.resume(throwing: NSError(domain: "EdgeAI", code: 0, userInfo: [NSLocalizedDescriptionKey: message ?? "Unknown error"]))
            })
        }
    }

    private func makeCacheKey(question: String, docs: [Document]) -> String {
        let docIds = docs.map { $0.id.uuidString }.sorted().joined(separator: "|")
        let normalizedQ = question.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedQ)|\(docIds)"
    }

    private func storeResponseCache(key: String, value: String) {
        let maxItems = 12
        responseCache[key] = value
        responseCacheOrder.removeAll { $0 == key }
        responseCacheOrder.append(key)
        if responseCacheOrder.count > maxItems {
            let overflow = responseCacheOrder.count - maxItems
            for _ in 0..<overflow {
                if let oldest = responseCacheOrder.first {
                    responseCacheOrder.removeFirst()
                    responseCache.removeValue(forKey: oldest)
                }
            }
        }
    }

    private func parseTitleListReply(_ reply: String, allDocs: [Document]) -> [Document] {
        let lower = reply.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "none" {
            return []
        }
        let lines = reply
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let titles = lines.compactMap { line -> String? in
            if line.lowercased().hasPrefix("titles:") {
                return nil
            }
            if line.hasPrefix("-") {
                return line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return nil
        }

        let matched = matchTitles(titles, allDocs: allDocs)
        if !matched.isEmpty { return matched }
        return matchTitles([reply], allDocs: allDocs)
    }

    private func buildNoDocumentPrompt(question: String) -> String {
        """
        You could not find a relevant document for the user's question. Respond briefly and ask the user to clarify or choose a document.

        Question: \(question)
        """
    }

    private func parseSingleTitleReply(_ reply: String, allDocs: [Document]) -> Document? {
        if let match = reply.range(of: "(?i)^title:\\s*", options: .regularExpression) {
            let picked = reply[match.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            return matchTitles([picked], allDocs: allDocs).first
        }
        return matchTitles([reply], allDocs: allDocs).first
    }

    private func matchTitles(_ titles: [String], allDocs: [Document]) -> [Document] {
        let lowered = titles.map { $0.lowercased() }
        return allDocs.filter { doc in
            lowered.contains(where: { doc.title.lowercased() == $0 })
        }
    }



    private func buildDocumentTitlesBlock(for docs: [Document], maxDocs: Int) -> String {
        let list = docs.prefix(maxDocs).map { "- \($0.title)" }
        return list.isEmpty ? "(No documents)" : list.joined(separator: "\n")
    }

    private func buildDocumentSummaryPrefixBlock(for docs: [Document], maxDocs: Int, maxChars: Int) -> String {
        let lines = docs.prefix(maxDocs).map { doc -> String in
            let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasSummary = !summary.isEmpty && summary != "Processing..." && summary != "Processing summary..."
            let prefixSource = hasSummary ? summary : doc.content
            let prefix = String(prefixSource.prefix(maxChars)).replacingOccurrences(of: "\n", with: " ")
            return "\(doc.title): \(prefix)"
        }
        return lines.isEmpty ? "(No summaries)" : lines.joined(separator: "\n")
    }

    private func buildDocumentFullSummariesBlock(for docs: [Document], maxDocs: Int) -> String {
        let lines = docs.prefix(maxDocs).map { doc -> String in
            let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let body = summary.isEmpty ? "(No summary)" : summary
            return "\(doc.title):\n\(body)"
        }
        return lines.isEmpty ? "(No summaries)" : lines.joined(separator: "\n\n")
    }

    private func buildDocumentOCRBlock(for doc: Document) -> String {
        let body = doc.content.trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty ? "(No OCR text)" : body
    }

    private func filterDocumentsByTitleMatch(question: String, docs: [Document]) -> [Document] {
        let tokens = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        guard !tokens.isEmpty else { return [] }

        func score(_ doc: Document) -> Int {
            let title = doc.title.lowercased()
            var s = 0
            for t in tokens {
                if title.contains(t) { s += 1 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return scored.map { $0.doc }
    }

    private func selectBestDocumentBySummary(question: String, docs: [Document]) -> Document? {
        let tokens = question
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        guard !tokens.isEmpty else { return docs.first }

        func score(_ doc: Document) -> Int {
            let summary = doc.summary.lowercased()
            var s = 0
            for t in tokens {
                if summary.contains(t) { s += 1 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .sorted { a, b in a.score > b.score }

        return scored.first?.doc
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

    private func selectRelevantDocumentsBySummaryPrefix(for query: String, in docs: [Document], maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func score(_ doc: Document) -> Int {
            let summary = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            if summary.isEmpty || summary == "Processing..." || summary == "Processing summary..." {
                return 0
            }
            let prefix = String(summary.prefix(100)).lowercased()
            var s = 0
            for t in tokens.prefix(8) {
                if prefix.contains(t) { s += 4 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func selectRelevantDocumentsByFullSummary(for query: String, in docs: [Document], maxDocs: Int) -> [(doc: Document, score: Int)] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 3 }

        func score(_ doc: Document) -> Int {
            let summary = doc.summary.lowercased()
            if summary.isEmpty || summary == "processing..." || summary == "processing summary..." {
                return 0
            }
            var s = 0
            if summary.contains(trimmed.lowercased()) { s += 10 }
            for t in tokens.prefix(8) {
                if summary.contains(t) { s += 3 }
            }
            return s
        }

        let scored = docs
            .map { (doc: $0, score: score($0)) }
            .filter { $0.score > 0 }
            .sorted { a, b in a.score > b.score }

        return Array(scored.prefix(maxDocs))
    }

    private func documentsWithReadySummaries(from docs: [Document]) -> [Document] {
        docs.filter { doc in
            let trimmed = doc.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            return !(trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary...")
        }
    }

    private func scopedDocuments() -> [Document] {
        if let folderId = selectedFolderId {
            let descendantIds = documentManager.descendantFolderIds(of: folderId)
            let folderIds = descendantIds.union([folderId])
            return documentManager.documents.filter { doc in
                guard let docFolderId = doc.folderId else { return false }
                return folderIds.contains(docFolderId)
            }
        }

        if !selectedDocIds.isEmpty {
            let idSet = Set(selectedDocIds)
            return documentManager.documents.filter { idSet.contains($0.id) }
        }

        return documentManager.documents
    }

    private var scopeLabel: String {
        if let folderId = selectedFolderId {
            return documentManager.folderName(for: folderId) ?? "Folder"
        }
        if !selectedDocIds.isEmpty {
            let count = selectedDocIds.count
            return count == 1 ? "1 Doc" : "\(count) Docs"
        }
        return "Scope"
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

struct ChatScopePickerView: View {
    @Binding var selectedDocIds: [UUID]
    @Binding var selectedFolderId: UUID?
    let folders: [DocumentFolder]
    let documents: [Document]

    @Environment(\.dismiss) private var dismiss
    @State private var showDocLimitAlert = false
    private struct FolderRowItem: Identifiable {
        let id: UUID
        let folder: DocumentFolder
        let level: Int
    }

    var body: some View {
        NavigationView {
            List {
                Section("Scope") {
                    Button {
                        selectedFolderId = nil
                        selectedDocIds = []
                    } label: {
                        HStack {
                            Text("All Documents")
                            Spacer()
                            if selectedFolderId == nil && selectedDocIds.isEmpty {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                            }
                        }
                    }
                }

                Section("Folder") {
                    let flattened = flattenedFolders()
                    if flattened.isEmpty {
                        Text("No folders")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(flattened) { row in
                            Button {
                                selectedFolderId = row.folder.id
                                selectedDocIds = []
                            } label: {
                                HStack {
                                    Text(row.folder.name)
                                        .padding(.leading, CGFloat(row.level) * 12)
                                    Spacer()
                                    if selectedFolderId == row.folder.id {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Documents (up to 3)") {
                    if documents.isEmpty {
                        Text("No documents")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(documents) { doc in
                            Button {
                                toggleDocSelection(doc.id)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(doc.title)
                                        if let folderName = folderName(for: doc.folderId) {
                                            Text(folderName)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer()
                                    if selectedDocIds.contains(doc.id) {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.accentColor)
                                    }
                                }
                            }
                            .disabled(selectedFolderId != nil)
                        }
                    }
                }
            }
            .navigationTitle("Chat Scope")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .alert("Up to 3 documents", isPresented: $showDocLimitAlert) {
                Button("OK") {}
            } message: {
                Text("Select up to three documents or choose a folder.")
            }
        }
    }

    private func sortedFolders(in parentId: UUID?) -> [DocumentFolder] {
        folders
            .filter { $0.parentId == parentId }
            .sorted { a, b in
                if a.sortOrder != b.sortOrder { return a.sortOrder < b.sortOrder }
                return a.dateCreated < b.dateCreated
            }
    }

    private func flattenedFolders() -> [FolderRowItem] {
        var out: [FolderRowItem] = []
        func walk(parentId: UUID?, level: Int) {
            for folder in sortedFolders(in: parentId) {
                out.append(FolderRowItem(id: folder.id, folder: folder, level: level))
                walk(parentId: folder.id, level: level + 1)
            }
        }
        walk(parentId: nil, level: 0)
        return out
    }

    private func folderName(for folderId: UUID?) -> String? {
        guard let folderId else { return nil }
        return folders.first(where: { $0.id == folderId })?.name
    }

    private func toggleDocSelection(_ docId: UUID) {
        if let idx = selectedDocIds.firstIndex(of: docId) {
            selectedDocIds.remove(at: idx)
            return
        }

        if selectedDocIds.count >= 3 {
            showDocLimitAlert = true
            return
        }

        selectedFolderId = nil
        selectedDocIds.append(docId)
    }
}

private func formatMarkdownText(_ text: String) -> AttributedString {
    var processedText = text

    // Convert markdown lists to bullet points
    processedText = processedText.replacingOccurrences(of: "* ", with: "• ")

    // Fix malformed bold markdown: **text* → **text**
    let malformedBoldRegex = try! NSRegularExpression(pattern: "\\*\\*([^*]+)\\*(?!\\*)", options: [])
    processedText = malformedBoldRegex.stringByReplacingMatches(in: processedText, options: [], range: NSRange(location: 0, length: processedText.count), withTemplate: "**$1**")

    // Support custom heading pattern: "## "
    let lines = processedText.split(separator: "\n", omittingEmptySubsequences: false)
    var output = AttributedString()

    for (idx, line) in lines.enumerated() {
        let lineText = String(line)
        if lineText.hasPrefix("## ") {
            let title = String(lineText.dropFirst(3))
            var heading = AttributedString(title)
            heading.font = .system(size: 17, weight: .semibold)
            output.append(heading)
        } else {
            do {
                var options = AttributedString.MarkdownParsingOptions()
                options.interpretedSyntax = .inlineOnlyPreservingWhitespace
                let attributedLine = try AttributedString(markdown: lineText, options: options)
                output.append(attributedLine)
            } catch {
                output.append(AttributedString(lineText))
            }
        }

        if idx < lines.count - 1 {
            output.append(AttributedString("\n"))
        }
    }

    return output
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
    @State private var showingSearchSheet = false
    @State private var previewController: CustomQLPreviewController?

    init(url: URL, document: Document? = nil, onAISummary: (() -> Void)? = nil) {
        self.url = url
        self.document = document
        self.onAISummary = onAISummary
    }

    var body: some View {
        ZStack {
            // Full screen PDF preview
            DocumentPreviewNavControllerView(
                url: url,
                title: document.map { splitDisplayTitle($0.title).base } ?? "Preview",
                onDismiss: { dismiss() },
                onControllerReady: { controller in
                    previewController = controller
                }
            )
            .ignoresSafeArea()

            // Top overlay with title and buttons
            VStack {
                HStack {
                    // Back button
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.leading, 20)
                    
                    Spacer()
                    
                    // Document title
                    Text(document.map { splitDisplayTitle($0.title).base } ?? "Preview")
                        .font(.headline)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .lineLimit(1)
                    
                    Spacer()
                    
                    // Search button
                    Button {
                        if document != nil {
                            showingSearchSheet = true
                        } else {
                            // Fallback to QuickLook search when no document context exists.
                            triggerSearch()
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.black.opacity(0.6))
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 20)
                }
                .padding(.top, 15)
                
                Spacer()
            }

            // Bottom buttons
            VStack {
                Spacer()
                HStack {
                    // Info button bottom-left
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
                    }
                    
                    Spacer()
                    
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
                    }
                }
                .padding(.bottom, 50)
            }
        }
        .sheet(isPresented: $showingInfo) {
            if let doc = document {
                DocumentInfoView(document: doc, fileURL: url)
            }
        }
        .sheet(isPresented: $showingSearchSheet) {
            if let doc = document {
                SearchInDocumentSheet(document: doc)
            }
        }
    }
    
    private func triggerSearch() {
        // Directly trigger search on the preview controller if available
        previewController?.triggerSearchDirectly()
    }

}

struct SearchInDocumentSheet: View {
    let document: Document
    @Environment(\.dismiss) private var dismiss
    @State private var query: String = ""
    @State private var results: [String] = []

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                TextField("Search text", text: $query)
                    .textInputAutocapitalization(.none)
                    .disableAutocorrection(true)
                    .padding(12)
                    .background(Color(.tertiarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.horizontal)

                if document.content.isEmpty {
                    Text("No text content available for this document.")
                        .foregroundColor(.secondary)
                        .padding()
                } else if results.isEmpty && !query.isEmpty {
                    Text("No matches found.")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    List(results, id: \.self) { snippet in
                        Text(snippet)
                            .font(.body)
                            .foregroundColor(.primary)
                    }
                    .listStyle(.plain)
                }

                Spacer()
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onChange(of: query) { _ in
                results = searchSnippets(in: document.content, query: query)
            }
            .onAppear {
                results = searchSnippets(in: document.content, query: query)
            }
        }
    }

    private func searchSnippets(in text: String, query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let lowerText = text.lowercased()
        let tokens = trimmed
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count >= 2 }

        let searchTerms = tokens.isEmpty ? [trimmed.lowercased()] : tokens
        let window = 80
        var snippets: [String] = []

        for term in searchTerms.prefix(4) {
            var searchStart = lowerText.startIndex
            while snippets.count < 10,
                  let range = lowerText.range(of: term, range: searchStart..<lowerText.endIndex) {
                let start = lowerText.index(range.lowerBound, offsetBy: -window, limitedBy: lowerText.startIndex) ?? lowerText.startIndex
                let end = lowerText.index(range.upperBound, offsetBy: window, limitedBy: lowerText.endIndex) ?? lowerText.endIndex
                let snippet = String(text[start..<end]).replacingOccurrences(of: "\n", with: " ")
                snippets.append(snippet)
                searchStart = range.upperBound
            }
            if snippets.count >= 10 { break }
        }

        let unique = Array(NSOrderedSet(array: snippets)) as? [String] ?? snippets
        return Array(unique.prefix(10))
    }
}

struct DocumentPreviewNavControllerView: UIViewControllerRepresentable {
    let url: URL
    let title: String
    let onDismiss: () -> Void
    let onControllerReady: (CustomQLPreviewController) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url, onDismiss: onDismiss)
    }

    func makeUIViewController(context: Context) -> UIViewController {
        let previewController = CustomQLPreviewController()
        previewController.dataSource = context.coordinator
        previewController.delegate = context.coordinator
        
        // Notify that controller is ready
        DispatchQueue.main.async {
            self.onControllerReady(previewController)
        }
        
        return previewController
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {
        // No-op
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource, QLPreviewControllerDelegate {
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
        
        // Allow search but disable editing modes
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: QLPreviewItem) -> QLPreviewItemEditingMode {
            return .disabled
        }
        
        // Block external app opening but allow internal actions like search
        func previewController(_ controller: QLPreviewController, shouldOpen url: URL, for item: QLPreviewItem) -> Bool {
            return false
        }
        
        // Remove specific unwanted toolbar items but allow search
        func previewController(_ controller: QLPreviewController, frameFor item: QLPreviewItem, inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>) -> CGRect {
            return CGRect.zero
        }

        @objc func handleBack() {
            onDismiss()
        }
    }
}

// Custom QLPreviewController to remove unwanted UI elements
class CustomQLPreviewController: QLPreviewController {
    
    func triggerSearchDirectly() {
        // Use the standard iOS search functionality
        if #available(iOS 16.0, *) {
            becomeFirstResponder()
            let searchCommand = #selector(UIResponder.find(_:))
            if canPerformAction(searchCommand, withSender: self) {
                perform(searchCommand, with: self)
            }
        } else {
            // For iOS < 16, try to find and show search interface
            DispatchQueue.main.async {
                self.findAndActivateSearch()
            }
        }
    }
    
    private func findAndActivateSearch() {
        // Look for search functionality in the view hierarchy
        func findSearchController(in view: UIView) -> UISearchController? {
            if let searchController = view as? UISearchController {
                return searchController
            }
            for subview in view.subviews {
                if let found = findSearchController(in: subview) {
                    return found
                }
            }
            return nil
        }
        
        // Try to activate search through menu system
        let menuController = UIMenuController.shared
        menuController.showMenu(from: self.view, rect: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        // Hide navigation bar and toolbar
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        
        // Force hide all bars and remove unwanted buttons
        navigationController?.setNavigationBarHidden(true, animated: false)
        navigationController?.setToolbarHidden(true, animated: false)
        
        // Remove share button and action button
        navigationItem.rightBarButtonItem = nil
        navigationItem.leftBarButtonItem = nil
        toolbarItems = []
        
        // Remove the dropdown button by searching through subviews
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.removeUnwantedButtons()
        }
    }
    
    private func removeUnwantedButtons() {
        // Recursively search for and hide share/action buttons
        func hideShareButtons(in view: UIView) {
            for subview in view.subviews {
                if let button = subview as? UIButton {
                    // Hide share/action buttons but keep search
                    if button.accessibilityIdentifier?.contains("share") == true ||
                       button.accessibilityIdentifier?.contains("action") == true {
                        button.isHidden = true
                    }
                }
                hideShareButtons(in: subview)
            }
        }
        hideShareButtons(in: self.view)
    }
    
    override var canBecomeFirstResponder: Bool {
        return true
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
    @State private var hasCanceledCurrent = false
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var documentManager: DocumentManager

    private var currentDoc: Document {
        documentManager.getDocument(by: document.id) ?? document
    }

    private var supportsAISummary: Bool {
        document.type != .image
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
                            if supportsAISummary {
                                if isGeneratingSummary {
                                    Button("Cancel") { cancelSummary() }
                                } else if hasUsableSummary {
                                    Button("Regenerate") { generateAISummary(force: true) }
                                } else {
                                    Button("Generate") { generateAISummary(force: false) }
                                }
                            }
                        }
                        
                        if !supportsAISummary {
                            Text("Summaries are unavailable for image files.")
                                .foregroundColor(.secondary)
                                .padding(.vertical)
                        } else if isGeneratingSummary {
                            HStack {
                                ProgressView()
                                    .scaleEffect(0.8)
                                Text("Generating summary...")
                                    .foregroundColor(.secondary)
                            }
                            .padding(.vertical)
                        } else if summary.isEmpty {
                            Text("No summary.")
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
            self.isGeneratingSummary = supportsAISummary && isSummaryPlaceholder(self.summary)
        }
        .onChange(of: currentDoc.summary) { newValue in
            if summary != newValue {
                summary = newValue
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SummaryGenerationStatus"))) { notification in
            guard let userInfo = notification.userInfo,
                  let idString = userInfo["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }
            guard docId == document.id else { return }
            if let active = userInfo["isActive"] as? Bool {
                if active {
                    if !hasCanceledCurrent {
                        isGeneratingSummary = true
                    }
                } else {
                    isGeneratingSummary = false
                    hasCanceledCurrent = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("CancelDocumentSummary"))) { notification in
            guard let idString = notification.userInfo?["documentId"] as? String,
                  let docId = UUID(uuidString: idString) else { return }
            guard docId == document.id else { return }
            hasCanceledCurrent = true
            isGeneratingSummary = false
        }
    }

    private var hasUsableSummary: Bool {
        !isSummaryPlaceholder(summary)
    }

    private func isSummaryPlaceholder(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "Processing..." || trimmed == "Processing summary..."
    }
    
    private func generateAISummary(force: Bool) {
        print("🧠 DocumentSummaryView: Requesting AI summary for '\(document.title)'")
        isGeneratingSummary = true
        documentManager.generateSummary(for: currentDoc, force: force)
    }

    private func cancelSummary() {
        hasCanceledCurrent = true
        isGeneratingSummary = false
        NotificationCenter.default.post(
            name: NSNotification.Name("CancelDocumentSummary"),
            object: nil,
            userInfo: ["documentId": document.id.uuidString]
        )
    }
}

// MARK: - Conversion View
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
        case html = "HTML"
        
        var fileExtension: String {
            switch self {
            case .pdf: return "pdf"
            case .docx: return "docx"
            case .txt: return "txt"
            case .image: return "jpg"
            case .html: return "html"
            }
        }
        
        var systemImage: String {
            switch self {
            case .pdf: return "doc.fill"
            case .docx: return "doc.text.fill"
            case .txt: return "doc.plaintext.fill"
            case .image: return "photo.fill"
            case .html: return "globe.fill"
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
                
            case (.pdf, .docx), (.txt, .docx):
                outputData = convertToDocx(content: latestDocument.content, title: latestDocument.title)
                
            case (.pdf, .html), (.docx, .html), (.txt, .html):
                outputData = convertToHTML(content: latestDocument.content, title: latestDocument.title)
                
            case (.pdf, .image), (.docx, .image), (.txt, .image):
                outputData = convertToImage(content: latestDocument.content)
                
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
    
    private func convertToHTML(content: String, title: String) -> Data? {
        let htmlContent = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>\(title)</title>
            <meta charset="UTF-8">
            <style>
                body { font-family: Arial, sans-serif; margin: 40px; line-height: 1.6; }
                h1 { color: #333; }
            </style>
        </head>
        <body>
            <h1>\(title)</h1>
            <div>\(content.replacingOccurrences(of: "\n", with: "<br>"))</div>
        </body>
        </html>
        """
        return htmlContent.data(using: .utf8)
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
