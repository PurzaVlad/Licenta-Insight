import SwiftUI
import PDFKit
import UIKit

struct ToolsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var showingSettings = false
    @AppStorage("pendingToolsDeepLink") private var pendingToolsDeepLink = ""
    @State private var deepLinkTool: ToolKind?
    @State private var showDeepLinkFlow = false

    var body: some View {
        NavigationView {
            ZStack {
                ScrollView {
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 12) {
                            SectionHeader(title: "Organize")
                            ToolRow(
                                icon: "rectangle.portrait.on.rectangle.portrait.fill",
                                title: "Merge PDF"
                            ) {
                                ToolsFlowView(tool: .merge)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(
                                icon: "rectangle.split.2x1.fill",
                                title: "Split PDF"
                            ) {
                                ToolsFlowView(tool: .split)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(
                                icon: "line.3.horizontal.decrease",
                                title: "Arrange PDF"
                            ) {
                                ToolsFlowView(tool: .rearrange)
                                    .environmentObject(documentManager)
                            }

                            SectionHeader(title: "Modify")
                            ToolRow(
                                icon: "rectangle.portrait.rotate",
                                title: "Rotate PDF"
                            ) {
                                ToolsFlowView(tool: .rotate)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(
                                icon: "arrow.down.right.and.arrow.up.left",
                                title: "Compress PDF"
                            ) {
                                ToolsFlowView(tool: .compress)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(icon: "crop", title: "Crop PDF") {
                                ToolsFlowView(tool: .crop)
                                    .environmentObject(documentManager)
                            }

                            SectionHeader(title: "Protect & Sign")
                            ToolRow(icon: "signature", title: "Sign PDF") {
                                ToolsFlowView(tool: .sign)
                                    .environmentObject(documentManager)
                            }
                            ToolRow(icon: "lock.fill", title: "Protect PDF", showsDivider: false) {
                                ToolsFlowView(tool: .protect)
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
                NavigationLink(isActive: $showDeepLinkFlow) {
                    if let tool = deepLinkTool {
                        ToolsFlowView(tool: tool)
                            .environmentObject(documentManager)
                    } else {
                        EmptyView()
                    }
                } label: {
                    EmptyView()
                }
                .hidden()
            }
            .hideScrollBackground()
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(.systemGroupedBackground).ignoresSafeArea())
            .navigationTitle("Tools")
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
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .modifier(SharedSettingsSheetBackgroundModifier())
            }
            .onAppear {
                handlePendingDeepLinkIfNeeded()
            }
            .onChange(of: pendingToolsDeepLink) { _ in
                handlePendingDeepLinkIfNeeded()
            }
        }
    }

    private var cardBackground: Color {
        colorScheme == .dark
            ? Color(.secondarySystemGroupedBackground)
            : Color(.systemBackground)
    }

    private func handlePendingDeepLinkIfNeeded() {
        guard !pendingToolsDeepLink.isEmpty else { return }
        guard let tool = toolKindFromDeepLinkId(pendingToolsDeepLink) else {
            pendingToolsDeepLink = ""
            return
        }
        pendingToolsDeepLink = ""
        deepLinkTool = tool
        showDeepLinkFlow = false
        DispatchQueue.main.async {
            showDeepLinkFlow = true
        }
    }

    private func toolKindFromDeepLinkId(_ id: String) -> ToolKind? {
        switch id {
        case "tool-merge": return .merge
        case "tool-split": return .split
        case "tool-arrange": return .rearrange
        case "tool-rotate": return .rotate
        case "tool-compress": return .compress
        case "tool-crop": return .crop
        case "tool-sign": return .sign
        case "tool-protect": return .protect
        default: return nil
        }
    }
}

struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.title3.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.top, 2)
    }
}

struct ToolRow<Destination: View>: View {
    let icon: String
    let title: String
    let destination: Destination
    let showsDivider: Bool

    init(icon: String, title: String, showsDivider: Bool = true, @ViewBuilder destination: () -> Destination) {
        self.icon = icon
        self.title = title
        self.destination = destination()
        self.showsDivider = showsDivider
    }

    var body: some View {
        NavigationLink(destination: destination) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(Color("Primary"))
                    .frame(width: 24)

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

private enum ToolKind: String, Hashable {
    case merge
    case split
    case rearrange
    case rotate
    case compress
    case crop
    case sign
    case protect

    var title: String {
        switch self {
        case .merge: return "Merge PDF"
        case .split: return "Split PDF"
        case .rearrange: return "Arrange PDF"
        case .rotate: return "Rotate PDF"
        case .compress: return "Compress PDF"
        case .crop: return "Crop PDF"
        case .sign: return "Sign PDF"
        case .protect: return "Protect PDF"
        }
    }

    var selectionLimit: Int {
        switch self {
        case .merge: return 3
        default: return 1
        }
    }

    var pickerTitle: String {
        selectionLimit > 1 ? "Select PDFs" : "Select PDF"
    }
}

private struct ToolsFlowView: View {
    let tool: ToolKind
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIds: [UUID] = []
    @State private var showEditor = false
    @State private var shouldExitToRoot = false

    private var pdfDocuments: [Document] {
        documentManager.documents.filter { isPDFDocument($0) }
    }

    var body: some View {
        ToolsPDFPickerView(
            title: tool.pickerTitle,
            documents: pdfDocuments,
            maxSelection: tool.selectionLimit,
            selectedIds: $selectedIds,
            suppressCancel: shouldExitToRoot,
            onDone: { ids in
                if ids.isEmpty {
                    dismiss()
                } else {
                    selectedIds = ids
                    showEditor = true
                }
            },
            onCancel: {
                dismiss()
            }
        )
        .background(
            NavigationLink(isActive: $showEditor) {
                ToolsEditorView(
                    tool: tool,
                    selectedIds: selectedIds,
                    onFinish: {
                        shouldExitToRoot = true
                        showEditor = false
                    }
                )
                .environmentObject(documentManager)
            } label: {
                EmptyView()
            }
        )
        .onAppear {
            if shouldExitToRoot {
                dismiss()
            }
        }
    }
}

private struct ToolsPDFPickerView: View {
    let title: String
    let documents: [Document]
    let maxSelection: Int
    @Binding var selectedIds: [UUID]
    let suppressCancel: Bool
    let onDone: ([UUID]) -> Void
    let onCancel: () -> Void
    @State private var searchText = ""
    @State private var didAdvance = false
    @State private var selectionSet: Set<UUID> = []
    @State private var lastSelectionSet: Set<UUID> = []
    @State private var isAdjustingSelection = false

    private var filteredDocuments: [Document] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return documents }
        let needle = trimmed.lowercased()
        return documents.filter { doc in
            let base = splitDisplayTitle(doc.title).base.lowercased()
            return base.contains(needle)
        }
    }

    var body: some View {
        List(selection: $selectionSet) {
            if filteredDocuments.isEmpty {
                Text("No PDFs available.")
                    .foregroundColor(.secondary)
            } else {
                ForEach(filteredDocuments) { document in
                    DocumentRowView(
                        document: document,
                        isSelected: selectedIds.contains(document.id),
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
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search PDFs")
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button("Clear") {
                    selectionSet = []
                    lastSelectionSet = []
                    selectedIds.removeAll()
                }
                .foregroundColor(.primary)
                .disabled(selectedIds.isEmpty)
            }
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("Done") {
                    didAdvance = true
                    onDone(selectedIds)
                }
                .foregroundColor(.primary)
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedIds.isEmpty)
            }
        }
        .onDisappear {
            if !didAdvance && !suppressCancel {
                onCancel()
            }
        }
        .onAppear {
            selectionSet = Set(selectedIds)
            lastSelectionSet = selectionSet
        }
        .onChange(of: selectionSet) { newSet in
            if isAdjustingSelection { return }
            isAdjustingSelection = true
            defer { isAdjustingSelection = false }

            let added = newSet.subtracting(lastSelectionSet)
            let removed = lastSelectionSet.subtracting(newSet)
            var ordered = selectedIds

            if !removed.isEmpty {
                ordered.removeAll { removed.contains($0) }
            }
            if !added.isEmpty {
                for id in added {
                    ordered.append(id)
                }
            }

            if ordered.count > maxSelection {
                ordered = Array(ordered.prefix(maxSelection))
                selectionSet = Set(ordered)
            }

            selectedIds = ordered
            lastSelectionSet = selectionSet
        }
    }
}

