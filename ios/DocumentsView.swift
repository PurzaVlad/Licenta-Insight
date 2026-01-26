import SwiftUI
import UIKit
import Vision
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import Foundation
import AVFoundation

private enum DocumentLayoutMode {
    case list
    case grid
}

private enum ScannerMode {
    case document
    case simple
}
struct DocumentsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let onOpenPreview: (Document, URL) -> Void
    let onShowSummary: (Document) -> Void
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
    @State private var isOpeningPreview = false
    @State private var activeFolder: DocumentFolder?
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

    @State private var showingZipExportSheet = false

    @State private var isSelectionMode = false
    @State private var selectedDocumentIds: Set<UUID> = []
    @State private var selectedFolderIds: Set<UUID> = []
    @State private var showingBulkDeleteDialog = false
    @State private var showingBulkMoveSheet = false
    @State private var showingNameSearch = false
    @State private var nameSearchText = ""

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
                                isSelected: selectedFolderIds.contains(folder.id),
                                isSelectionMode: isSelectionMode,
                                onSelectToggle: { toggleFolderSelection(folder.id) },
                                onLongPress: { beginSelection(folderId: folder.id) },
                                onOpen: { activeFolder = folder },
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
                        }
                    }
                }

                ForEach(rootDocs, id: \.id) { document in
                    DocumentRowView(
                        document: document,
                        isSelected: selectedDocumentIds.contains(document.id),
                        isSelectionMode: isSelectionMode,
                        onSelectToggle: { toggleDocumentSelection(document.id) },
                        onLongPress: { beginSelection(documentId: document.id) },
                        onOpen: { openDocumentPreview(document: document) },
                        onRename: { renameDocument(document) },
                        onMoveToFolder: {
                            documentToMove = document
                        },
                        onDelete: { deleteDocument(document) },
                        onConvert: { convertDocument(document) },
                        onShare: { shareDocuments([document]) }
                    )
                    .listRowBackground(Color.clear)
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
                                isSelected: selectedFolderIds.contains(folder.id),
                                isSelectionMode: isSelectionMode,
                                onSelectToggle: { toggleFolderSelection(folder.id) },
                                onLongPress: { beginSelection(folderId: folder.id) },
                                onOpen: { activeFolder = folder },
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
                    }

                    ForEach(rootDocs, id: \.id) { document in
                        DocumentGridItemView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleDocumentSelection(document.id) },
                            onLongPress: { beginSelection(documentId: document.id) },
                            onOpen: { openDocumentPreview(document: document) },
                            onRename: { renameDocument(document) },
                        onMoveToFolder: {
                            documentToMove = document
                        },
                            onDelete: { deleteDocument(document) },
                            onConvert: { convertDocument(document) },
                            onShare: { shareDocuments([document]) }
                        )
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

    private var isShowingActiveFolder: Binding<Bool> {
        Binding(
            get: { activeFolder != nil },
            set: { isActive in
                if !isActive {
                    activeFolder = nil
                }
            }
        )
    }

    @ViewBuilder
    private var activeFolderDestinationView: some View {
        if let folder = activeFolder {
            FolderDocumentsView(folder: folder, onOpenDocument: openDocumentPreview)
                .environmentObject(documentManager)
        } else {
            EmptyView()
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

            NavigationLink(
                destination: activeFolderDestinationView,
                isActive: isShowingActiveFolder
            ) {
                EmptyView()
            }
            .hidden()
        }
    }
    
    var body: some View {
        NavigationView {
            documentsMainStack
                .navigationBarTitleDisplayMode(.inline)
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        nameSearchText = ""
                        showingNameSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 52, height: 52)
                            .background(Color.accentColor)
                            .clipShape(Circle())
                            .shadow(radius: 4, y: 2)
                    }
                    .padding(.trailing, 20)
                    .padding(.bottom, 12)
                }
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Text(" Documents ")
                            .font(.headline)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    ToolbarItemGroup(placement: .navigationBarTrailing) {
                        if isSelectionMode {
                            Menu {
                                Button("Share Selected") {
                                    shareSelectedDocuments()
                                }
                                Button("Delete Selected", role: .destructive) {
                                    showingBulkDeleteDialog = true
                                }
                                Button("Move Selected") {
                                    showingBulkMoveSheet = true
                                }
                                Button("Create Zip") {
                                    showingZipExportSheet = true
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }

                            Button("Done") {
                                clearSelection()
                            }
                        } else {
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

                                Button("Create Zip") {
                                    showingZipExportSheet = true
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
        .confirmationDialog("Delete Selected Items", isPresented: $showingBulkDeleteDialog) {
            Button("Delete", role: .destructive) {
                deleteSelectedItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all selected items and their contents.")
        }
        .sheet(isPresented: $showingBulkMoveSheet) {
            BulkMoveSheet(
                folders: documentManager.folders,
                onSelectParent: { parentId in
                    moveSelectedItems(to: parentId)
                    showingBulkMoveSheet = false
                },
                onCancel: {
                    showingBulkMoveSheet = false
                }
            )
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
        .sheet(isPresented: $showingZipExportSheet) {
            ZipExportView(
                preselectedDocumentIds: selectedDocumentIds,
                preselectedFolderIds: selectedFolderIds
            )
                .environmentObject(documentManager)
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
        .sheet(isPresented: $showingNameSearch) {
            DocumentNameSearchSheet(
                query: $nameSearchText,
                documents: documentManager.documents,
                onSelect: { doc in
                    showingNameSearch = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        openDocumentPreview(document: doc)
                    }
                },
                onClose: {
                    showingNameSearch = false
                }
            )
        }
    }

    
    
    // Menu actions
    private func renameDocument(_ document: Document) {
        documentToRename = document
        renameText = splitDisplayTitle(document.title).base
        showingRenameDialog = true
    }

    private func beginSelection(documentId: UUID? = nil, folderId: UUID? = nil) {
        if !isSelectionMode {
            isSelectionMode = true
        }
        if let documentId {
            toggleDocumentSelection(documentId)
        }
        if let folderId {
            toggleFolderSelection(folderId)
        }
    }

    private func toggleDocumentSelection(_ id: UUID) {
        if selectedDocumentIds.contains(id) {
            selectedDocumentIds.remove(id)
        } else {
            selectedDocumentIds.insert(id)
        }
    }

    private func toggleFolderSelection(_ id: UUID) {
        if selectedFolderIds.contains(id) {
            selectedFolderIds.remove(id)
        } else {
            selectedFolderIds.insert(id)
        }
    }

    private func clearSelection() {
        isSelectionMode = false
        selectedDocumentIds.removeAll()
        selectedFolderIds.removeAll()
    }

    private func deleteSelectedItems() {
        let docIds = selectedDocumentIds
        let folderIds = selectedFolderIds

        for id in docIds {
            if let doc = documentManager.documents.first(where: { $0.id == id }) {
                documentManager.deleteDocument(doc)
            }
        }

        for folderId in folderIds {
            documentManager.deleteFolder(folderId: folderId, mode: .deleteAllItems)
        }

        clearSelection()
    }

    private func moveSelectedItems(to parentId: UUID?) {
        let docIds = selectedDocumentIds
        let folderIds = selectedFolderIds

        for id in docIds {
            documentManager.moveDocument(documentId: id, toFolder: parentId)
        }

        for folderId in folderIds {
            documentManager.moveFolder(folderId: folderId, toParent: parentId)
        }

        clearSelection()
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
                        let current = self.documentManager.getDocument(by: document.id) ?? document
                        let updatedDocument = Document(
                            id: document.id,
                            title: document.title, // Keep original name
                            content: document.content,
                            summary: document.summary,
                            ocrPages: document.ocrPages,
                            category: cat,
                            keywordsResume: kw,
                            dateCreated: document.dateCreated,
                            folderId: current.folderId,
                            sortOrder: current.sortOrder,
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
        func presentScanner() {
            // Delay to avoid presenting from a context menu hosting controller.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                showingScanner = true
            }
        }
        if !VNDocumentCameraViewController.isSupported {
            scannerMode = .simple
            presentScanner()
            return
        }

        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            scannerMode = .document
            presentScanner()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        scannerMode = .document
                        presentScanner()
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
            title: titleCaseFromOCR(text),
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

        let namingSeed = extractedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? firstPageText : extractedText

        // Use AI to suggest document name based on headings + first paragraph
        if !namingSeed.isEmpty {
            print("Using AI to generate document name from OCR text")
            generateAIDocumentName(from: namingSeed)
        } else {
            print("OCR extraction failed or returned no text, using default name")
            suggestedName = titleCaseFromOCR(firstPageText)
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        }
    }

    private func generateAIDocumentName(from text: String) {
        let base = extractHeadingsAndFirstParagraph(from: text)
        let seed = base.isEmpty ? text : base
        let candidates = extractTitleCandidates(from: seed)
        let fallback = candidates.first ?? titleCaseFromOCR(text)

        let prompt = """
            Choose the best candidate and output a 1–4 word Title Case title. No punctuation. Output only the title.

            CANDIDATES:
            \(candidates.map { "- \($0)" }.joined(separator: "\n"))
            """

        print("🏷️ DocumentsView: Generating AI document name from OCR text")
        // Ensure the JS bridge routes this as a naming request with no chat history.
        EdgeAI.shared?.generate("<<<NO_HISTORY>>><<<NAME_REQUEST>>>" + prompt, resolver: { result in
            print("🏷️ DocumentsView: Got name suggestion result: \(String(describing: result))")
            DispatchQueue.main.async {
                if let result = result as? String, !result.isEmpty {
                    let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = normalizeSuggestedTitle(clean, fallback: fallback)
                    self.suggestedName = normalized.isEmpty ? fallback : normalized
                } else {
                    self.suggestedName = fallback
                }
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        }, rejecter: { code, message, error in
            print("❌ DocumentsView: Name generation failed - Code: \(code ?? "nil"), Message: \(message ?? "nil")")
            DispatchQueue.main.async {
                self.suggestedName = fallback
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        })
    }

    private func extractTitleCandidates(from text: String) -> [String] {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var scored: [(String, Double)] = []
        for (idx, line) in lines.enumerated() {
            if isMetadataLine(line) { continue }
            let score = scoreTitleLine(line, index: idx)
            if score > 0 {
                scored.append((line, score))
            }
        }

        let top = scored
            .sorted { $0.1 > $1.1 }
            .prefix(5)
            .map { normalizeTitleCandidate($0.0, maxWords: 16) }
            .filter { !$0.isEmpty }

        return top.isEmpty ? [normalizeTitleCandidate(text, maxWords: 8)] : top
    }

    private func isMetadataLine(_ line: String) -> Bool {
        let lower = line.lowercased()
        let denylist = [
            "abstract", "keywords", "references", "acknowledg", "copyright",
            "doi", "issn", "isbn", "volume", "vol.", "issue", "no.", "page",
            "journal", "proceedings", "conference", "university", "department",
            "faculty", "publisher", "press", "editor", "address", "telephone", "phone", "fax"
        ]
        if lower.contains("http://") || lower.contains("https://") || lower.contains("www.") { return true }
        if lower.range(of: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}", options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if lower.range(of: "\\bdoi\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bissn\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bpage\\s+\\d+\\b", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bvol\\.?\\s*\\d+", options: .regularExpression) != nil { return true }
        if lower.range(of: "\\bissue\\s*\\d+", options: .regularExpression) != nil { return true }
        if denylist.contains(where: { lower.contains($0) }) { return true }
        return false
    }

    private func scoreTitleLine(_ line: String, index: Int) -> Double {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count < 4 { return -1 }
        if trimmed.count > 120 { return -1 }

        let words = trimmed.split { $0.isWhitespace }
        let wordCount = words.count
        let letters = trimmed.filter { $0.isLetter }.count
        let digits = trimmed.filter { $0.isNumber }.count
        let total = max(1, trimmed.count)

        var score: Double = 0
        score += Double(max(0, 5 - index)) * 0.35 // top-of-page boost
        if wordCount >= 4 && wordCount <= 16 { score += 2.0 }
        if wordCount <= 2 { score -= 1.5 }
        if wordCount > 20 { score -= 1.0 }

        let letterRatio = Double(letters) / Double(total)
        let digitRatio = Double(digits) / Double(total)
        if letterRatio >= 0.7 { score += 1.0 }
        if letterRatio < 0.4 { score -= 1.0 }
        if digitRatio > 0.3 { score -= 1.5 }

        let isAllCaps = trimmed == trimmed.uppercased() && letterRatio > 0.5
        let isTitleCase = words.allSatisfy { word in
            guard let first = word.first else { return false }
            return String(first) == String(first).uppercased()
        }
        if isTitleCase { score += 0.8 }
        if isAllCaps { score += 0.5 }

        return score
    }

    private func normalizeTitleCandidate(_ input: String, maxWords: Int) -> String {
        let firstLine = input.components(separatedBy: .newlines).first ?? ""
        let stripped = firstLine
            .replacingOccurrences(of: "^[\\s•\\-–—*]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\"'“”`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if stripped.isEmpty { return "" }
        return stripped.split(separator: " ").prefix(maxWords).joined(separator: " ")
    }

    private func normalizeSuggestedTitle(_ raw: String, fallback: String) -> String {
        let firstLine = raw.components(separatedBy: .newlines).first ?? ""
        let stripped = firstLine
            .replacingOccurrences(of: "^[\\s•\\-–—*]+", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[\"'“”`]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "[^A-Za-z0-9\\s]", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let words = stripped.split(separator: " ").map(String.init)
        var seen = Set<String>()
        var unique: [String] = []
        for word in words {
            let key = word.lowercased()
            if seen.contains(key) { continue }
            seen.insert(key)
            unique.append(word)
            if unique.count == 4 { break }
        }

        let cleaned = unique.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return enforceTitleCase(normalizeTitleCandidate(fallback, maxWords: 4)) }
        if isMetadataLine(cleaned) { return enforceTitleCase(normalizeTitleCandidate(fallback, maxWords: 4)) }
        return enforceTitleCase(cleaned)
    }

    private func buildNamingSeed(from pages: [OCRPage], fallback: String) -> String {
        let structured = buildStructuredText(from: pages, includePageLabels: false)
        let source = structured.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback : structured
        let prefix = extractHeadingsAndFirstParagraph(from: source)
        return String((prefix.isEmpty ? source : prefix).prefix(800))
    }

    private func extractHeadingsAndFirstParagraph(from text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let paragraphs = trimmed
            .replacingOccurrences(of: "\n\n\n+", with: "\n\n", options: .regularExpression)
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else { return trimmed }
        if paragraphs.count == 1 { return paragraphs[0] }
        return paragraphs[0] + "\n\n" + paragraphs[1]
    }

    private func titleCaseFromOCR(_ text: String) -> String {
        let snippet = String(text.prefix(300))
        return enforceTitleCase(snippet)
    }

    private func enforceTitleCase(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let normalized = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        let words = normalized.lowercased().split(separator: " ").map(String.init)
        let cased = words.map { word -> String in
            guard let first = word.first else { return "" }
            return String(first).uppercased() + word.dropFirst()
        }
        return cased.joined()
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
            DispatchQueue.main.async {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    self.onOpenPreview(document, url)
                    self.isOpeningPreview = false
                }
            }
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
        case .scanned:
            return "pdf"
        case .image:
            return "jpg"
        case .zip:
            return "zip"
        }
    }

    private func shareSelectedDocuments() {
        let docs = documentManager.documents.filter { selectedDocumentIds.contains($0.id) }
        shareDocuments(docs)
    }

    private func shareDocuments(_ documents: [Document]) {
        let urls = documents.compactMap { makeShareURL(for: $0) }
        guard !urls.isEmpty else { return }
        presentShare(urls: urls)
    }

    private func makeShareURL(for document: Document) -> URL? {
        let parts = splitDisplayTitle(document.title)
        let safeBase = parts.base.replacingOccurrences(of: "/", with: "-")
        let base = safeBase.isEmpty ? "Document" : safeBase
        let ext = parts.ext.isEmpty ? getFileExtension(for: document.type) : parts.ext
        let filename = parts.ext.isEmpty ? "\(base).\(ext)" : "\(base).\(parts.ext)"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)

        if let data = document.originalFileData ?? document.pdfData ?? document.imageData?.first {
            try? data.write(to: tempURL)
            return tempURL
        }

        if !document.content.isEmpty, let data = document.content.data(using: .utf8) {
            try? data.write(to: tempURL)
            return tempURL
        }

        return nil
    }

    private func presentShare(urls: [URL]) {
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(activity, animated: true)
    }
}

struct DocumentRowView: View {
    let document: Document
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    let onLongPress: () -> Void

    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void
    let onShare: () -> Void
    
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

            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .frame(width: 28, height: 28)
            } else {
                Menu {
                    Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelectionMode {
                onSelectToggle()
            } else {
                onOpen()
            }
        }
        .simultaneousGesture(
            LongPressGesture().onEnded { _ in
                onLongPress()
            }
        )
    }
    
}

struct DocumentGridItemView: View {
    let document: Document
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    let onLongPress: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void
    let onShare: () -> Void

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
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                } else {
                    Menu {
                        Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
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
            if isSelectionMode {
                onSelectToggle()
            } else {
                onOpen()
            }
        }
        .simultaneousGesture(
            LongPressGesture().onEnded { _ in
                onLongPress()
            }
        )
    }
}

struct FolderRowView: View {
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    let onLongPress: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .trailing) {
            Button(action: {
                if isSelectionMode {
                    onSelectToggle()
                } else {
                    onOpen()
                }
            }) {
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

            if isSelectionMode {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .secondary)
                    .frame(width: 28, height: 28)
            } else {
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
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .highPriorityGesture(
            LongPressGesture().onEnded { _ in
                onLongPress()
            }
        )
    }
}

struct FolderGridItemView: View {
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    let onLongPress: () -> Void
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
                if isSelectionMode {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(isSelected ? .blue : .secondary)
                        .padding(.top, 6)
                        .padding(.trailing, 6)
                } else {
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
            if isSelectionMode {
                onSelectToggle()
            } else {
                onOpen()
            }
        }
        .highPriorityGesture(
            LongPressGesture().onEnded { _ in
                onLongPress()
            }
        )
    }
}

struct FolderDocumentsView: View {
    let folder: DocumentFolder
    let onOpenDocument: (Document) -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    private var layoutMode: DocumentLayoutMode { documentManager.prefersGridLayout ? .grid : .list }
    @State private var documentToMove: Document?

    @State private var activeSubfolder: DocumentFolder?

    @State private var isSelectionMode = false
    @State private var selectedDocumentIds: Set<UUID> = []
    @State private var selectedFolderIds: Set<UUID> = []
    @State private var showingBulkDeleteDialog = false
    @State private var showingBulkMoveSheet = false
    @State private var showingZipExportSheet = false

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

    

    private var isShowingActiveSubfolder: Binding<Bool> {
        Binding(
            get: { activeSubfolder != nil },
            set: { isActive in
                if !isActive {
                    activeSubfolder = nil
                }
            }
        )
    }

    @ViewBuilder
    private var activeSubfolderDestinationView: some View {
        if let sub = activeSubfolder {
            FolderDocumentsView(folder: sub, onOpenDocument: onOpenDocument)
                .environmentObject(documentManager)
        } else {
            EmptyView()
        }
    }

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
                                isSelected: selectedFolderIds.contains(sub.id),
                                isSelectionMode: isSelectionMode,
                                onSelectToggle: { toggleFolderSelection(sub.id) },
                                onLongPress: { beginSelection(folderId: sub.id) },
                                onOpen: { activeSubfolder = sub },
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
                        }
                        }
                    }

                    ForEach(docs, id: \ .id) { document in
                        DocumentRowView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleDocumentSelection(document.id) },
                            onLongPress: { beginSelection(documentId: document.id) },
                            onOpen: { onOpenDocument(document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
                            },
                            onDelete: { documentManager.deleteDocument(document) },
                            onConvert: { },
                            onShare: { shareDocuments([document]) }
                        )
                        .listRowBackground(Color.clear)
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
                                isSelected: selectedFolderIds.contains(sub.id),
                                isSelectionMode: isSelectionMode,
                                onSelectToggle: { toggleFolderSelection(sub.id) },
                                onLongPress: { beginSelection(folderId: sub.id) },
                                onOpen: { activeSubfolder = sub },
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
                        }

                        ForEach(docs, id: \ .id) { document in
                        DocumentGridItemView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleDocumentSelection(document.id) },
                            onLongPress: { beginSelection(documentId: document.id) },
                            onOpen: { onOpenDocument(document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
                            },
                                onDelete: { documentManager.deleteDocument(document) },
                                onConvert: { },
                                onShare: { shareDocuments([document]) }
                            )
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 12)
                    .padding(.bottom, 24)
                }
            }
        }
        .overlay(
            NavigationLink(
                destination: activeSubfolderDestinationView,
                isActive: isShowingActiveSubfolder
            ) {
                EmptyView()
            }
            .hidden()
        )
        .navigationTitle(folder.name)
        .toolbar {
            ToolbarItemGroup(placement: .navigationBarTrailing) {
                if isSelectionMode {
                    Menu {
                        Button("Share Selected") {
                            shareSelectedDocuments()
                        }
                        Button("Delete Selected", role: .destructive) {
                            showingBulkDeleteDialog = true
                        }
                        Button("Move Selected") {
                            showingBulkMoveSheet = true
                        }
                        Button("Create Zip") {
                            showingZipExportSheet = true
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }

                    Button("Done") {
                        clearSelection()
                    }
                } else {
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
        .confirmationDialog("Delete Selected Items", isPresented: $showingBulkDeleteDialog) {
            Button("Delete", role: .destructive) {
                deleteSelectedItems()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will delete all selected items and their contents.")
        }
        .sheet(isPresented: $showingBulkMoveSheet) {
            BulkMoveSheet(
                folders: documentManager.folders,
                onSelectParent: { parentId in
                    moveSelectedItems(to: parentId)
                    showingBulkMoveSheet = false
                },
                onCancel: {
                    showingBulkMoveSheet = false
                }
            )
        }
        .sheet(isPresented: $showingZipExportSheet) {
            ZipExportView(
                preselectedDocumentIds: selectedDocumentIds,
                preselectedFolderIds: selectedFolderIds
            )
            .environmentObject(documentManager)
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

    private func renameDocument(_ document: Document) {
        documentToRename = document
        renameText = splitDisplayTitle(document.title).base
        showingRenameDialog = true
    }

    private func beginSelection(documentId: UUID? = nil, folderId: UUID? = nil) {
        if !isSelectionMode {
            isSelectionMode = true
        }
        if let documentId {
            toggleDocumentSelection(documentId)
        }
        if let folderId {
            toggleFolderSelection(folderId)
        }
    }

    private func toggleDocumentSelection(_ id: UUID) {
        if selectedDocumentIds.contains(id) {
            selectedDocumentIds.remove(id)
        } else {
            selectedDocumentIds.insert(id)
        }
    }

    private func toggleFolderSelection(_ id: UUID) {
        if selectedFolderIds.contains(id) {
            selectedFolderIds.remove(id)
        } else {
            selectedFolderIds.insert(id)
        }
    }

    private func clearSelection() {
        isSelectionMode = false
        selectedDocumentIds.removeAll()
        selectedFolderIds.removeAll()
    }

    private func deleteSelectedItems() {
        let docIds = selectedDocumentIds
        let folderIds = selectedFolderIds

        for id in docIds {
            if let doc = documentManager.documents.first(where: { $0.id == id }) {
                documentManager.deleteDocument(doc)
            }
        }

        for folderId in folderIds {
            documentManager.deleteFolder(folderId: folderId, mode: .deleteAllItems)
        }

        clearSelection()
    }

    private func moveSelectedItems(to parentId: UUID?) {
        let docIds = selectedDocumentIds
        let folderIds = selectedFolderIds

        for id in docIds {
            documentManager.moveDocument(documentId: id, toFolder: parentId)
        }

        for folderId in folderIds {
            documentManager.moveFolder(folderId: folderId, toParent: parentId)
        }

        clearSelection()
    }

    private func shareSelectedDocuments() {
        let docs = documentManager.documents.filter { selectedDocumentIds.contains($0.id) }
        shareDocuments(docs)
    }

    private func shareDocuments(_ documents: [Document]) {
        let urls = documents.compactMap { makeShareURL(for: $0) }
        guard !urls.isEmpty else { return }
        presentShare(urls: urls)
    }

    private func makeShareURL(for document: Document) -> URL? {
        let parts = splitDisplayTitle(document.title)
        let safeBase = parts.base.replacingOccurrences(of: "/", with: "-")
        let base = safeBase.isEmpty ? "Document" : safeBase
        let ext = parts.ext.isEmpty ? fileExtension(for: document.type) : parts.ext
        let filename = parts.ext.isEmpty ? "\(base).\(ext)" : "\(base).\(parts.ext)"
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(filename)

        if let data = document.originalFileData ?? document.pdfData ?? document.imageData?.first {
            try? data.write(to: tempURL)
            return tempURL
        }

        if !document.content.isEmpty, let data = document.content.data(using: .utf8) {
            try? data.write(to: tempURL)
            return tempURL
        }

        return nil
    }

    private func presentShare(urls: [URL]) {
        let activity = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              let window = scene.windows.first,
              let root = window.rootViewController else { return }
        if let popover = activity.popoverPresentationController {
            popover.sourceView = window
            popover.sourceRect = CGRect(x: window.bounds.midX, y: window.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        root.present(activity, animated: true)
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

struct DocumentNameSearchSheet: View {
    @Binding var query: String
    let documents: [Document]
    let onSelect: (Document) -> Void
    let onClose: () -> Void

    private var matches: [Document] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let q = trimmed.lowercased()
        return documents.filter { doc in
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
            List {
                if matches.isEmpty {
                } else {
                    ForEach(matches) { doc in
                        Button {
                            onSelect(doc)
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
            .navigationTitle("Find Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Close") { onClose() }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Enter document name")
        }
    }
}

struct BulkMoveSheet: View {
    let folders: [DocumentFolder]
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
                    }
                }

                ForEach(folders.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { dest in
                    Button {
                        onSelectParent(dest.id)
                    } label: {
                        HStack {
                            Text(dest.name)
                            Spacer()
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
