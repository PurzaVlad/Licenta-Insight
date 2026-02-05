import SwiftUI
import UIKit
import Vision
import VisionKit
import UniformTypeIdentifiers
import PDFKit
import QuickLookThumbnailing
import Foundation
import AVFoundation

// MARK: - Drag & Drop modifiers for iOS 16+
extension View {
    @ViewBuilder
    func folderDraggable(_ id: UUID) -> some View {
        if #available(iOS 16.0, *) {
            self.draggable(id.uuidString)
        } else {
            self
        }
    }
    
    @ViewBuilder
    func folderDropDestination(
        folderId: UUID,
        documentManager: DocumentManager,
        dropTargetedFolderId: Binding<UUID?>
    ) -> some View {
        if #available(iOS 16.0, *) {
            self.dropDestination(for: String.self) { items, _ in
                guard let uuidString = items.first, let id = UUID(uuidString: uuidString) else { return false }
                if id == folderId { return false }
                if documentManager.documents.contains(where: { $0.id == id }) {
                    documentManager.moveDocument(documentId: id, toFolder: folderId)
                    return true
                } else if documentManager.folders.contains(where: { $0.id == id }) {
                    documentManager.moveFolder(folderId: id, toParent: folderId)
                    return true
                }
                return false
            } isTargeted: { isTargeted in
                if isTargeted {
                    dropTargetedFolderId.wrappedValue = folderId
                } else if dropTargetedFolderId.wrappedValue == folderId {
                    dropTargetedFolderId.wrappedValue = nil
                }
            }
        } else {
            self
        }
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

private enum DocumentsSortMode: String, CaseIterable {
    case dateNewest = "newest"
    case dateOldest = "oldest"
    case nameAsc = "alphabetically"
    case nameDesc = "alphabetically_desc"
    case accessNewest = "access_newest"
    case accessOldest = "access_oldest"

    var title: String {
        switch self {
        case .dateNewest: return "Newest"
        case .dateOldest: return "Oldest"
        case .nameAsc: return "A → Z"
        case .nameDesc: return "Z → A"
        case .accessNewest: return "Most Recent"
        case .accessOldest: return "Least Recent"
        }
    }

    var systemImage: String {
        switch self {
        case .dateNewest: return "arrow.down"
        case .dateOldest: return "arrow.up"
        case .nameAsc, .nameDesc: return "textformat"
        case .accessNewest, .accessOldest: return "clock"
        }
    }
}

private enum MixedItemKind {
    case folder(DocumentFolder)
    case document(Document)
}

private struct MixedItem: Identifiable {
    let id: UUID
    let kind: MixedItemKind
    let name: String
    let dateCreated: Date
}

private func makeDocumentDragProvider(_ id: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let text = id.uuidString
    provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
        completion(text.data(using: .utf8), nil)
        return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
        completion(text.data(using: .utf8), nil)
        return nil
    }
    provider.registerObject(text as NSString, visibility: .all)
    return provider
}