private struct ToolsEditorView: View {
    let tool: ToolKind
    let selectedIds: [UUID]
    let onFinish: () -> Void
    @EnvironmentObject private var documentManager: DocumentManager
    @Environment(\.dismiss) private var dismiss
    @State private var renameQueue: [UUID] = []
    @State private var showingRenameDialog = false
    @State private var renameText = ""
    @State private var suggestedName = ""
    @State private var renameTargetId: UUID?

    private var selectedDocuments: [Document] {
        selectedIds.compactMap { documentManager.getDocument(by: $0) }
    }

    var body: some View {
        toolView
            .alert("Rename Document", isPresented: $showingRenameDialog) {
                TextField("Document name", text: $renameText)

                Button("Use Suggested") {
                    advanceRenameQueue(shouldRename: false)
                }

                Button("Rename") {
                    advanceRenameQueue(shouldRename: true)
                }

                Button("Cancel", role: .cancel) {
                    advanceRenameQueue(shouldRename: false)
                }
            } message: {
                Text("Suggested name: \"\(suggestedName)\"\n\nWould you like to use this name or enter a custom one?")
            }
    }

    @ViewBuilder
    private var toolView: some View {
        switch tool {
        case .merge:
            MergePDFsView(
                preselectedIds: selectedIds,
                preferredOrder: selectedIds,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .split:
            SplitPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .rearrange:
            RearrangePDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .rotate:
            RotatePDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .compress:
            CompressPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .crop:
            CropPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .sign:
            SignPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        case .protect:
            ProtectPDFView(
                preselectedDocument: selectedDocuments.first,
                allowsPicker: false,
                onComplete: handleCompletion
            )
        }
    }

    private func handleCompletion(_ documents: [Document]) {
        let ids = documents.map { $0.id }
        renameQueue = ids
        showNextRename()
    }

    private func showNextRename() {
        guard !renameQueue.isEmpty else {
            finishFlow()
            return
        }
        let nextId = renameQueue.removeFirst()
        guard let doc = documentManager.getDocument(by: nextId) else {
            showNextRename()
            return
        }
        renameTargetId = doc.id
        suggestedName = doc.title
        renameText = splitDisplayTitle(doc.title).base
        showingRenameDialog = true
    }

    private func advanceRenameQueue(shouldRename: Bool) {
        if shouldRename {
            let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let targetId = renameTargetId {
                renameDocument(id: targetId, to: trimmed)
            }
        }
        showingRenameDialog = false
        showNextRename()
    }

    private func finishFlow() {
        onFinish()
        dismiss()
    }

    private func renameDocument(id: UUID, to newBase: String) {
        guard let idx = documentManager.documents.firstIndex(where: { $0.id == id }) else { return }
        let old = documentManager.documents[idx]

        let oldParts = splitDisplayTitle(old.title)
        let typedURL = URL(fileURLWithPath: newBase)
        let typedExt = typedURL.pathExtension.lowercased()
        let knownExts: Set<String> = ["pdf", "docx", "ppt", "pptx", "xls", "xlsx", "txt", "png", "jpg", "jpeg", "heic"]
        let sanitizedBase = knownExts.contains(typedExt) ? typedURL.deletingPathExtension().lastPathComponent : newBase
        let finalBase = sanitizedBase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalBase.isEmpty else { return }

        let newTitle = oldParts.ext.isEmpty ? finalBase : "\(finalBase).\(oldParts.ext)"

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
        documentManager.updateSummary(for: updated.id, to: updated.summary)
    }
}

struct CompressPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var didAutoPresent = false
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var quality: Double = 0.7

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 16) {
            if let document = selectedDocument {
                VStack(spacing: 6) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Compression quality: \(Int(quality * 100))%")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                Slider(value: $quality, in: 0.4...0.9, step: 0.05)
                    .padding(.horizontal)

                Button(isSaving ? "Compressing..." : "Compress PDF") {
                    compressSelected()
                }
                .disabled(isSaving)

                if allowsPicker {
                    Button("Choose Different PDF") { showingPicker = true }
                        .foregroundColor(.secondary)
                }
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Compress PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .alert("Compress PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func compressSelected() {
        guard let document = selectedDocument,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else {
            alertMessage = "Please choose a PDF first."
            showingAlert = true
            return
        }

        isSaving = true
        var existingTitles = existingDocumentTitles(in: documentManager)
        let baseName = baseTitle(for: document.title)
        let preferredBase = "\(baseName)_compressed"
        let outputName = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
        existingTitles.insert(outputName.lowercased())

        let compressionQuality = quality

        DispatchQueue.global(qos: .userInitiated).async {
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            let outData = renderer.pdfData { context in
                for idx in 0..<pdf.pageCount {
                    guard let page = pdf.page(at: idx) else { continue }
                    let bounds = page.bounds(for: .mediaBox)
                    context.beginPage(withBounds: bounds, pageInfo: [:])

                    let targetSize = CGSize(width: bounds.width * compressionQuality, height: bounds.height * compressionQuality)
                    let image = page.thumbnail(of: targetSize, for: .mediaBox)
                    let rect = CGRect(
                        x: (bounds.width - image.size.width) / 2,
                        y: (bounds.height - image.size.height) / 2,
                        width: image.size.width,
                        height: image.size.height
                    )
                    image.draw(in: rect)
                }
            }

            let newDoc = makePDFDocument(title: outputName, data: outData, sourceDocumentId: document.id)
            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Compressed PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
    }
}

struct ProtectPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var didAutoPresent = false
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 16) {
            if let document = selectedDocument {
                VStack(spacing: 6) {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Text("Set a password required by any PDF reader.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                SecureField("Password", text: $password)
                    .textContentType(.newPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                SecureField("Confirm Password", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                Button(isSaving ? "Securing..." : "Protect PDF") {
                    protectSelected()
                }
                .disabled(isSaving)

                if allowsPicker {
                    Button("Choose Different PDF") { showingPicker = true }
                        .foregroundColor(.secondary)
                }
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .navigationTitle("Protect PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .alert("Protect PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func protectSelected() {
        guard let document = selectedDocument,
              let sourceData = pdfData(from: document) else {
            alertMessage = "Please choose a PDF first."
            showingAlert = true
            return
        }

        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "Password cannot be empty."
            showingAlert = true
            return
        }
        guard trimmed == confirmPassword else {
            alertMessage = "Passwords do not match."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            guard let pdf = PDFDocument(data: sourceData) else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to read the selected PDF."
                    showingAlert = true
                }
                return
            }

            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("protected_\(UUID().uuidString).pdf")
            let options: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: trimmed,
                .ownerPasswordOption: trimmed
            ]

            let writeOK = pdf.write(to: tempURL, withOptions: options)
            guard writeOK, let outData = try? Data(contentsOf: tempURL) else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to encrypt PDF."
                    showingAlert = true
                }
                return
            }
            try? FileManager.default.removeItem(at: tempURL)

            guard let verifyPDF = PDFDocument(data: outData), verifyPDF.isEncrypted else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "PDF encryption failed."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_protected"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                password = ""
                confirmPassword = ""
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Password-protected PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

struct ComingSoonView: View {
    let title: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock")
                .font(.system(size: 34, weight: .regular))
                .foregroundStyle(.secondary)
            Text("\(title) is coming soon.")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("We’ll add this feature in a future update.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}


// MARK: - PDF Editing Tools

struct SignPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @StateObject private var signatureStore = SignatureStore()
    @StateObject private var pdfController = PDFSigningController()
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var showingSignatureSheet = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 12) {
            if selectedDocument != nil {
                Color.clear
                    .frame(height: 24)
                    .padding(.top, 6)

                PDFSigningViewRepresentable(controller: pdfController)
                    .frame(maxWidth: .infinity, minHeight: 360, maxHeight: 520)
                    .background(Color(.secondarySystemBackground))
                    .cornerRadius(12)
                    .padding(.horizontal)

                HStack(spacing: 12) {
                    Button("Draw Signature") {
                        showingSignatureSheet = true
                    }

                    Button(isSaving ? "Saving..." : "Save Signed PDF") {
                        saveSignedPDF()
                    }
                    .disabled(isSaving)
                }

                signaturePanel
                    .padding(.bottom, 10)
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                        .padding(.horizontal)
                        .padding(.top, 6)
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
            }
        }
        .padding(.top, 8)
        .navigationTitle("Sign PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .sheet(isPresented: $showingSignatureSheet) {
            SignatureCaptureSheet { image in
                signatureStore.addSignature(image: image)
            }
        }
        .onAppear {
            if autoPresentPicker, !didAutoPresent {
                didAutoPresent = true
                DispatchQueue.main.async {
                    showingPicker = true
                }
            }
            if selectedDocument != nil {
                loadPDF(for: selectedDocument)
            }
        }
        .onChange(of: selectedDocument) { newDoc in
            loadPDF(for: newDoc)
        }
        .alert("Sign PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private var signaturePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Signatures")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .padding(.horizontal)

            if signatureStore.signatures.isEmpty {
                Text("No signatures yet. Tap “Draw Signature” to add one.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
            } else {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 12) {
                        ForEach(signatureStore.signatures) { sig in
                            Button {
                                pdfController.addSignatureAtVisibleCenter(image: sig.image)
                            } label: {
                                Image(uiImage: sig.image)
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundColor(.white)
                                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: 120)
                                    .padding(.horizontal, 8)
                            }
                            .buttonStyle(.plain)
                            .cornerRadius(10)
                            .shadow(color: Color.black.opacity(0.08), radius: 3, x: 0, y: 1)
                        }
                    }
                    .padding(.horizontal)
                }
                .frame(height: 220)
            }
        }
    }

    private func loadPDF(for document: Document?) {
        guard let document,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else {
            pdfController.load(document: nil)
            return
        }
        pdfController.load(document: pdf)
    }

    private func saveSignedPDF() {
        guard let document = selectedDocument,
              let outData = pdfController.renderSignedData() else {
            alertMessage = "No signed PDF to save."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_signed"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Signed PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

final class PDFSigningController: NSObject, ObservableObject, UIGestureRecognizerDelegate {
    weak var pdfView: PDFView?
    weak var overlayView: UIView?
    private var document: PDFDocument?
    private var placements: [SignaturePlacement] = []
    private var signatureViews: [UUID: SignaturePlacementView] = [:]
    private var observers: [NSObjectProtocol] = []
    private var scrollObservation: NSKeyValueObservation?

    deinit {
        removeObservers()
    }

    func load(document: PDFDocument?) {
        objectWillChange.send()
        self.document = document
        placements.removeAll()
        signatureViews.values.forEach { $0.removeFromSuperview() }
        signatureViews.removeAll()
        pdfView?.document = document
        pdfView?.autoScales = true
        updateOverlay()
    }

    func currentDocument() -> PDFDocument? {
        document
    }

    func addSignature(image: UIImage, at viewPoint: CGPoint) {
        guard let pdfView,
              let page = pdfView.page(for: viewPoint, nearest: true) else {
            return
        }
        let pagePoint = pdfView.convert(viewPoint, to: page)
        addSignature(image: image, on: page, at: pagePoint)
    }

    func addSignatureAtVisibleCenter(image: UIImage) {
        guard let pdfView else { return }
        let centerInPdfView = CGPoint(x: pdfView.bounds.midX, y: pdfView.bounds.midY)
        let page = pdfView.page(for: centerInPdfView, nearest: true) ?? document?.page(at: 0)
        guard let targetPage = page else { return }
        let pagePoint = pdfView.convert(centerInPdfView, to: targetPage)
        addSignature(image: image, on: targetPage, at: pagePoint)
    }

    private func addSignature(image: UIImage, on page: PDFPage, at pagePoint: CGPoint) {
        guard let pdfView else { return }
        let pageBounds = page.bounds(for: pdfView.displayBox)
        let maxWidth = min(pageBounds.width * 0.35, 240)
        let aspect = image.size.height == 0 ? 0.3 : image.size.height / image.size.width
        let height = maxWidth * aspect
        let size = CGSize(width: maxWidth, height: max(height, 24))

        var origin = CGPoint(x: pagePoint.x - size.width / 2, y: pagePoint.y - size.height / 2)
        let contentInsets = image.alphaInsets()
        let contentInsetsScaled = scaledContentInsets(contentInsets, imageSize: image.size, targetSize: size)
        let minX = pageBounds.minX - contentInsetsScaled.left
        let maxX = pageBounds.maxX - size.width + contentInsetsScaled.right
        let minY = pageBounds.minY - contentInsetsScaled.bottom
        let maxY = pageBounds.maxY - size.height + contentInsetsScaled.top
        origin.x = min(max(origin.x, minX), maxX)
        origin.y = min(max(origin.y, minY), maxY)
        let bounds = CGRect(origin: origin, size: size)
        let pageIndex = document?.index(for: page) ?? max(0, (page.pageRef?.pageNumber ?? 1) - 1)
        let placement = SignaturePlacement(image: image, pageIndex: pageIndex, boundsInPage: bounds, contentInsets: contentInsets)
        placements.append(placement)
        if pdfView.documentView == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.updateOverlay()
            }
        } else {
            updateOverlay()
        }
    }

    func renderSignedData() -> Data? {
        guard let document, document.pageCount > 0 else { return nil }
        let firstBounds = document.page(at: 0)?.bounds(for: .mediaBox) ?? CGRect(x: 0, y: 0, width: 612, height: 792)
        let renderer = UIGraphicsPDFRenderer(bounds: firstBounds)

        return renderer.pdfData { context in
            for pageIndex in 0..<document.pageCount {
                guard let page = document.page(at: pageIndex) else { continue }
                let pageBounds = page.bounds(for: .mediaBox)
                context.beginPage(withBounds: pageBounds, pageInfo: [:])

                let cg = context.cgContext
                cg.saveGState()
                cg.translateBy(x: 0, y: pageBounds.height)
                cg.scaleBy(x: 1, y: -1)
                page.draw(with: .mediaBox, to: cg)
                cg.restoreGState()

                for placement in placements where placement.pageIndex == pageIndex {
                    let rect = placement.boundsInPage
                    let drawRect = CGRect(
                        x: rect.origin.x,
                        y: pageBounds.height - rect.origin.y - rect.height,
                        width: rect.width,
                        height: rect.height
                    )
                    placement.image.draw(in: drawRect)
                }
            }
        }
    }

    func attach(pdfView: PDFView, overlayView: UIView) {
        self.pdfView = pdfView
        self.overlayView = overlayView
        removeObservers()
        attachScrollObserver()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: Notification.Name.PDFViewScaleChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.clampScaleToMinimum()
            self?.updateOverlay()
        })
        observers.append(center.addObserver(forName: Notification.Name.PDFViewPageChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updateOverlay()
        })
        observers.append(center.addObserver(forName: Notification.Name.PDFViewDisplayModeChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updateOverlay()
        })
        observers.append(center.addObserver(forName: Notification.Name.PDFViewDisplayBoxChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.updateOverlay()
        })
        observers.append(center.addObserver(forName: Notification.Name.PDFViewDocumentChanged, object: pdfView, queue: .main) { [weak self] _ in
            self?.attachScrollObserver()
            self?.updateOverlay()
        })
    }

    private func removeObservers() {
        scrollObservation?.invalidate()
        scrollObservation = nil
        let center = NotificationCenter.default
        for token in observers {
            center.removeObserver(token)
        }
        observers.removeAll()
    }

    private func updateOverlay() {
        guard let pdfView, let overlayView else { return }
        let placementIds = Set(placements.map { $0.id })
        for (id, view) in signatureViews where !placementIds.contains(id) {
            view.removeFromSuperview()
            signatureViews.removeValue(forKey: id)
        }

        for placement in placements {
            guard let page = document?.page(at: placement.pageIndex) else { continue }
            let viewRect = pdfView.convert(placement.boundsInPage, from: page)
            let docRect = overlayView.convert(viewRect, from: pdfView)
            let sigView: SignaturePlacementView
            if let existing = signatureViews[placement.id] {
                sigView = existing
            } else {
                let created = SignaturePlacementView(image: placement.image)
                created.accessibilityIdentifier = placement.id.uuidString
                created.onDelete = { [weak self] in
                    self?.removePlacement(id: placement.id)
                }
                let pan = UIPanGestureRecognizer(target: self, action: #selector(handleSignaturePan(_:)))
                pan.delegate = self
                created.addGestureRecognizer(pan)
                overlayView.addSubview(created)
                signatureViews[placement.id] = created
                sigView = created
            }
            sigView.frame = docRect
            sigView.contentInsets = scaledContentInsets(placement.contentInsets, imageSize: placement.image.size, targetSize: docRect.size)
        }
    }

    private func removePlacement(id: UUID) {
        if let index = placements.firstIndex(where: { $0.id == id }) {
            placements.remove(at: index)
            if let view = signatureViews.removeValue(forKey: id) {
                view.removeFromSuperview()
            }
            updateOverlay()
        }
    }

    @objc private func handleSignaturePan(_ gesture: UIPanGestureRecognizer) {
        guard let view = gesture.view,
              let overlayView,
              let pdfView,
              let idString = view.accessibilityIdentifier,
              let placementIndex = placements.firstIndex(where: { $0.id.uuidString == idString }) else {
            return
        }

        switch gesture.state {
        case .began, .changed:
            let translation = gesture.translation(in: overlayView)
            view.center = CGPoint(x: view.center.x + translation.x, y: view.center.y + translation.y)
            gesture.setTranslation(.zero, in: overlayView)
        case .ended, .cancelled, .failed:
            let centerInPdf = overlayView.convert(view.center, to: pdfView)
            guard let page = pdfView.page(for: centerInPdf, nearest: true) else { return }
            let pageBounds = page.bounds(for: pdfView.displayBox)
            let frameInPdf = overlayView.convert(view.frame, to: pdfView)
            var pageRect = pdfView.convert(frameInPdf, to: page)

            let placement = placements[placementIndex]
            let contentInsetsScaled = scaledContentInsets(placement.contentInsets, imageSize: placement.image.size, targetSize: pageRect.size)
            let minX = pageBounds.minX - contentInsetsScaled.left
            let maxX = pageBounds.maxX - pageRect.width + contentInsetsScaled.right
            let minY = pageBounds.minY - contentInsetsScaled.bottom
            let maxY = pageBounds.maxY - pageRect.height + contentInsetsScaled.top
            pageRect.origin.x = min(max(pageRect.origin.x, minX), maxX)
            pageRect.origin.y = min(max(pageRect.origin.y, minY), maxY)

            let pageIndex = document?.index(for: page) ?? max(0, (page.pageRef?.pageNumber ?? 1) - 1)
            placements[placementIndex].pageIndex = pageIndex
            placements[placementIndex].boundsInPage = pageRect

            let correctedViewRect = pdfView.convert(pageRect, from: page)
            let correctedInOverlay = overlayView.convert(correctedViewRect, from: pdfView)
            view.frame = correctedInOverlay
            if let sigView = view as? SignaturePlacementView {
                sigView.contentInsets = scaledContentInsets(placement.contentInsets, imageSize: placement.image.size, targetSize: correctedInOverlay.size)
            }
        default:
            break
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        false
    }

    private func attachScrollObserver() {
        scrollObservation?.invalidate()
        guard let pdfView, let scrollView = findScrollView(in: pdfView) else { return }
        scrollObservation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            self?.updateOverlay()
        }
    }

    private func clampScaleToMinimum() {
        guard let pdfView else { return }
        let fit = pdfView.scaleFactorForSizeToFit
        if fit > 0 {
            if pdfView.minScaleFactor != fit {
                pdfView.minScaleFactor = fit
            }
            if pdfView.scaleFactor < fit {
                pdfView.scaleFactor = fit
            }
        }
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let found = findScrollView(in: subview) {
                return found
            }
        }
        return nil
    }

    private func scaledContentInsets(_ insets: UIEdgeInsets, imageSize: CGSize, targetSize: CGSize) -> UIEdgeInsets {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scaleX = targetSize.width / imageSize.width
        let scaleY = targetSize.height / imageSize.height
        return UIEdgeInsets(
            top: insets.top * scaleY,
            left: insets.left * scaleX,
            bottom: insets.bottom * scaleY,
            right: insets.right * scaleX
        )
    }
}

