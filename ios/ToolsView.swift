import SwiftUI
import PDFKit

struct ToolsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var showingSettings = false

    var body: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 12) {
                        SectionHeader(title: "Organize")
                        ToolRow(
                            icon: "rectangle.portrait.on.rectangle.portrait.fill",
                            title: "Merge PDF"
                        ) {
                            MergePDFsView(autoPresentPicker: true)
                                .environmentObject(documentManager)
                        }
                        ToolRow(
                            icon: "rectangle.split.2x1.fill",
                            title: "Split PDF"
                        ) {
                            SplitPDFView(autoPresentPicker: true)
                                .environmentObject(documentManager)
                        }
                        ToolRow(
                            icon: "line.3.horizontal.decrease",
                            title: "Arrange PDF"
                        ) {
                            RearrangePDFView(autoPresentPicker: true)
                                .environmentObject(documentManager)
                        }

                        SectionHeader(title: "Modify")
                        ToolRow(
                            icon: "rectangle.portrait.rotate",
                            title: "Rotate PDF"
                        ) {
                            RotatePDFView(autoPresentPicker: true)
                                .environmentObject(documentManager)
                        }
                        ToolRow(
                            icon: "arrow.down.right.and.arrow.up.left",
                            title: "Compress PDF"
                        ) {
                            CompressPDFView(autoPresentPicker: true)
                                .environmentObject(documentManager)
                        }
                        ToolRow(icon: "pencil", title: "Edit PDF") {
                            ComingSoonView(title: "Edit PDF")
                        }

                        SectionHeader(title: "Protect & Sign")
                        ToolRow(icon: "signature", title: "Sign PDF") {
                            SignPDFView(autoPresentPicker: true)
                                .environmentObject(documentManager)
                        }
                        ToolRow(icon: "lock.fill", title: "Protect PDF") {
                            ComingSoonView(title: "Protect PDF")
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color(.systemBackground))
                    )
                    .padding(.horizontal, 16)

                    Spacer()
                }
                .padding(.top, 8)
            }
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
            }
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

    init(icon: String, title: String, @ViewBuilder destination: () -> Destination) {
        self.icon = icon
        self.title = title
        self.destination = destination()
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
        Divider()
    }
}

struct CompressPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    @State private var didAutoPresent = false
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var quality: Double = 0.7

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
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

                Button("Choose Different PDF") { showingPicker = true }
                    .foregroundColor(.secondary)
            } else {
                Button("Choose PDF") { showingPicker = true }
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
        let baseName = splitDisplayTitle(document.title).base
        let outputName = baseName.isEmpty ? "Compressed PDF" : "\(baseName)_Compressed"

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
                alertMessage = "Compressed PDF saved to Documents."
                showingAlert = true
            }
        }
    }
}

struct ProtectPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    @State private var didAutoPresent = false
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
    }

    var body: some View {
        VStack(spacing: 16) {
            if let document = selectedDocument {
                Text(document.title)
                    .font(.headline)
                    .lineLimit(1)

                SecureField("Password", text: $password)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)
                SecureField("Confirm password", text: $confirmPassword)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .padding(.horizontal)

                Button(isSaving ? "Protecting..." : "Protect PDF") {
                    protectSelected()
                }
                .disabled(isSaving)

                Button("Choose Different PDF") { showingPicker = true }
                    .foregroundColor(.secondary)
            } else {
                Button("Choose PDF") { showingPicker = true }
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
    }

    private func protectSelected() {
        guard let document = selectedDocument,
              let data = pdfData(from: document),
              let pdf = PDFDocument(data: data) else {
            alertMessage = "Please choose a PDF first."
            showingAlert = true
            return
        }

        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedConfirm = confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            alertMessage = "Password cannot be empty."
            showingAlert = true
            return
        }
        guard trimmed == trimmedConfirm else {
            alertMessage = "Passwords do not match."
            showingAlert = true
            return
        }

        isSaving = true
        let baseName = splitDisplayTitle(document.title).base
        let outputName = baseName.isEmpty ? "Protected PDF" : "\(baseName)_Protected"

        DispatchQueue.global(qos: .userInitiated).async {
            let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).pdf")
            let options: [PDFDocumentWriteOption: Any] = [
                .userPasswordOption: trimmed,
                .ownerPasswordOption: trimmed
            ]

            let success = pdf.write(to: tempURL, withOptions: options)
            guard success, let outData = try? Data(contentsOf: tempURL) else {
                DispatchQueue.main.async {
                    isSaving = false
                    alertMessage = "Failed to protect PDF."
                    showingAlert = true
                }
                return
            }

            let newDoc = makePDFDocument(title: outputName, data: outData, sourceDocumentId: document.id)
            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                alertMessage = "Protected PDF saved to Documents."
                showingAlert = true
            }
        }
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
