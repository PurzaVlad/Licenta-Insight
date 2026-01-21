import SwiftUI
import PDFKit

struct PDFEditView: View {
    @EnvironmentObject private var documentManager: DocumentManager

    var body: some View {
        NavigationView {
            List {
                NavigationLink {
                    MergePDFsView()
                        .environmentObject(documentManager)
                } label: {
                    Label("Merge PDFs", systemImage: "square.on.square")
                }

                NavigationLink {
                    SplitPDFView()
                        .environmentObject(documentManager)
                } label: {
                    Label("Split PDF", systemImage: "scissors")
                }

                NavigationLink {
                    RearrangePDFView()
                        .environmentObject(documentManager)
                } label: {
                    Label("Rearrange PDF", systemImage: "arrow.up.arrow.down")
                }

                NavigationLink {
                    RotatePDFView()
                        .environmentObject(documentManager)
                } label: {
                    Label("Rotate PDF Pages", systemImage: "rotate.right")
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text(" PDFEdit ")
                        .font(.headline)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

// MARK: - Merge

struct MergePDFsView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var selectedIds: Set<UUID> = []
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    private var pdfDocuments: [Document] {
        documentManager.documents.filter { isPDFDocument($0) }
    }

    private var selectedDocuments: [Document] {
        pdfDocuments.filter { selectedIds.contains($0.id) }
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
                Button("Choose PDFs") {
                    showingPicker = true
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
        .alert("Merge PDFs", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
    }

    private func mergeSelected() {
        guard selectedDocuments.count >= 2 else { return }
        isSaving = true

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

            let title = "Merged PDF \(shortDateString())"
            let newDoc = makePDFDocument(title: title, data: data)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                selectedIds.removeAll()
                alertMessage = "Merged PDF saved to Documents."
                showingAlert = true
            }
        }
        DispatchQueue.global(qos: .userInitiated).async(execute: workItem)
    }
}

// MARK: - Split

struct SplitPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var ranges: [PageRangeInput] = [PageRangeInput()]
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

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
                        Button("Change") { showingPicker = true }
                    }
                    Text("Pages: \(pageCount)")
                        .foregroundColor(.secondary)
                } else {
                    Button("Choose PDF") { showingPicker = true }
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
        .alert("Split PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
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

        let workItem = DispatchWorkItem {
            var created = 0
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
                let title = "\(base)_Part\(idx + 1).pdf"
                let newDoc = makePDFDocument(title: title, data: outData)
                DispatchQueue.main.async {
                    documentManager.addDocument(newDoc)
                }
                created += 1
                if created >= 3 { break }
            }

            DispatchQueue.main.async {
                isSaving = false
                alertMessage = created > 0 ? "Created \(created) PDFs." : "Failed to split PDF."
                showingAlert = true
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
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [PDFPageItem] = []
    @State private var editMode: EditMode = .active
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            if let document = selectedDocument {
                HStack {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button("Change") { showingPicker = true }
                }
                .padding(.horizontal)
            } else {
                Button("Choose PDF") { showingPicker = true }
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
        .onChange(of: selectedDocument) { newDoc in
            loadPages(for: newDoc)
        }
        .alert("Rearrange PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
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

            let base = baseTitle(for: document.title)
            let title = "\(base)_Rearranged.pdf"
            let newDoc = makePDFDocument(title: title, data: outData)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                alertMessage = "Rearranged PDF saved to Documents."
                showingAlert = true
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

// MARK: - Rotate

struct RotatePDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [RotatePageItem] = []
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""

    var body: some View {
        VStack(spacing: 12) {
            if let document = selectedDocument {
                HStack {
                    Text(document.title)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Button("Change") { showingPicker = true }
                }
                .padding(.horizontal)
            } else {
                Button("Choose PDF") { showingPicker = true }
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
        .onChange(of: selectedDocument) { newDoc in
            loadPages(for: newDoc)
        }
        .alert("Rotate PDF", isPresented: $showingAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage)
        }
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

            let base = baseTitle(for: document.title)
            let title = "\(base)_Rotated.pdf"
            let newDoc = makePDFDocument(title: title, data: outData)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                alertMessage = "Rotated PDF saved to Documents."
                showingAlert = true
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
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.headline)
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
                                    .foregroundColor(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(document.title)
                                        .font(.headline)
                                    Text(fileTypeLabel(documentType: document.type, titleParts: splitDisplayTitle(document.title)))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                if selectedIds.contains(document.id) {
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.blue)
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

private func makePDFDocument(title: String, data: Data) -> Document {
    let text = extractText(from: data)
    return Document(
        title: title,
        content: text,
        summary: "Processing summary...",
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
        if let page = pdf.page(at: idx) {
            if let pageText = page.string {
                text += pageText + "\n"
            }
        }
    }
    return text.trimmingCharacters(in: .whitespacesAndNewlines)
}

private func baseTitle(for title: String) -> String {
    let url = URL(fileURLWithPath: title)
    let base = url.deletingPathExtension().lastPathComponent
    return base.isEmpty ? "PDF" : base
}

private func shortDateString() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmm"
    return formatter.string(from: Date())
}