private struct SignaturePlacement: Identifiable {
    let id = UUID()
    let image: UIImage
    var pageIndex: Int
    var boundsInPage: CGRect
    let contentInsets: UIEdgeInsets
}

struct PDFSigningViewRepresentable: UIViewRepresentable {
    @ObservedObject var controller: PDFSigningController

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let pdfView = PDFView()
        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.autoScales = true
        pdfView.minScaleFactor = pdfView.scaleFactorForSizeToFit
        pdfView.maxScaleFactor = pdfView.scaleFactorForSizeToFit * 6.0
        pdfView.backgroundColor = UIColor.clear
        pdfView.isMultipleTouchEnabled = true
        pdfView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(pdfView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: container.topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        controller.attach(pdfView: pdfView, overlayView: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard let pdfView = controller.pdfView else { return }
        if pdfView.document !== controller.currentDocument() {
            pdfView.document = controller.currentDocument()
        }
        let fit = pdfView.scaleFactorForSizeToFit
        if fit > 0 {
            if pdfView.minScaleFactor != fit {
                pdfView.minScaleFactor = fit
            }
            let maxScale = fit * 6.0
            if pdfView.maxScaleFactor != maxScale {
                pdfView.maxScaleFactor = maxScale
            }
        }
    }
}

final class SignaturePlacementView: UIView {
    private let imageView = UIImageView()
    private let deleteButton = UIButton(type: .system)
    var onDelete: (() -> Void)?
    var contentInsets: UIEdgeInsets = .zero {
        didSet { setNeedsLayout() }
    }