private func makeFolderDragProvider(_ id: UUID) -> NSItemProvider {
    let provider = NSItemProvider()
    let text = id.uuidString
    provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier, visibility: .all) { completion in
        completion(text.data(using: .utf8), nil)
        return nil
    }
    provider.registerDataRepresentation(forTypeIdentifier: UTType.data.identifier, visibility: .all) { completion in
        completion(text.data(using: .utf8), nil)
        return nil
    }
    provider.registerObject(text as NSString, visibility: .all)
    return provider
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
    @State private var extractedText: String = ""
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
    @State private var showingSettings = false
    @State private var editMode: EditMode = .inactive
    @State private var dropTargetedFolderId: UUID? = nil
    @AppStorage("documentsSortMode") private var documentsSortModeRaw = DocumentsSortMode.dateNewest.rawValue

    private var documentsSortMode: DocumentsSortMode {
        get { DocumentsSortMode(rawValue: documentsSortModeRaw) ?? .dateNewest }
        nonmutating set { documentsSortModeRaw = newValue.rawValue }
    }

    private func toggleNameSort() {
        documentsSortMode = (documentsSortMode == .nameAsc) ? .nameDesc : .nameAsc
    }

    private func toggleDateSort() {
        documentsSortMode = (documentsSortMode == .dateNewest) ? .dateOldest : .dateNewest
    }

    private func toggleAccessSort() {
        documentsSortMode = (documentsSortMode == .accessNewest) ? .accessOldest : .accessNewest
    }

    private var listSelectionBinding: Binding<Set<UUID>> {
        Binding(
            get: { selectedDocumentIds.union(selectedFolderIds) },
            set: { newValue in
                let docIds = Set(documentManager.documents.map { $0.id })
                let folderIds = Set(documentManager.folders.map { $0.id })
                selectedDocumentIds = newValue.filter { docIds.contains($0) }
                selectedFolderIds = newValue.filter { folderIds.contains($0) }
            }
        )
    }

    private var rootFolders: [DocumentFolder] { documentManager.folders(in: nil) }
    private var rootDocs: [Document] { documentManager.documents(in: nil) }

    private var sortMenu: some View {
        Menu {
            ForEach(DocumentsSortMode.allCases, id: \.rawValue) { mode in
                Button {
                    documentsSortModeRaw = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .semibold))
        }
    }

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

    @ViewBuilder
    private var rootListView: some View {
        if isSelectionMode {
            // Use List for native selection support
            List(selection: listSelectionBinding) {
                ForEach(mixedRootItems()) { item in
                    rootListRow(item)
                }
            }
            .listStyle(.plain)
            .hideScrollBackground()
            .environment(\.editMode, $editMode)
        } else {
            // Use ScrollView + LazyVStack for drag and drop support
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(mixedRootItems()) { item in
                        rootScrollRow(item)
                    }
                }
            }
            .hideScrollBackground()
        }
    }

    @ViewBuilder
    private func rootScrollRow(_ item: MixedItem) -> some View {
        switch item.kind {
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                docCount: documentManager.documents(in: folder.id).count,
                isSelected: selectedFolderIds.contains(folder.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: false,
                onSelectToggle: { toggleFolderSelection(folder.id) },
                onOpen: {
                    documentManager.updateLastAccessed(id: folder.id)
                    activeFolder = folder
                },
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
                },
                isDropTargeted: dropTargetedFolderId == folder.id
            )
            .padding(.horizontal, 8)
            .onDrag { makeFolderDragProvider(folder.id) }
            .onDrop(
                of: [UTType.plainText, UTType.text, UTType.data],
                delegate: ListFolderDropDelegate(
                    folderId: folder.id,
                    documentManager: documentManager,
                    dropTargetedFolderId: $dropTargetedFolderId
                )
            )
        case .document(let document):
            DocumentRowView(
                document: document,
                isSelected: selectedDocumentIds.contains(document.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: false,
                onSelectToggle: { toggleDocumentSelection(document.id) },
                onOpen: { openDocumentPreview(document: document) },
                onRename: { renameDocument(document) },
                onMoveToFolder: {
                    documentToMove = document
                },
                onDelete: { deleteDocument(document) },
                onConvert: { convertDocument(document) },
                onShare: { shareDocuments([document]) }
            )
            .padding(.horizontal, 8)
            .onDrag { makeDocumentDragProvider(document.id) }
        }
    }

    @ViewBuilder
    private func rootListRow(_ item: MixedItem) -> some View {
        switch item.kind {
        case .folder(let folder):
            FolderRowView(
                folder: folder,
                docCount: documentManager.documents(in: folder.id).count,
                isSelected: selectedFolderIds.contains(folder.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: true,
                onSelectToggle: { toggleFolderSelection(folder.id) },
                onOpen: {
                    documentManager.updateLastAccessed(id: folder.id)
                    activeFolder = folder
                },
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
                },
                isDropTargeted: false
            )
            .tag(folder.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        case .document(let document):
            DocumentRowView(
                document: document,
                isSelected: selectedDocumentIds.contains(document.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: true,
                onSelectToggle: { toggleDocumentSelection(document.id) },
                onOpen: { openDocumentPreview(document: document) },
                onRename: { renameDocument(document) },
                onMoveToFolder: {
                    documentToMove = document
                },
                onDelete: { deleteDocument(document) },
                onConvert: { convertDocument(document) },
                onShare: { shareDocuments([document]) }
            )
            .tag(document.id)
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 0, leading: 8, bottom: 0, trailing: 16))
        }
    }

    private var rootGridView: some View {
        ScrollView {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(mixedRootItems()) { item in
                    switch item.kind {
                    case .folder(let folder):
                        FolderGridItemView(
                            folder: folder,
                            docCount: documentManager.documents(in: folder.id).count,
                            isSelected: selectedFolderIds.contains(folder.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleFolderSelection(folder.id) },
                            onOpen: {
                                documentManager.updateLastAccessed(id: folder.id)
                                activeFolder = folder
                            },
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
                        .onDrag { makeFolderDragProvider(folder.id) }
                        .onDrop(
                            of: [UTType.plainText, UTType.text, UTType.data],
                            delegate: FolderDropDelegate(
                                folderId: folder.id,
                                documentManager: documentManager,
                                onHoverChange: { _ in }
                            )
                        )
                    case .document(let document):
                        DocumentGridItemView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleDocumentSelection(document.id) },
                            onOpen: { openDocumentPreview(document: document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
                            },
                            onDelete: { deleteDocument(document) },
                            onConvert: { convertDocument(document) },
                            onShare: { shareDocuments([document]) }
                        )
                        .onDrag { makeDocumentDragProvider(document.id) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .hideScrollBackground()
    }

    @ViewBuilder
    private var rootBrowserView: some View {
        if layoutMode == .list {
            rootListView
        } else {
            rootGridView
        }
        if isOpeningPreview {
            ZStack {
                Rectangle()
                    .fill(.ultraThinMaterial)
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.2)
                    Text("Opening preview...")
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var processingOverlayView: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
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

    private var documentsRootContent: some View {
        Group {
            if isSelectionMode {
                documentsRootContentSelection
            } else {
                documentsRootContentNormal
            }
        }
    }

    private var documentsRootContentSelection: some View {
        documentsMainStack
    }

    private var documentsRootContentNormal: some View {
        documentsMainStack
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
            Group {
                if documentManager.documents.isEmpty && !isProcessing {
                    emptyStateView
                } else {
                    rootBrowserView
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .overlay {
                if isProcessing {
                    processingOverlayView
                }
            }
            .overlay {
                NavigationLink(
                    destination: activeFolderDestinationView,
                    isActive: isShowingActiveFolder
                ) {
                    EmptyView()
                }
                .hidden()
            }
            .navigationTitle("Documents")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newFolderName = ""
                            showingNewFolderDialog = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Button {
                            startScan()
                        } label: {
                            Label("Scan Document", systemImage: "doc.viewfinder")
                        }
                        
                        Button {
                            showingDocumentPicker = true
                        } label: {
                            Label("Import Files", systemImage: "square.and.arrow.down")
                        }
                        
                        Button {
                            showingZipExportSheet = true
                        } label: {
                            Label("Create Zip", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.primary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if isSelectionMode {
                            Button("Share Selected") {
                                shareSelectedDocuments()
                            }
                            Button("Move Selected") {
                                showingBulkMoveSheet = true
                            }
                            Button("Create Zip") {
                                showingZipExportSheet = true
                            }
                            Button("Delete Selected", role: .destructive) {
                                showingBulkDeleteDialog = true
                            }
                            
                            Divider()
                            
                            Button("Cancel") {
                                clearSelection()
                            }
                        } else {
                            Button {
                                isSelectionMode = true
                            } label: {
                                Label("Select", systemImage: "checkmark.circle")
                            }
                            
                            Button {
                                showingSettings = true
                            } label: {
                                Label("Preferences", systemImage: "gearshape")
                            }
                            
                            Divider()
                            
                            Text("View")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                documentManager.setPrefersGridLayout(false)
                            } label: {
                                HStack {
                                    Image(systemName: "list.bullet")
                                    Text("List")
                                    Spacer()
                                    if !documentManager.prefersGridLayout {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                documentManager.setPrefersGridLayout(true)
                            } label: {
                                HStack {
                                    Image(systemName: "square.grid.2x2")
                                    Text("Grid")
                                    Spacer()
                                    if documentManager.prefersGridLayout {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Divider()

                            Text("Sort")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            Button {
                                toggleNameSort()
                            } label: {
                                HStack {
                                    Image(systemName: "textformat")
                                    Text("Name")
                                    Spacer()
                                    if documentsSortMode == .nameAsc {
                                        Image(systemName: "arrow.down")
                                            .foregroundColor(.secondary)
                                    } else if documentsSortMode == .nameDesc {
                                        Image(systemName: "arrow.up")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                toggleDateSort()
                            } label: {
                                HStack {
                                    Image(systemName: "calendar")
                                    Text("Date")
                                    Spacer()
                                    if documentsSortMode == .dateNewest {
                                        Image(systemName: "arrow.down")
                                            .foregroundColor(.secondary)
                                    } else if documentsSortMode == .dateOldest {
                                        Image(systemName: "arrow.up")
                                            .foregroundColor(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Button {
                                toggleAccessSort()
                            } label: {
                                HStack {
                                    Label {
                                        Text("Recent")
                                    } icon: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "clock")
                                            if documentsSortMode == .accessNewest {
                                                Image(systemName: "arrow.down")
                                            } else if documentsSortMode == .accessOldest {
                                                Image(systemName: "arrow.up")
                                            }
                                        }
                                    }
                                    Spacer()
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .onChange(of: isSelectionMode) { active in
            editMode = active ? .active : .inactive
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
                        tags: old.tags,
                        sourceDocumentId: old.sourceDocumentId,
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

    private func processImportedFiles(_ urls: [URL]) {
        isProcessing = true
        var processedCount = 0

        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()

            if let document = documentManager.processFile(at: url) {
                let withFolder = Document(
                    id: document.id,
                    title: document.title,
                    content: document.content,
                    summary: document.summary,
                    ocrPages: document.ocrPages,
                    category: document.category,
                    keywordsResume: document.keywordsResume,
                    tags: document.tags,
                    sourceDocumentId: document.sourceDocumentId,
                    dateCreated: document.dateCreated,
                    folderId: activeFolder?.id,
                    sortOrder: document.sortOrder,
                    type: document.type,
                    imageData: document.imageData,
                    pdfData: document.pdfData,
                    originalFileData: document.originalFileData
                )

                documentManager.addDocument(withFolder)

                let fullTextForKeywords = withFolder.content
                DispatchQueue.global(qos: .utility).async {
                    let cat = DocumentManager.inferCategory(title: withFolder.title, content: fullTextForKeywords, summary: withFolder.summary)
                    let kw = DocumentManager.makeKeywordsResume(title: withFolder.title, content: fullTextForKeywords, summary: withFolder.summary)

                    DispatchQueue.main.async {
                        let current = self.documentManager.getDocument(by: withFolder.id) ?? withFolder
                        let updated = Document(
                            id: current.id,
                            title: current.title,
                            content: current.content,
                            summary: current.summary,
                            ocrPages: current.ocrPages,
                            category: cat,
                            keywordsResume: kw,
                            tags: current.tags,
                            sourceDocumentId: current.sourceDocumentId,
                            dateCreated: current.dateCreated,
                            folderId: current.folderId ?? activeFolder?.id,
                            sortOrder: current.sortOrder,
                            type: current.type,
                            imageData: current.imageData,
                            pdfData: current.pdfData,
                            originalFileData: current.originalFileData
                        )
                        if let idx = self.documentManager.documents.firstIndex(where: { $0.id == current.id }) {
                            self.documentManager.documents[idx] = updated
                        }
                    }
                }

                processedCount += 1
            }

            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        DispatchQueue.main.async {
            self.isProcessing = false
        }
    }

    private func finalizePendingDocument(with name: String) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = finalName.isEmpty ? suggestedName : finalName
        finalizeDocument(with: safeName)
    }

    private func startScan() {
        func presentScanner() {
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

        let cappedText = DocumentManager.truncateText(text, maxChars: 50000)
        let document = Document(
            title: titleCaseFromOCR(cappedText),
            content: cappedText,
            summary: "Processing summary...",
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: activeFolder?.id,
            type: .scanned,
            imageData: nil,
            pdfData: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }

    private func prepareNamingDialog(for images: [UIImage]) {
        guard let firstImage = images.first else { return }

        isProcessing = true

        let firstPage = performOCRDetailed(on: firstImage, pageIndex: 0)
        let firstPageText = firstPage.text

        var ocrPages: [OCRPage] = []
        for (index, image) in images.enumerated() {
            let page = performOCRDetailed(on: image, pageIndex: index)
            ocrPages.append(page.page)
        }
        extractedText = buildStructuredText(from: ocrPages, includePageLabels: true)
        pendingOCRPages = ocrPages

        let fullTextForKeywords = extractedText
        DispatchQueue.global(qos: .utility).async {
            let cat = DocumentManager.inferCategory(title: "", content: fullTextForKeywords, summary: "")
            let kw = DocumentManager.makeKeywordsResume(title: "", content: fullTextForKeywords, summary: "")
            DispatchQueue.main.async {
                self.pendingCategory = cat
                self.pendingKeywordsResume = kw
            }
        }

        suggestedName = titleCaseFromOCR(extractedText.isEmpty ? firstPageText : extractedText)
        customName = suggestedName
        isProcessing = false
        showingNamingDialog = true
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

        let pdfData = createPDF(from: scannedImages)
        let cappedText = DocumentManager.truncateText(extractedText, maxChars: 50000)
        let cappedPages: [OCRPage]? = {
            if pendingOCRPages.isEmpty { return nil }
            return [OCRPage(pageIndex: 0, blocks: [OCRBlock(text: cappedText, confidence: 1.0, bbox: OCRBoundingBox(x: 0.0, y: 0.0, width: 1.0, height: 1.0), order: 0)])]
        }()
        let pagesToStore = pendingOCRPages.isEmpty ? cappedPages : pendingOCRPages

        let document = Document(
            title: name,
            content: cappedText,
            summary: "Processing summary...",
            ocrPages: pagesToStore,
            category: pendingCategory,
            keywordsResume: pendingKeywordsResume,
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: activeFolder?.id,
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            documentManager.addDocument(document)
            isProcessing = false

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
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var mediaBox = pageRect

        guard let pdfContext = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) else { return nil }

        for image in images {
            pdfContext.beginPDFPage(nil)
            let imageSize = image.size
            let scale = min(pageWidth / imageSize.width, pageHeight / imageSize.height)
            let width = imageSize.width * scale
            let height = imageSize.height * scale
            let x = (pageWidth - width) / 2
            let y = (pageHeight - height) / 2
            let rect = CGRect(x: x, y: y, width: width, height: height)
            if let cgImage = image.cgImage {
                pdfContext.draw(cgImage, in: rect)
            }
            pdfContext.endPDFPage()
        }

        pdfContext.closePDF()
        return pdfData as Data
    }

    private func performOCRDetailed(on image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            return ("Could not process image", OCRPage(pageIndex: pageIndex, blocks: []))
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        var recognizedText = ""
        var blocks: [OCRBlock] = []

        do {
            try handler.perform([request])
            if let results = request.results as? [VNRecognizedTextObservation] {
                for (idx, observation) in results.enumerated() {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let bbox = observation.boundingBox
                    let bounding = OCRBoundingBox(x: bbox.origin.x, y: bbox.origin.y, width: bbox.size.width, height: bbox.size.height)
                    blocks.append(OCRBlock(text: candidate.string, confidence: Double(candidate.confidence), bbox: bounding, order: idx))
                    recognizedText += candidate.string + "\n"
                }
            }
        } catch {
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }

        let page = OCRPage(pageIndex: pageIndex, blocks: blocks)
        return (recognizedText, page)
    }

    private func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        var output: [String] = []
        for page in pages {
            if includePageLabels {
                output.append("Page \(page.pageIndex + 1):")
            }
            let sorted = page.blocks.sorted { $0.order < $1.order }
            for block in sorted {
                let line = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    output.append(line)
                }
            }
            output.append("")
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        let targetSize: CGFloat = 2560
        let scale = min(targetSize / max(image.size.width, 1), targetSize / max(image.size.height, 1))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: newSize))
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    private func mixedRootItems() -> [MixedItem] {
        let folderItems = rootFolders.map { folder in
            MixedItem(id: folder.id, kind: .folder(folder), name: folder.name, dateCreated: folder.dateCreated)
        }
        let documentItems = rootDocs.map { doc in
            MixedItem(id: doc.id, kind: .document(doc), name: splitDisplayTitle(doc.title).base, dateCreated: doc.dateCreated)
        }
        return sortMixedItems(folderItems + documentItems)
    }

    private func sortMixedItems(_ items: [MixedItem]) -> [MixedItem] {
        switch documentsSortMode {
        case .dateNewest:
            return items.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated > $1.dateCreated }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .dateOldest:
            return items.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated < $1.dateCreated }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nameAsc:
            return items.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.dateCreated > $1.dateCreated
            }
        case .nameDesc:
            return items.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedDescending }
                return $0.dateCreated > $1.dateCreated
            }
        case .accessNewest:
            return items.sorted {
                let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                if a != b { return a > b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .accessOldest:
            return items.sorted {
                let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
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
    
    private func openDocumentPreview(document: Document) {
        documentManager.updateLastAccessed(id: document.id)
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
    let usesNativeSelection: Bool
    let onSelectToggle: () -> Void

    let onOpen: () -> Void
    let onRename: () -> Void
    let onMoveToFolder: () -> Void
    let onDelete: () -> Void
    let onConvert: () -> Void
    let onShare: () -> Void
    
    var body: some View {
        let parts = splitDisplayTitle(document.title)
        let dateText = DateFormatter.localizedString(from: document.dateCreated, dateStyle: .medium, timeStyle: .none)
        let typeText = fileTypeLabel(documentType: document.type, titleParts: parts)

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Group {
                    if document.type == .zip {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color("Primary"))

                            Image(systemName: "archivebox.fill")
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
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if isSelectionMode && !usesNativeSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? Color("Primary") : .secondary)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .modifier(SelectionTapModifier(
            isSelectionMode: isSelectionMode,
            usesNativeSelection: usesNativeSelection,
            onSelectToggle: onSelectToggle,
            onOpen: onOpen
        ))
        .contextMenu {
            Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onMoveToFolder) { Label("Move to folder", systemImage: "folder") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
        .onDrag { makeDocumentDragProvider(document.id) }
    }
    
}

struct DocumentGridItemView: View {
    let document: Document
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
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
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    if document.type == .zip {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color("Primary"))
                        Image(systemName: "archivebox.fill")
                            .font(.system(size: 28))
                            .foregroundColor(.white)
                    } else {
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(.tertiarySystemBackground))
                        DocumentThumbnailView(document: document, size: CGSize(width: side, height: side))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .frame(width: side, height: side)
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
        .contextMenu {
            Button(action: onShare) { Label("Share", systemImage: "square.and.arrow.up") }
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onMoveToFolder) { Label("Move to folder", systemImage: "folder") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

struct FolderRowView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isSelectionMode: Bool
    let usesNativeSelection: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void
    var isDropTargeted: Bool = false

    var body: some View {
        let dateText = DateFormatter.localizedString(from: folder.dateCreated, dateStyle: .medium, timeStyle: .none)
        let countText = "\(docCount) item\(docCount == 1 ? "" : "s")"

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color("Primary"))
                        .frame(width: 50, height: 50)

                    Image(systemName: "folder.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 20))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                        .lineLimit(2)

                    HStack(spacing: 4) {
                        Text(dateText)
                        Text("•")
                        Text(countText)
                    }
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if isSelectionMode && !usesNativeSelection {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundColor(isSelected ? Color("Primary") : .secondary)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)

            Divider()
                .padding(.horizontal, 16)
        }
        .contentShape(Rectangle())
        .modifier(SelectionTapModifier(
            isSelectionMode: isSelectionMode,
            usesNativeSelection: usesNativeSelection,
            onSelectToggle: onSelectToggle,
            onOpen: onOpen
        ))
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isDropTargeted ? Color("Primary").opacity(0.18) : Color.clear)
        )
        .contextMenu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onMove) { Label("Move to folder", systemImage: "folder") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

private struct SelectionTapModifier: ViewModifier {
    let isSelectionMode: Bool
    let usesNativeSelection: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void

    func body(content: Content) -> some View {
        if usesNativeSelection {
            content
        } else {
            content
                .onTapGesture {
                    if isSelectionMode {
                        onSelectToggle()
                    } else {
                        onOpen()
                    }
                }
        }
    }
}

private struct FolderDropDelegate: DropDelegate {
    let folderId: UUID
    let documentManager: DocumentManager
    let onHoverChange: (Bool) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText, UTType.text, UTType.data])
    }

    func dropEntered(info: DropInfo) {
        DispatchQueue.main.async {
            onHoverChange(true)
        }
    }

    func dropExited(info: DropInfo) {
        DispatchQueue.main.async {
            onHoverChange(false)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText, UTType.text, UTType.data]).first else { return false }
        let preferredType = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : (provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) ? UTType.text.identifier : UTType.data.identifier)

        provider.loadDataRepresentation(forTypeIdentifier: preferredType) { data, _ in
            let uuidString: String? = {
                if let data { return String(data: data, encoding: .utf8) }
                return nil
            }()

            guard let uuidString, let id = UUID(uuidString: uuidString) else { return }
            DispatchQueue.main.async {
                onHoverChange(false)
                // Check if it's a document or a folder and move accordingly
                if documentManager.documents.contains(where: { $0.id == id }) {
                    documentManager.moveDocument(documentId: id, toFolder: folderId)
                } else if documentManager.folders.contains(where: { $0.id == id }) {
                    // Prevent moving folder into itself
                    if id != folderId {
                        documentManager.moveFolder(folderId: id, toParent: folderId)
                    }
                }
            }
        }
        return true
    }
}

private struct ListFolderDropDelegate: DropDelegate {
    let folderId: UUID
    let documentManager: DocumentManager
    @Binding var dropTargetedFolderId: UUID?

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [UTType.plainText, UTType.text, UTType.data])
    }

    func dropEntered(info: DropInfo) {
        DispatchQueue.main.async {
            dropTargetedFolderId = folderId
        }
    }

    func dropExited(info: DropInfo) {
        DispatchQueue.main.async {
            if dropTargetedFolderId == folderId {
                dropTargetedFolderId = nil
            }
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = info.itemProviders(for: [UTType.plainText, UTType.text, UTType.data]).first else { return false }
        let preferredType = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
            ? UTType.plainText.identifier
            : (provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) ? UTType.text.identifier : UTType.data.identifier)

        provider.loadDataRepresentation(forTypeIdentifier: preferredType) { data, _ in
            let uuidString: String? = {
                if let data { return String(data: data, encoding: .utf8) }
                return nil
            }()

            guard let uuidString, let id = UUID(uuidString: uuidString) else { return }
            DispatchQueue.main.async {
                dropTargetedFolderId = nil
                // Check if it's a document or a folder and move accordingly
                if documentManager.documents.contains(where: { $0.id == id }) {
                    documentManager.moveDocument(documentId: id, toFolder: folderId)
                } else if documentManager.folders.contains(where: { $0.id == id }) {
                    // Prevent moving folder into itself
                    if id != folderId {
                        documentManager.moveFolder(folderId: id, toParent: folderId)
                    }
                }
            }
        }
        return true
    }
}

struct CheckeredPatternView: View {
    var body: some View {
        Canvas { context, size in
            let tileSize: CGFloat = 4
            let rows = Int(ceil(size.height / tileSize))
            let cols = Int(ceil(size.width / tileSize))

            for row in 0..<rows {
                for col in 0..<cols {
                    let isEven = (row + col) % 2 == 0
                    let rect = CGRect(
                        x: CGFloat(col) * tileSize,
                        y: CGFloat(row) * tileSize,
                        width: tileSize,
                        height: tileSize
                    )

                    context.fill(
                        Path(rect),
                        with: .color(isEven ? .gray.opacity(0.3) : .gray.opacity(0.1))
                    )
                }
            }
        }
    }
}

struct FolderGridItemView: View {
    let folder: DocumentFolder
    let docCount: Int
    let isSelected: Bool
    let isSelectionMode: Bool
    let onSelectToggle: () -> Void
    let onOpen: () -> Void
    let onRename: () -> Void
    let onMove: () -> Void
    let onDelete: () -> Void

    var body: some View {
        let previewHeight: CGFloat = 120
        let parts = splitDisplayTitle(folder.name)

        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let side = proxy.size.width
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color("Primary"))
                    Image(systemName: "folder.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.white)
                }
                .frame(width: side, height: side)
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
        .contextMenu {
            Button(action: onRename) { Label("Rename", systemImage: "pencil") }
            Button(action: onMove) { Label("Move to folder", systemImage: "folder") }
            Button(role: .destructive, action: onDelete) { Label("Delete", systemImage: "trash") }
        }
    }
}

struct FolderDocumentsView: View {
    let folder: DocumentFolder
    let onOpenDocument: (Document) -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    private var layoutMode: DocumentLayoutMode { documentManager.prefersGridLayout ? .grid : .list }
    @AppStorage("documentsSortMode") private var documentsSortModeRaw = DocumentsSortMode.dateNewest.rawValue
    private var documentsSortMode: DocumentsSortMode {
        get { DocumentsSortMode(rawValue: documentsSortModeRaw) ?? .dateNewest }
        nonmutating set { documentsSortModeRaw = newValue.rawValue }
    }
    @State private var documentToMove: Document?

    @State private var activeSubfolder: DocumentFolder?

    @State private var showingDocumentPicker = false
    @State private var showingScanner = false
    @State private var scannerMode: ScannerMode = .document
    @State private var showingCameraPermissionAlert = false
    @State private var isProcessing = false
    @State private var showingNamingDialog = false
    @State private var suggestedName = ""
    @State private var customName = ""
    @State private var scannedImages: [UIImage] = []
    @State private var extractedText: String = ""
    @State private var pendingOCRPages: [OCRPage] = []
    @State private var pendingCategory: Document.DocumentCategory = .general
    @State private var pendingKeywordsResume: String = ""
    @State private var showingSettings = false

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

    @State private var showingNewFolderDialog = false
    @State private var newFolderName = ""
    @State private var dropTargetedFolderId: UUID? = nil

    private func toggleNameSort() {
        documentsSortMode = (documentsSortMode == .nameAsc) ? .nameDesc : .nameAsc
    }

    private func toggleDateSort() {
        documentsSortMode = (documentsSortMode == .dateNewest) ? .dateOldest : .dateNewest
    }

    private func toggleAccessSort() {
        documentsSortMode = (documentsSortMode == .accessNewest) ? .accessOldest : .accessNewest
    }

    private var sortMenu: some View {
        Menu {
            ForEach(DocumentsSortMode.allCases, id: \.rawValue) { mode in
                Button {
                    documentsSortModeRaw = mode.rawValue
                } label: {
                    Label(mode.title, systemImage: mode.systemImage)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 16, weight: .semibold))
        }
    }

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

    @ViewBuilder
    private var folderListContent: some View {
        if isSelectionMode {
            // Use List for native selection support
            List {
                ForEach(mixedFolderItems()) { item in
                    folderListRowForSelection(item)
                }
            }
            .listStyle(.plain)
            .hideScrollBackground()
        } else {
            // Use ScrollView for drag and drop support
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(mixedFolderItems()) { item in
                        folderScrollRow(item)
                    }
                }
            }
            .hideScrollBackground()
        }
    }

    @ViewBuilder
    private func folderListRowForSelection(_ item: MixedItem) -> some View {
        switch item.kind {
        case .folder(let sub):
            FolderRowView(
                folder: sub,
                docCount: documentManager.documents(in: sub.id).count,
                isSelected: selectedFolderIds.contains(sub.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: true,
                onSelectToggle: { toggleFolderSelection(sub.id) },
                onOpen: {
                    documentManager.updateLastAccessed(id: sub.id)
                    activeSubfolder = sub
                },
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
                },
                isDropTargeted: false
            )
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        case .document(let document):
            DocumentRowView(
                document: document,
                isSelected: selectedDocumentIds.contains(document.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: true,
                onSelectToggle: { toggleDocumentSelection(document.id) },
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
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets())
        }
    }

    @ViewBuilder
    private func folderScrollRow(_ item: MixedItem) -> some View {
        switch item.kind {
        case .folder(let sub):
            FolderRowView(
                folder: sub,
                docCount: documentManager.documents(in: sub.id).count,
                isSelected: selectedFolderIds.contains(sub.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: false,
                onSelectToggle: { toggleFolderSelection(sub.id) },
                onOpen: {
                    documentManager.updateLastAccessed(id: sub.id)
                    activeSubfolder = sub
                },
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
                },
                isDropTargeted: dropTargetedFolderId == sub.id
            )
            .padding(.horizontal, 8)
            .onDrag { makeFolderDragProvider(sub.id) }
            .onDrop(
                of: [UTType.plainText, UTType.text, UTType.data],
                delegate: ListFolderDropDelegate(
                    folderId: sub.id,
                    documentManager: documentManager,
                    dropTargetedFolderId: $dropTargetedFolderId
                )
            )
        case .document(let document):
            DocumentRowView(
                document: document,
                isSelected: selectedDocumentIds.contains(document.id),
                isSelectionMode: isSelectionMode,
                usesNativeSelection: false,
                onSelectToggle: { toggleDocumentSelection(document.id) },
                onOpen: { onOpenDocument(document) },
                onRename: { renameDocument(document) },
                onMoveToFolder: {
                    documentToMove = document
                },
                onDelete: { documentManager.deleteDocument(document) },
                onConvert: { },
                onShare: { shareDocuments([document]) }
            )
            .padding(.horizontal, 8)
            .onDrag { makeDocumentDragProvider(document.id) }
        }
    }

    private var folderGridContent: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
        return ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(mixedFolderItems()) { item in
                    switch item.kind {
                    case .folder(let sub):
                        FolderGridItemView(
                            folder: sub,
                            docCount: documentManager.documents(in: sub.id).count,
                            isSelected: selectedFolderIds.contains(sub.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleFolderSelection(sub.id) },
                            onOpen: {
                                documentManager.updateLastAccessed(id: sub.id)
                                activeSubfolder = sub
                            },
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
                        .onDrag { makeFolderDragProvider(sub.id) }
                        .onDrop(
                            of: [UTType.plainText, UTType.text, UTType.data],
                            delegate: FolderDropDelegate(
                                folderId: sub.id,
                                documentManager: documentManager,
                                onHoverChange: { _ in }
                            )
                        )
                    case .document(let document):
                        DocumentGridItemView(
                            document: document,
                            isSelected: selectedDocumentIds.contains(document.id),
                            isSelectionMode: isSelectionMode,
                            onSelectToggle: { toggleDocumentSelection(document.id) },
                            onOpen: { onOpenDocument(document) },
                            onRename: { renameDocument(document) },
                            onMoveToFolder: {
                                documentToMove = document
                            },
                            onDelete: { documentManager.deleteDocument(document) },
                            onConvert: { },
                            onShare: { shareDocuments([document]) }
                        )
                        .onDrag { makeDocumentDragProvider(document.id) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)
            .padding(.bottom, 24)
        }
        .hideScrollBackground()
    }

    private var folderBaseContent: some View {
        Group {
            if layoutMode == .list {
                folderListContent
            } else {
                folderGridContent
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .overlay {
            NavigationLink(
                destination: activeSubfolderDestinationView,
                isActive: isShowingActiveSubfolder
            ) {
                EmptyView()
            }
            .hidden()
        }
        .navigationTitle(folder.name)
    }

    private var folderContentSelection: some View {
        folderBaseContent
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newFolderName = ""
                            showingNewFolderDialog = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Button {
                            startScan()
                        } label: {
                            Label("Scan Document", systemImage: "doc.viewfinder")
                        }

                        Button {
                            showingDocumentPicker = true
                        } label: {
                            Label("Import Files", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            showingZipExportSheet = true
                        } label: {
                            Label("Create Zip", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.primary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Share Selected") {
                            shareSelectedDocuments()
                        }
                        Button("Move Selected") {
                            showingBulkMoveSheet = true
                        }
                        Button("Create Zip") {
                            showingZipExportSheet = true
                        }
                        Button("Delete Selected", role: .destructive) {
                            showingBulkDeleteDialog = true
                        }
                        
                        Divider()
                        
                        Button("Cancel") {
                            clearSelection()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
    }

    private var folderContentNormal: some View {
        folderBaseContent
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            newFolderName = ""
                            showingNewFolderDialog = true
                        } label: {
                            Label("New Folder", systemImage: "folder.badge.plus")
                        }

                        Button {
                            startScan()
                        } label: {
                            Label("Scan Document", systemImage: "doc.viewfinder")
                        }

                        Button {
                            showingDocumentPicker = true
                        } label: {
                            Label("Import Files", systemImage: "square.and.arrow.down")
                        }

                        Button {
                            showingZipExportSheet = true
                        } label: {
                            Label("Create Zip", systemImage: "archivebox")
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundColor(.primary)
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            isSelectionMode = true
                        } label: {
                            Label("Select", systemImage: "checkmark.circle")
                        }
                        
                        Button {
                            showingSettings = true
                        } label: {
                            Label("Preferences", systemImage: "gearshape")
                        }
                        
                        Divider()
                        
                        Text("View")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            documentManager.setPrefersGridLayout(false)
                        } label: {
                            HStack {
                                Image(systemName: "list.bullet")
                                Text("List")
                                Spacer()
                                if !documentManager.prefersGridLayout {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Button {
                            documentManager.setPrefersGridLayout(true)
                        } label: {
                            HStack {
                                Image(systemName: "square.grid.2x2")
                                Text("Grid")
                                Spacer()
                                if documentManager.prefersGridLayout {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Divider()
                        
                        Text("Sort")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Button {
                            toggleNameSort()
                        } label: {
                            HStack {
                                Image(systemName: "textformat")
                                Text("Name")
                                Spacer()
                                if documentsSortMode == .nameAsc {
                                    Image(systemName: "arrow.down")
                                        .foregroundColor(.secondary)
                                } else if documentsSortMode == .nameDesc {
                                    Image(systemName: "arrow.up")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Button {
                            toggleDateSort()
                        } label: {
                            HStack {
                                Image(systemName: "calendar")
                                Text("Date")
                                Spacer()
                                if documentsSortMode == .dateNewest {
                                    Image(systemName: "arrow.down")
                                        .foregroundColor(.secondary)
                                } else if documentsSortMode == .dateOldest {
                                    Image(systemName: "arrow.up")
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Button {
                            toggleAccessSort()
                        } label: {
                            HStack {
                                Label {
                                    Text("Recent")
                                } icon: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "clock")
                                        if documentsSortMode == .accessNewest {
                                            Image(systemName: "arrow.down")
                                        } else if documentsSortMode == .accessOldest {
                                            Image(systemName: "arrow.up")
                                        }
                                    }
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .foregroundColor(.primary)
                    }
                }
            }
    }

    var body: some View {
        Group {
            if isSelectionMode {
                folderContentSelection
            } else {
                folderContentNormal
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
                preselectedFolderIds: selectedFolderIds,
                targetFolderId: folder.id
            )
            .environmentObject(documentManager)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showingDocumentPicker) {
            DocumentPicker { urls in
                processImportedFiles(urls)
            }
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
        .alert("New Folder", isPresented: $showingNewFolderDialog) {
            TextField("Folder name", text: $newFolderName)
            Button("Create") {
                documentManager.createFolder(name: newFolderName, parentId: folder.id)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Enter a name for the folder")
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
                        tags: old.tags,
                        sourceDocumentId: old.sourceDocumentId,
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

    private func mixedFolderItems() -> [MixedItem] {
        let subfolders = documentManager.folders(in: folder.id).map { sub in
            MixedItem(id: sub.id, kind: .folder(sub), name: sub.name, dateCreated: sub.dateCreated)
        }
        let docs = documentManager.documents(in: folder.id).map { doc in
            MixedItem(id: doc.id, kind: .document(doc), name: splitDisplayTitle(doc.title).base, dateCreated: doc.dateCreated)
        }
        return sortMixedItems(subfolders + docs)
    }

    private func sortMixedItems(_ items: [MixedItem]) -> [MixedItem] {
        switch documentsSortMode {
        case .dateNewest:
            return items.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated > $1.dateCreated }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .dateOldest:
            return items.sorted {
                if $0.dateCreated != $1.dateCreated { return $0.dateCreated < $1.dateCreated }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nameAsc:
            return items.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedAscending }
                return $0.dateCreated > $1.dateCreated
            }
        case .nameDesc:
            return items.sorted {
                let nameOrder = $0.name.localizedCaseInsensitiveCompare($1.name)
                if nameOrder != .orderedSame { return nameOrder == .orderedDescending }
                return $0.dateCreated > $1.dateCreated
            }
        case .accessNewest:
            return items.sorted {
                let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                if a != b { return a > b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .accessOldest:
            return items.sorted {
                let a = documentManager.lastAccessedDate(for: $0.id, fallback: $0.dateCreated)
                let b = documentManager.lastAccessedDate(for: $1.id, fallback: $1.dateCreated)
                if a != b { return a < b }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
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

    // MARK: - Folder-specific document processing functions
    
    private func startScan() {
        func presentScanner() {
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

    private func processImportedFiles(_ urls: [URL]) {
        isProcessing = true
        var processedCount = 0

        for url in urls {
            let didStartAccess = url.startAccessingSecurityScopedResource()

            if let document = documentManager.processFile(at: url) {
                let withFolder = Document(
                    id: document.id,
                    title: document.title,
                    content: document.content,
                    summary: document.summary,
                    ocrPages: document.ocrPages,
                    category: document.category,
                    keywordsResume: document.keywordsResume,
                    tags: document.tags,
                    sourceDocumentId: document.sourceDocumentId,
                    dateCreated: document.dateCreated,
                    folderId: folder.id,
                    sortOrder: document.sortOrder,
                    type: document.type,
                    imageData: document.imageData,
                    pdfData: document.pdfData,
                    originalFileData: document.originalFileData
                )

                documentManager.addDocument(withFolder)

                let fullTextForKeywords = withFolder.content
                DispatchQueue.global(qos: .utility).async {
                    let cat = DocumentManager.inferCategory(title: withFolder.title, content: fullTextForKeywords, summary: withFolder.summary)
                    let kw = DocumentManager.makeKeywordsResume(title: withFolder.title, content: fullTextForKeywords, summary: withFolder.summary)

                    DispatchQueue.main.async {
                        let current = self.documentManager.getDocument(by: withFolder.id) ?? withFolder
                        let updated = Document(
                            id: current.id,
                            title: current.title,
                            content: current.content,
                            summary: current.summary,
                            ocrPages: current.ocrPages,
                            category: cat,
                            keywordsResume: kw,
                            tags: current.tags,
                            sourceDocumentId: current.sourceDocumentId,
                            dateCreated: current.dateCreated,
                            folderId: current.folderId ?? self.folder.id,
                            sortOrder: current.sortOrder,
                            type: current.type,
                            imageData: current.imageData,
                            pdfData: current.pdfData,
                            originalFileData: current.originalFileData
                        )
                        if let idx = self.documentManager.documents.firstIndex(where: { $0.id == current.id }) {
                            self.documentManager.documents[idx] = updated
                        }
                    }
                }

                processedCount += 1
            }

            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        DispatchQueue.main.async {
            self.isProcessing = false
        }
    }

    private func processScannedText(_ text: String) {
        isProcessing = true

        let cappedText = DocumentManager.truncateText(text, maxChars: 50000)
        let document = Document(
            title: titleCaseFromOCR(cappedText),
            content: cappedText,
            summary: "Processing summary...",
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: folder.id,
            type: .scanned,
            imageData: nil,
            pdfData: nil
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            documentManager.addDocument(document)
            isProcessing = false
        }
    }

    private func prepareNamingDialog(for images: [UIImage]) {
        guard let firstImage = images.first else { return }

        isProcessing = true

        let firstPage = performOCRDetailed(on: firstImage, pageIndex: 0)
        let firstPageText = firstPage.text

        var ocrPages: [OCRPage] = []
        for (index, image) in images.enumerated() {
            let page = performOCRDetailed(on: image, pageIndex: index)
            ocrPages.append(page.page)
        }
        extractedText = buildStructuredText(from: ocrPages, includePageLabels: true)
        pendingOCRPages = ocrPages

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

        if !namingSeed.isEmpty {
            generateAIDocumentName(from: namingSeed)
        } else {
            suggestedName = titleCaseFromOCR(firstPageText)
            customName = suggestedName
            isProcessing = false
            showingNamingDialog = true
        }
    }

    private func finalizePendingDocument(with name: String) {
        let finalName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = finalName.isEmpty ? suggestedName : finalName
        finalizeDocument(with: safeName)
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

        let pdfData = createPDF(from: scannedImages)
        let cappedText = DocumentManager.truncateText(extractedText, maxChars: 50000)
        let cappedPages: [OCRPage]? = {
            if pendingOCRPages.isEmpty { return nil }
            return [OCRPage(pageIndex: 0, blocks: [OCRBlock(text: cappedText, confidence: 1.0, bbox: OCRBoundingBox(x: 0.0, y: 0.0, width: 1.0, height: 1.0), order: 0)])]
        }()
        let pagesToStore = pendingOCRPages.isEmpty ? cappedPages : pendingOCRPages

        let document = Document(
            title: name,
            content: cappedText,
            summary: "Processing summary...",
            ocrPages: pagesToStore,
            category: pendingCategory,
            keywordsResume: pendingKeywordsResume,
            tags: [],
            sourceDocumentId: nil,
            dateCreated: Date(),
            folderId: folder.id,
            type: .scanned,
            imageData: imageDataArray,
            pdfData: pdfData
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            documentManager.addDocument(document)
            isProcessing = false

            scannedImages.removeAll()
            extractedText = ""
            suggestedName = ""
            customName = ""
            pendingCategory = .general
            pendingKeywordsResume = ""
            pendingOCRPages = []
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

        EdgeAI.shared?.generate("<<<NO_HISTORY>>><<<NAME_REQUEST>>>" + prompt, resolver: { result in
            DispatchQueue.main.async {
                if let result = result as? String, !result.isEmpty {
                    let clean = result.trimmingCharacters(in: .whitespacesAndNewlines)
                    let normalized = self.normalizeSuggestedTitle(clean, fallback: fallback)
                    self.suggestedName = normalized.isEmpty ? fallback : normalized
                } else {
                    self.suggestedName = fallback
                }
                self.customName = self.suggestedName
                self.isProcessing = false
                self.showingNamingDialog = true
            }
        }, rejecter: { code, message, error in
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
        score += Double(max(0, 5 - index)) * 0.35
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
            .replacingOccurrences(of: "[\"'`]", with: "", options: .regularExpression)
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
            .replacingOccurrences(of: "[\"'`]", with: "", options: .regularExpression)
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

    private func performOCRDetailed(on image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
        guard let processedImage = preprocessImageForOCR(image),
              let cgImage = processedImage.cgImage else {
            return ("Could not process image", OCRPage(pageIndex: pageIndex, blocks: []))
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        var recognizedText = ""
        var blocks: [OCRBlock] = []

        do {
            try handler.perform([request])
            if let results = request.results as? [VNRecognizedTextObservation] {
                for (idx, observation) in results.enumerated() {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let bbox = observation.boundingBox
                    let bounding = OCRBoundingBox(x: bbox.origin.x, y: bbox.origin.y, width: bbox.size.width, height: bbox.size.height)
                    blocks.append(OCRBlock(text: candidate.string, confidence: Double(candidate.confidence), bbox: bounding, order: idx))
                    recognizedText += candidate.string + "\n"
                }
            }
        } catch {
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }

        let page = OCRPage(pageIndex: pageIndex, blocks: blocks)
        return (recognizedText, page)
    }

    private func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        var output: [String] = []
        for page in pages {
            if includePageLabels {
                output.append("Page \(page.pageIndex + 1):")
            }
            let sorted = page.blocks.sorted { $0.order < $1.order }
            for block in sorted {
                let line = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty {
                    output.append(line)
                }
            }
            output.append("")
        }
        return output.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func preprocessImageForOCR(_ image: UIImage) -> UIImage? {
        let targetSize: CGFloat = 2560
        let scale = min(targetSize / max(image.size.width, 1), targetSize / max(image.size.height, 1))
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, true, 1.0)
        UIColor.white.setFill()
        UIRectFill(CGRect(origin: .zero, size: newSize))
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let result = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return result
    }

    private func createPDF(from images: [UIImage]) -> Data? {
        let pdfData = NSMutableData()

        guard let dataConsumer = CGDataConsumer(data: pdfData) else { return nil }
        let pageWidth: CGFloat = 612
        let pageHeight: CGFloat = 792
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)
        var mediaBox = pageRect

        guard let pdfContext = CGContext(consumer: dataConsumer, mediaBox: &mediaBox, nil) else { return nil }

        for image in images {
            pdfContext.beginPDFPage(nil)

            if let cgImage = image.cgImage {
                let imageSize = image.size
                let imageAspectRatio = imageSize.width / imageSize.height
                let pageAspectRatio = pageWidth / pageHeight

                var drawRect: CGRect

                if imageAspectRatio > pageAspectRatio {
                    let scaledHeight = pageWidth / imageAspectRatio
                    let yOffset = (pageHeight - scaledHeight) / 2
                    drawRect = CGRect(x: 0, y: yOffset, width: pageWidth, height: scaledHeight)
                } else {
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
    let contentMode: UIView.ContentMode

    init(data: Data, contentMode: UIView.ContentMode = .scaleAspectFill) {
        self.data = data
        self.contentMode = contentMode
    }
    
    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = contentMode
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

struct DocumentThumbnailView: UIViewRepresentable {
    let document: Document
    let size: CGSize

    func makeUIView(context: Context) -> UIImageView {
        let imageView = UIImageView()
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        return imageView
    }

    func updateUIView(_ uiView: UIImageView, context: Context) {
        if document.type == .scanned, let imageData = document.imageData?.first, let uiImage = UIImage(data: imageData) {
            uiView.image = renderThumbnail(from: uiImage, size: size)
            return
        }

        if let imageData = document.imageData?.first, let uiImage = UIImage(data: imageData) {
            uiView.image = renderThumbnail(from: uiImage, size: size)
            return
        }

        if let pdfData = document.pdfData, let image = thumbnailFromPDF(data: pdfData, size: size) {
            uiView.image = image
            return
        }

        var ext = splitDisplayTitle(document.title).ext
        var data: Data?

        if document.type == .scanned,
           document.pdfData == nil,
           document.imageData?.first == nil {
            data = document.content.data(using: .utf8)
            ext = "txt"
        } else {
            data = document.originalFileData ?? document.pdfData ?? document.imageData?.first ?? document.content.data(using: .utf8)
            if ext.isEmpty {
                ext = fileExtension(for: document.type)
            }
        }

        guard let data else {
            uiView.image = nil
            return
        }

        let fileURL = temporaryFileURL(id: document.id, ext: ext.isEmpty ? "dat" : ext)

        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL, options: [.atomic])
        }

        let request = QLThumbnailGenerator.Request(
            fileAt: fileURL,
            size: size,
            scale: UIScreen.main.scale,
            representationTypes: .thumbnail
        )

        QLThumbnailGenerator.shared.generateRepresentations(for: request) { representation, _, _ in
            guard let representation = representation else { return }
            DispatchQueue.main.async {
                uiView.image = representation.uiImage
            }
        }
    }

    private func thumbnailFromPDF(data: Data, size: CGSize) -> UIImage? {
        guard let document = PDFDocument(data: data), let firstPage = document.page(at: 0) else { return nil }
        return firstPage.thumbnail(of: size, for: .mediaBox)
    }

    private func renderThumbnail(from image: UIImage, size: CGSize) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            let imageSize = image.size
            let scale = max(size.width / imageSize.width, size.height / imageSize.height)
            let width = imageSize.width * scale
            let height = imageSize.height * scale
            let x = (size.width - width) / 2
            let y = (size.height - height) / 2
            image.draw(in: CGRect(x: x, y: y, width: width, height: height))
        }
    }

    private func temporaryFileURL(id: UUID, ext: String) -> URL {
        let safeExt = ext.isEmpty ? "dat" : ext
        return FileManager.default.temporaryDirectory.appendingPathComponent("doc_thumb_\(id.uuidString).\(safeExt)")
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