    init(image: UIImage) {
        super.init(frame: .zero)
        setup()
        imageView.image = image
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        backgroundColor = .clear
        isUserInteractionEnabled = true

        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        deleteButton.tintColor = .systemRed
        deleteButton.translatesAutoresizingMaskIntoConstraints = true
        deleteButton.isHidden = true
        deleteButton.addTarget(self, action: #selector(handleDelete), for: .touchUpInside)

        addSubview(imageView)
        addSubview(deleteButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let tap = UITapGestureRecognizer(target: self, action: #selector(toggleDelete))
        tap.cancelsTouchesInView = false
        addGestureRecognizer(tap)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonSize: CGFloat = 28
        let contentRect = bounds.inset(by: contentInsets)
        let x = contentRect.maxX - buttonSize * 0.5
        let y = contentRect.minY - buttonSize * 0.5
        deleteButton.frame = CGRect(x: x, y: y, width: buttonSize, height: buttonSize)
    }

    @objc private func toggleDelete() {
        deleteButton.isHidden.toggle()
    }

    @objc private func handleDelete() {
        onDelete?()
    }
}

// MARK: - Signature Capture

struct SignatureCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var padController = SignaturePadController()
    let onSave: (UIImage) -> Void
    @State private var showEmptyAlert = false

    var body: some View {
        NavigationView {
            VStack(spacing: 12) {
                SignaturePadRepresentable(controller: padController)
                    .background(Color.white)
                    .cornerRadius(12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color(.systemGray4), lineWidth: 1)
                    )
                    .padding()

                HStack(spacing: 12) {
                    Button("Clear") {
                        padController.clear()
                    }

                    Button("Save") {
                        guard let image = padController.renderImage(), !padController.isEmpty else {
                            showEmptyAlert = true
                            return
                        }
                        onSave(image)
                        dismiss()
                    }
                }
                .padding(.bottom)
            }
            .navigationTitle("Draw Signature")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .alert("Signature is empty", isPresented: $showEmptyAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Draw a signature before saving.")
            }
        }
    }
}

final class SignaturePadController: ObservableObject {
    weak var view: SignaturePadView?

    var isEmpty: Bool {
        view?.isEmpty ?? true
    }

    func clear() {
        view?.clear()
    }

    func renderImage() -> UIImage? {
        view?.renderImage()
    }
}

struct SignaturePadRepresentable: UIViewRepresentable {
    @ObservedObject var controller: SignaturePadController

    func makeUIView(context: Context) -> SignaturePadView {
        let view = SignaturePadView()
        controller.view = view
        return view
    }

    func updateUIView(_ uiView: SignaturePadView, context: Context) {}
}

final class SignaturePadView: UIView {
    private var paths: [UIBezierPath] = []
    private var currentPath: UIBezierPath?
    private var lastPoint: CGPoint = .zero
    private var lastMidPoint: CGPoint = .zero
    private lazy var panGesture: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.maximumNumberOfTouches = 1
        pan.cancelsTouchesInView = false
        pan.delaysTouchesBegan = false
        pan.delaysTouchesEnded = false
        return pan
    }()

    var isEmpty: Bool {
        paths.isEmpty && currentPath == nil
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        isMultipleTouchEnabled = false
        addGestureRecognizer(panGesture)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        backgroundColor = .white
        isMultipleTouchEnabled = false
        addGestureRecognizer(panGesture)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        switch gesture.state {
        case .began:
            let path = UIBezierPath()
            path.lineWidth = 2.5
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            path.move(to: point)
            currentPath = path
            lastPoint = point
            lastMidPoint = point
            setNeedsDisplay()
        case .changed:
            guard let path = currentPath else { return }
            let midPoint = CGPoint(x: (lastPoint.x + point.x) / 2, y: (lastPoint.y + point.y) / 2)
            path.addQuadCurve(to: midPoint, controlPoint: lastPoint)
            lastPoint = point
            lastMidPoint = midPoint
            setNeedsDisplay()
        case .ended, .cancelled, .failed:
            guard let path = currentPath else { return }
            path.addLine(to: lastPoint)
            paths.append(path)
            currentPath = nil
            setNeedsDisplay()
        default:
            break
        }
    }

    override func draw(_ rect: CGRect) {
        UIColor.black.setStroke()
        for path in paths {
            path.stroke()
        }
        currentPath?.stroke()
    }

    func clear() {
        paths.removeAll()
        currentPath = nil
        setNeedsDisplay()
    }

    func renderImage() -> UIImage? {
        let format = UIGraphicsImageRendererFormat.default()
        format.opaque = false
        format.scale = 0
        let renderer = UIGraphicsImageRenderer(bounds: bounds, format: format)
        return renderer.image { context in
            UIColor.clear.setFill()
            context.fill(bounds)
            UIColor.black.setStroke()
            for path in paths {
                path.stroke()
            }
            currentPath?.stroke()
        }
    }
}

private extension UIImage {
    func alphaInsets(alphaThreshold: UInt8 = 10) -> UIEdgeInsets {
        guard let cgImage = cgImage else { return .zero }
        let width = cgImage.width
        let height = cgImage.height
        if width == 0 || height == 0 { return .zero }

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        let bitsPerComponent = 8
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return .zero
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { return .zero }

        var minX = width
        var minY = height
        var maxX = 0
        var maxY = 0
        var foundPixel = false

        let buffer = data.bindMemory(to: UInt8.self, capacity: height * bytesPerRow)
        for y in 0..<height {
            let row = y * bytesPerRow
            for x in 0..<width {
                let alpha = buffer[row + x * bytesPerPixel + 3]
                if alpha > alphaThreshold {
                    foundPixel = true
                    if x < minX { minX = x }
                    if x > maxX { maxX = x }
                    if y < minY { minY = y }
                    if y > maxY { maxY = y }
                }
            }
        }

        guard foundPixel else { return .zero }

        return UIEdgeInsets(
            top: CGFloat(minY),
            left: CGFloat(minX),
            bottom: CGFloat(height - 1 - maxY),
            right: CGFloat(width - 1 - maxX)
        )
    }
}

// MARK: - Signature Store

struct SignatureItem: Identifiable {
    let id: String
    let image: UIImage
}

final class SignatureStore: ObservableObject {
    @Published private(set) var signatures: [SignatureItem] = []
    private let storageKey = "savedSignatures"

    init() {
        load()
    }

    func addSignature(image: UIImage) {
        guard let data = image.pngData() else { return }
        let encoded = data.base64EncodedString()
        var stored = storedSignatures()
        if stored.contains(encoded) == false {
            stored.insert(encoded, at: 0)
        }
        UserDefaults.standard.set(stored, forKey: storageKey)
        load()
    }

    private func load() {
        signatures = storedSignatures().compactMap { encoded in
            guard let data = Data(base64Encoded: encoded),
                  let image = UIImage(data: data) else { return nil }
            return SignatureItem(id: encoded, image: image)
        }
    }

    private func storedSignatures() -> [String] {
        UserDefaults.standard.stringArray(forKey: storageKey) ?? []
    }
}

// MARK: - Merge

struct MergePDFsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let preferredOrder: [UUID]?
    let onComplete: (([Document]) -> Void)?
    @State private var selectedIds: Set<UUID> = []
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(
        autoPresentPicker: Bool = false,
        preselectedIds: [UUID] = [],
        preferredOrder: [UUID]? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.preferredOrder = preferredOrder ?? preselectedIds
        self.onComplete = onComplete
        _selectedIds = State(initialValue: Set(preselectedIds))
    }

    private var pdfDocuments: [Document] {
        documentManager.documents.filter { isPDFDocument($0) }
    }

    private var selectedDocuments: [Document] {
        guard let preferredOrder else {
            return pdfDocuments.filter { selectedIds.contains($0.id) }
        }

        let docsById = Dictionary(uniqueKeysWithValues: pdfDocuments.map { ($0.id, $0) })
        var orderedDocs: [Document] = []
        var seen = Set<UUID>()

        for id in preferredOrder where selectedIds.contains(id) {
            if let doc = docsById[id], seen.insert(id).inserted {
                orderedDocs.append(doc)
            }
        }

        if orderedDocs.count < selectedIds.count {
            for doc in pdfDocuments where selectedIds.contains(doc.id) && !seen.contains(doc.id) {
                orderedDocs.append(doc)
            }
        }

        return orderedDocs
    }

    var body: some View {
        VStack(spacing: 16) {
            if selectedDocuments.isEmpty {
                Text("Select up to 3 PDFs to merge.")
                    .foregroundColor(.secondary)
            } else {
                List {
                    ForEach(selectedDocuments, id: \.id) { doc in
                        HStack {
                            Text(doc.title)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                selectedIds.remove(doc.id)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
            }

            HStack(spacing: 12) {
                if allowsPicker {
                    Button("Choose PDFs") {
                        showingPicker = true
                    }
                }

                Button(isSaving ? "Merging..." : "Merge") {
                    mergeSelected()
                }
                .disabled(selectedDocuments.count < 2 || isSaving)
            }
        }
        .padding()
        .navigationTitle("Merge PDFs")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFMultiPickerSheet(
                documents: pdfDocuments,
                selectedIds: $selectedIds,
                maxSelection: 3
            )
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .alert("Merge PDFs", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func mergeSelected() {
        guard selectedDocuments.count >= 2 else { return }
        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)

        let workItem = DispatchWorkItem {
            let merged = PDFDocument()
            var pageIndex = 0

            for doc in selectedDocuments {
                guard let data = pdfData(from: doc),
                      let pdf = PDFDocument(data: data) else { continue }
                for i in 0..<pdf.pageCount {
                    if let page = pdf.page(at: i) {
                        merged.insert(page, at: pageIndex)
                        pageIndex += 1
                    }
                }
            }

            guard let data = merged.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to merge PDFs."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: selectedDocuments.first?.title ?? "PDF")
            let preferredBase = "\(base)_merged"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(title: title, data: data, sourceDocumentId: nil)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                selectedIds.removeAll()
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Merged PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

// MARK: - Split

struct SplitPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var ranges: [PageRangeInput] = [PageRangeInput()]
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    private var pageCount: Int {
        guard let doc = selectedDocument,
              let data = pdfData(from: doc),
              let pdf = PDFDocument(data: data) else { return 0 }
        return pdf.pageCount
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let document = selectedDocument {
                    HStack {
                        Text(document.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        if allowsPicker {
                            Button("Change") { showingPicker = true }
                        }
                    }
                    Text("Pages: \(pageCount)")
                        .foregroundColor(.secondary)
                } else {
                    if allowsPicker {
                        Button("Choose PDF") { showingPicker = true }
                    } else {
                        Text("No PDF selected.")
                            .foregroundColor(.secondary)
                    }
                }

                VStack(spacing: 12) {
                    ForEach(ranges.indices, id: \.self) { idx in
                        HStack(spacing: 12) {
                            TextField("Start", text: $ranges[idx].start)
                                .keyboardType(.numberPad)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Text("to")
                            TextField("End", text: $ranges[idx].end)
                                .keyboardType(.numberPad)
                                .textFieldStyle(RoundedBorderTextFieldStyle())
                            Button {
                                if ranges.count > 1 {
                                    ranges.remove(at: idx)
                                }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundColor(ranges.count > 1 ? .red : .secondary)
                            }
                            .disabled(ranges.count == 1)
                        }
                    }

                    Button("Add Range") {
                        if ranges.count < 3 {
                            ranges.append(PageRangeInput())
                        }
                    }
                    .disabled(ranges.count >= 3)
                }

                Button(isSaving ? "Splitting..." : "Split") {
                    splitSelected()
                }
                .disabled(selectedDocument == nil || isSaving)
            }
            .padding()
        }
        .navigationTitle("Split PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
            }
        }
        .alert("Split PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func splitSelected() {
        guard let document = selectedDocument,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else { return }

        let totalPages = pdf.pageCount
        let parsedRanges = parseRanges(totalPages: totalPages)
        if parsedRanges.isEmpty {
            alertMessage = "Enter valid page ranges within 1-\(totalPages)."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)

        let workItem = DispatchWorkItem {
            var created = 0
            var newDocs: [Document] = []
            var existingTitles = initialTitles
            for (idx, range) in parsedRanges.enumerated() {
                let newPDF = PDFDocument()
                var insertIndex = 0
                for page in range.lowerBound...range.upperBound {
                    if let pdfPage = pdf.page(at: page - 1) {
                        newPDF.insert(pdfPage, at: insertIndex)
                        insertIndex += 1
                    }
                }
                guard let outData = newPDF.dataRepresentation() else { continue }
                let base = baseTitle(for: document.title)
                let preferredBase = "\(base)_split\(idx + 1)"
                let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
                existingTitles.insert(title.lowercased())
                let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)
                newDocs.append(newDoc)
                created += 1
                if created >= 3 { break }
            }

            DispatchQueue.main.async {
                for doc in newDocs {
                    documentManager.addDocument(doc)
                }
                isSaving = false
                if let onComplete, !newDocs.isEmpty {
                    onComplete(newDocs)
                } else {
                    alertMessage = created > 0 ? "Created \(created) PDFs." : "Failed to split PDF."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }

    private func parseRanges(totalPages: Int) -> [ClosedRange<Int>] {
        ranges.compactMap { input in
            guard let start = Int(input.start), let end = Int(input.end) else { return nil }
            guard start >= 1, end >= 1, start <= end, end <= totalPages else { return nil }
            return start...end
        }.prefix(3).map { $0 }
    }
}

struct PageRangeInput {
    var start: String = ""
    var end: String = ""
}

// MARK: - Rearrange

struct RearrangePDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [PDFPageItem] = []
    @State private var editMode: EditMode = .active
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let document = selectedDocument {
                HStack {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if allowsPicker {
                        Button("Change") { showingPicker = true }
                    }
                }
                .padding(.horizontal)
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }

            if !pageItems.isEmpty {
                List {
                    ForEach(pageItems) { item in
                        HStack(spacing: 12) {
                            Image(uiImage: item.thumbnail)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 70)
                                .cornerRadius(6)
                            Text("Page \(item.index + 1)")
                        }
                    }
                    .onMove { indices, newOffset in
                        pageItems.move(fromOffsets: indices, toOffset: newOffset)
                    }
                }
                .environment(\.editMode, $editMode)
            }

            Button(isSaving ? "Saving..." : "Save Rearranged") {
                saveRearranged()
            }
            .disabled(selectedDocument == nil || pageItems.isEmpty || isSaving)
            .padding(.bottom, 12)
        }
        .navigationTitle("Rearrange PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            if autoPresentPicker, !didAutoPresent {
                didAutoPresent = true
                DispatchQueue.main.async {
                    showingPicker = true
                }
            }
            if selectedDocument != nil && pageItems.isEmpty {
                loadPages(for: selectedDocument)
            }
        }
        .onChange(of: selectedDocument) { newDoc in
            loadPages(for: newDoc)
        }
        .alert("Rearrange PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func loadPages(for document: Document?) {
        pageItems.removeAll()
        guard let document,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else { return }

        var items: [PDFPageItem] = []
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index) {
                let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
                items.append(PDFPageItem(index: index, thumbnail: thumb))
            }
        }
        pageItems = items
    }

    private func saveRearranged() {
        guard let document = selectedDocument,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else { return }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            let newPDF = PDFDocument()
            var insertIndex = 0
            for item in pageItems {
                if let page = pdf.page(at: item.index) {
                    newPDF.insert(page, at: insertIndex)
                    insertIndex += 1
                }
            }
            guard let outData = newPDF.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to save rearranged PDF."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_rearranged"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Rearranged PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

struct PDFPageItem: Identifiable {
    let id = UUID()
    let index: Int
    let thumbnail: UIImage
}

// MARK: - Crop

struct CropPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var didAutoPresent = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var workingPDF: PDFDocument?
    @State private var pageThumbnails: [UIImage] = []
    @State private var currentPageIndex = 0
    @State private var cropValuesByPage: [Int: PageCropValues] = [:]

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    private var pageCount: Int {
        workingPDF?.pageCount ?? 0
    }

    private var currentCrop: PageCropValues {
        get { cropValuesByPage[currentPageIndex] ?? .zero }
        set { cropValuesByPage[currentPageIndex] = newValue }
    }

    private var currentPageSummary: String {
        guard let pdf = workingPDF,
              currentPageIndex >= 0,
              currentPageIndex < pdf.pageCount,
              let page = pdf.page(at: currentPageIndex) else { return "" }
        let bounds = page.bounds(for: .mediaBox)
        let insets = currentCrop.absoluteInsets(in: bounds)
        let cropped = bounds.inset(by: insets)
        let width = Int(max(1, cropped.width).rounded())
        let height = Int(max(1, cropped.height).rounded())
        return "\(width) × \(height) pt"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                if let document = selectedDocument {
                    HStack {
                        Text(document.title)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        if allowsPicker {
                            Button("Change") { showingPicker = true }
                        }
                    }

                    if pageCount > 0 {
                        pagePicker
                        pagePreview
                        Text("Drag the handles to keep the area you want.")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Text("Current output size: \(currentPageSummary)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)

                        Button("Apply This Crop To All Pages") {
                            applyCurrentCropToAllPages()
                        }
                        .buttonStyle(.bordered)
                    }
                } else {
                    if allowsPicker {
                        Button("Choose PDF") { showingPicker = true }
                    } else {
                        Text("No PDF selected.")
                            .foregroundColor(.secondary)
                    }
                }

                Button(isSaving ? "Cropping..." : "Save Cropped PDF") {
                    saveCroppedPDF()
                }
                .buttonStyle(.borderedProminent)
                .tint(Color("Primary"))
                .disabled(selectedDocument == nil || workingPDF == nil || isSaving)
            }
            .padding()
        }
        .navigationTitle("Crop PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            if autoPresentPicker, !didAutoPresent {
                didAutoPresent = true
                DispatchQueue.main.async {
                    showingPicker = true
                }
            }
            if selectedDocument != nil && workingPDF == nil {
                loadDocument(for: selectedDocument)
            }
        }
        .onChange(of: selectedDocument) { newDoc in
            loadDocument(for: newDoc)
        }
        .alert("Crop PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private var pagePicker: some View {
        HStack(spacing: 12) {
            Button {
                currentPageIndex = max(0, currentPageIndex - 1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(currentPageIndex == 0)

            Text("Page \(currentPageIndex + 1) / \(pageCount)")
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity)

            Button {
                currentPageIndex = min(max(0, pageCount - 1), currentPageIndex + 1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(currentPageIndex >= pageCount - 1)
        }
    }

    private var pagePreview: some View {
        Group {
            if currentPageIndex < pageThumbnails.count, currentPageSize.width > 0, currentPageSize.height > 0 {
                InteractiveCropPageView(
                    image: pageThumbnails[currentPageIndex],
                    pageSize: currentPageSize,
                    crop: currentCropBinding()
                )
                .frame(height: 360)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(.separator), lineWidth: 1)
                )
            }
        }
    }

    private var currentPageSize: CGSize {
        guard let pdf = workingPDF,
              currentPageIndex >= 0,
              currentPageIndex < pdf.pageCount,
              let page = pdf.page(at: currentPageIndex) else { return .zero }
        return page.bounds(for: .mediaBox).size
    }

    private func currentCropBinding() -> Binding<PageCropValues> {
        let pageIndex = currentPageIndex
        return Binding(
            get: { cropValuesByPage[pageIndex] ?? .zero },
            set: { values in
                var values = values
                values.clamp()
                cropValuesByPage[pageIndex] = values
            }
        )
    }

    private func loadDocument(for document: Document?) {
        pageThumbnails.removeAll()
        cropValuesByPage.removeAll()
        currentPageIndex = 0
        guard let document,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else {
            workingPDF = nil
            return
        }
        workingPDF = pdf
        var thumbs: [UIImage] = []
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index) {
                thumbs.append(page.thumbnail(of: CGSize(width: 220, height: 300), for: .mediaBox))
            }
            cropValuesByPage[index] = .zero
        }
        pageThumbnails = thumbs
    }

    private func applyCurrentCropToAllPages() {
        guard pageCount > 0 else { return }
        for index in 0..<pageCount {
            cropValuesByPage[index] = currentCrop
        }
    }

    private func saveCroppedPDF() {
        guard let document = selectedDocument,
              let sourceData = pdfData(from: document),
              let pdf = PDFDocument(data: sourceData) else {
            alertMessage = "Please choose a valid PDF first."
            showingAlert = true
            return
        }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let cropValues = cropValuesByPage

        let workItem = DispatchWorkItem {
            let croppedPDF = PDFDocument()
            for index in 0..<pdf.pageCount {
                guard let sourcePage = pdf.page(at: index),
                      let copiedPage = sourcePage.copy() as? PDFPage else { continue }

                let mediaBox = copiedPage.bounds(for: .mediaBox)
                let cropValuesForPage = cropValues[index] ?? .zero
                let insets = cropValuesForPage.absoluteInsets(in: mediaBox)
                var cropRect = mediaBox.inset(by: insets)
                if cropRect.width < 8 || cropRect.height < 8 {
                    cropRect = mediaBox
                }

                copiedPage.setBounds(cropRect, for: .cropBox)
                croppedPDF.insert(copiedPage, at: croppedPDF.pageCount)
            }
            guard let outData = croppedPDF.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to crop PDF."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_cropped"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Cropped PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

private struct PageCropValues {
    var topFraction: Double = 0
    var bottomFraction: Double = 0
    var leftFraction: Double = 0
    var rightFraction: Double = 0

    static let zero = PageCropValues()

    mutating func clamp() {
        topFraction = min(max(0, topFraction), 0.45)
        bottomFraction = min(max(0, bottomFraction), 0.45)
        leftFraction = min(max(0, leftFraction), 0.45)
        rightFraction = min(max(0, rightFraction), 0.45)

        if topFraction + bottomFraction > 0.9 {
            let scale = 0.9 / (topFraction + bottomFraction)
            topFraction *= scale
            bottomFraction *= scale
        }
        if leftFraction + rightFraction > 0.9 {
            let scale = 0.9 / (leftFraction + rightFraction)
            leftFraction *= scale
            rightFraction *= scale
        }
    }

    func absoluteInsets(in bounds: CGRect) -> UIEdgeInsets {
        UIEdgeInsets(
            top: bounds.height * topFraction,
            left: bounds.width * leftFraction,
            bottom: bounds.height * bottomFraction,
            right: bounds.width * rightFraction
        )
    }
}

private struct InteractiveCropPageView: View {
    let image: UIImage
    let pageSize: CGSize
    @Binding var crop: PageCropValues
    private let minKeepFraction: Double = 0.1
    private let handleSize: CGFloat = 26

    var body: some View {
        GeometryReader { proxy in
            let contentRect = aspectFitRect(in: proxy.size, contentSize: pageSize)
            let keepRect = keepRect(in: contentRect)

            ZStack {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(width: proxy.size.width, height: proxy.size.height)

                Path { path in
                    path.addRect(CGRect(origin: .zero, size: proxy.size))
                    path.addRect(keepRect)
                }
                .fill(Color.black.opacity(0.32), style: FillStyle(eoFill: true))

                Path { path in
                    path.addRect(keepRect)
                }
                .stroke(Color("Primary"), lineWidth: 2)

                handle(at: CGPoint(x: keepRect.minX, y: keepRect.midY))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = value.location.x.clamped(to: contentRect.minX...keepRect.maxX - contentRect.width * minKeepFraction)
                        crop.leftFraction = ((x - contentRect.minX) / contentRect.width).clamped(to: 0...(1 - crop.rightFraction - minKeepFraction))
                        crop.clamp()
                    })

                handle(at: CGPoint(x: keepRect.maxX, y: keepRect.midY))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let x = value.location.x.clamped(to: keepRect.minX + contentRect.width * minKeepFraction...contentRect.maxX)
                        crop.rightFraction = ((contentRect.maxX - x) / contentRect.width).clamped(to: 0...(1 - crop.leftFraction - minKeepFraction))
                        crop.clamp()
                    })

                handle(at: CGPoint(x: keepRect.midX, y: keepRect.minY))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let y = value.location.y.clamped(to: contentRect.minY...keepRect.maxY - contentRect.height * minKeepFraction)
                        crop.topFraction = ((y - contentRect.minY) / contentRect.height).clamped(to: 0...(1 - crop.bottomFraction - minKeepFraction))
                        crop.clamp()
                    })

                handle(at: CGPoint(x: keepRect.midX, y: keepRect.maxY))
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let y = value.location.y.clamped(to: keepRect.minY + contentRect.height * minKeepFraction...contentRect.maxY)
                        crop.bottomFraction = ((contentRect.maxY - y) / contentRect.height).clamped(to: 0...(1 - crop.topFraction - minKeepFraction))
                        crop.clamp()
                    })
            }
        }
    }

    private func keepRect(in contentRect: CGRect) -> CGRect {
        let left = contentRect.width * crop.leftFraction
        let right = contentRect.width * crop.rightFraction
        let top = contentRect.height * crop.topFraction
        let bottom = contentRect.height * crop.bottomFraction
        return CGRect(
            x: contentRect.minX + left,
            y: contentRect.minY + top,
            width: max(1, contentRect.width - left - right),
            height: max(1, contentRect.height - top - bottom)
        )
    }

    private func handle(at point: CGPoint) -> some View {
        Circle()
            .fill(Color(.systemBackground))
            .frame(width: handleSize, height: handleSize)
            .overlay(
                Circle()
                    .stroke(Color("Primary"), lineWidth: 2)
            )
            .position(point)
            .shadow(radius: 1)
    }

    private func aspectFitRect(in container: CGSize, contentSize: CGSize) -> CGRect {
        guard container.width > 0, container.height > 0, contentSize.width > 0, contentSize.height > 0 else {
            return CGRect(origin: .zero, size: container)
        }
        let scale = min(container.width / contentSize.width, container.height / contentSize.height)
        let drawSize = CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
        let origin = CGPoint(
            x: (container.width - drawSize.width) / 2,
            y: (container.height - drawSize.height) / 2
        )
        return CGRect(origin: origin, size: drawSize)
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

// MARK: - Rotate

struct RotatePDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    let allowsPicker: Bool
    let onComplete: (([Document]) -> Void)?
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [RotatePageItem] = []
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(
        autoPresentPicker: Bool = false,
        preselectedDocument: Document? = nil,
        allowsPicker: Bool = true,
        onComplete: (([Document]) -> Void)? = nil
    ) {
        self.autoPresentPicker = autoPresentPicker && allowsPicker
        self.allowsPicker = allowsPicker
        self.onComplete = onComplete
        _selectedDocument = State(initialValue: preselectedDocument)
    }

    var body: some View {
        VStack(spacing: 12) {
            if let document = selectedDocument {
                HStack {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if allowsPicker {
                        Button("Change") { showingPicker = true }
                    }
                }
                .padding(.horizontal)
            } else {
                if allowsPicker {
                    Button("Choose PDF") { showingPicker = true }
                } else {
                    Text("No PDF selected.")
                        .foregroundColor(.secondary)
                }
            }

            if !pageItems.isEmpty {
                List {
                    ForEach(pageItems.indices, id: \.self) { idx in
                        HStack(spacing: 12) {
                            Image(uiImage: rotatedThumbnail(for: pageItems[idx]))
                                .resizable()
                                .scaledToFit()
                                .frame(height: 70)
                                .cornerRadius(6)
                            Text("Page \(pageItems[idx].index + 1)")
                                .foregroundColor(.secondary)
                            Spacer()
                            Button {
                                rotatePage(at: idx, delta: -90)
                            } label: {
                                Image(systemName: "rotate.left")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                            Button {
                                rotatePage(at: idx, delta: 90)
                            } label: {
                                Image(systemName: "rotate.right")
                            }
                            .buttonStyle(BorderlessButtonStyle())
                        }
                    }
                }
            }

            Button(isSaving ? "Saving..." : "Save Rotations") {
                saveRotations()
            }
            .disabled(selectedDocument == nil || pageItems.isEmpty || isSaving)
            .padding(.bottom, 12)
        }
        .navigationTitle("Rotate PDF")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingPicker) {
            PDFSinglePickerSheet(
                documents: documentManager.documents.filter { isPDFDocument($0) },
                selectedDocument: $selectedDocument
            )
        }
        .onAppear {
            if autoPresentPicker, !didAutoPresent {
                didAutoPresent = true
                DispatchQueue.main.async {
                    showingPicker = true
                }
            }
            if selectedDocument != nil && pageItems.isEmpty {
                loadPages(for: selectedDocument)
            }
        }
        .onChange(of: selectedDocument) { newDoc in
            loadPages(for: newDoc)
        }
        .alert("Rotate PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
        .bindGlobalOperationLoading(isSaving)
    }

    private func loadPages(for document: Document?) {
        pageItems.removeAll()
        guard let document,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else { return }

        var items: [RotatePageItem] = []
        for index in 0..<pdf.pageCount {
            if let page = pdf.page(at: index) {
                let thumb = page.thumbnail(of: CGSize(width: 120, height: 160), for: .mediaBox)
                let rotation = page.rotation
                items.append(RotatePageItem(index: index, thumbnail: thumb, rotation: rotation))
            }
        }
        pageItems = items
    }

    private func rotatePage(at index: Int, delta: Int) {
        let newRotation = (pageItems[index].rotation + delta + 360) % 360
        pageItems[index].rotation = newRotation
    }

    private func rotatedThumbnail(for item: RotatePageItem) -> UIImage {
        guard item.rotation % 360 != 0 else { return item.thumbnail }
        let radians = CGFloat(item.rotation) * .pi / 180
        let size = item.thumbnail.size
        let isQuarterTurn = (item.rotation / 90) % 2 != 0
        let newSize = isQuarterTurn ? CGSize(width: size.height, height: size.width) : size

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { ctx in
            ctx.cgContext.translateBy(x: newSize.width / 2, y: newSize.height / 2)
            ctx.cgContext.rotate(by: radians)
            ctx.cgContext.translateBy(x: -size.width / 2, y: -size.height / 2)
            item.thumbnail.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    private func saveRotations() {
        guard let document = selectedDocument,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else { return }

        isSaving = true
        let initialTitles = existingDocumentTitles(in: documentManager)
        let workItem = DispatchWorkItem {
            for item in pageItems {
                if let page = pdf.page(at: item.index) {
                    page.rotation = item.rotation
                }
            }

            guard let outData = pdf.dataRepresentation() else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to save rotated PDF."
                    showingAlert = true
                }
                return
            }

            var existingTitles = initialTitles
            let base = baseTitle(for: document.title)
            let preferredBase = "\(base)_rotated"
            let title = uniquePDFTitle(preferredBase: preferredBase, existingTitles: existingTitles)
            existingTitles.insert(title.lowercased())
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                if let onComplete {
                    onComplete([newDoc])
                } else {
                    alertMessage = "Rotated PDF saved to Documents."
                    showingAlert = true
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

struct RotatePageItem: Identifiable {
    let id = UUID()
    let index: Int
    let thumbnail: UIImage
    var rotation: Int
}

// MARK: - Pickers

struct PDFSinglePickerSheet: View {
    let documents: [Document]
    @Binding var selectedDocument: Document?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if documents.isEmpty {
                    Text("No PDFs available.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(documents) { document in
                        Button {
                            selectedDocument = document
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: iconForDocumentType(document.type))
                                    .foregroundColor(Color("Primary"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select PDF")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(.primary)
                }
            }
        }
    }
}

struct PDFMultiPickerSheet: View {
    let documents: [Document]
    @Binding var selectedIds: Set<UUID>
    let maxSelection: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            List {
                if documents.isEmpty {
                    Text("No PDFs available.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(documents) { document in
                        Button {
                            toggleSelection(for: document.id)
                        } label: {
                            HStack {
                                Image(systemName: iconForDocumentType(document.type))
                                    .foregroundColor(Color("Primary"))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.headline)
                                        .foregroundColor(.primary)
                                    Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedIds.contains(document.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(Color("Primary"))
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select PDFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundColor(.primary)
                }
            }
        }
    }

    private func toggleSelection(for id: UUID) {
        if selectedIds.contains(id) {
            selectedIds.remove(id)
        } else if selectedIds.count < maxSelection {
            selectedIds.insert(id)
        }
    }
}

// MARK: - Helpers

private func isPDFDocument(_ document: Document) -> Bool {
    document.type == .pdf || document.type == .scanned
}

private func pdfData(from document: Document) -> Data? {
    if let pdfData = document.pdfData { return pdfData }
    if let original = document.originalFileData { return original }
    return nil
}

private func makePDFDocument(title: String, data: Data, sourceDocumentId: UUID?) -> Document {
    let text = extractText(from: data)
    let summaryText = sourceDocumentId == nil
        ? "Processing summary..."
        : DocumentManager.summaryUnavailableMessage
    return Document(
        title: title,
        content: text,
        summary: summaryText,
        ocrPages: nil,
        tags: [],
        sourceDocumentId: sourceDocumentId,
        dateCreated: Date(),
        type: .pdf,
        imageData: nil,
        pdfData: data,
        originalFileData: data
    )
}

private func extractText(from data: Data) -> String {
    guard let pdf = PDFDocument(data: data) else { return "" }
    var text = ""
    for idx in 0..<pdf.pageCount {
        if let page = pdf.page(at: idx), let pageText = page.string {
            text += pageText + "\n"
        }
    }
    return text
}

private func baseTitle(for title: String) -> String {
    let url = URL(fileURLWithPath: title)
    let base = url.deletingPathExtension().lastPathComponent
    return base.isEmpty ? "PDF" : base
}

private func existingDocumentTitles(in documentManager: DocumentManager) -> Set<String> {
    Set(documentManager.documents.map { $0.title.lowercased() })
}

private func uniquePDFTitle(preferredBase: String, existingTitles: Set<String>) -> String {
    uniqueTitle(preferredBase: preferredBase, ext: "pdf", existingTitles: existingTitles)
}

private func uniqueTitle(preferredBase: String, ext: String, existingTitles: Set<String>) -> String {
    let trimmedBase = preferredBase.trimmingCharacters(in: .whitespacesAndNewlines)
    let base = trimmedBase.isEmpty ? "PDF" : trimmedBase
    let extSuffix = ext.isEmpty ? "" : ".\(ext)"
    var candidate = "\(base)\(extSuffix)"
    let lowerExisting = existingTitles

    if !lowerExisting.contains(candidate.lowercased()) {
        return candidate
    }

    var idx = 2
    while true {
        candidate = "\(base)\(idx)\(extSuffix)"
        if !lowerExisting.contains(candidate.lowercased()) {
            return candidate
        }
        idx += 1
    }
}
