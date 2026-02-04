import SwiftUI
import PDFKit
import UIKit

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
                    Label("Rearrange pages", systemImage: "arrow.up.arrow.down")
                }

                NavigationLink {
                    RotatePDFView()
                        .environmentObject(documentManager)
                } label: {
                    Label("Rotate Pages", systemImage: "rotate.right")
                }

                NavigationLink {
                    SignPDFView()
                        .environmentObject(documentManager)
                } label: {
                    Label("Sign PDF", systemImage: "pencil.tip")
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

// MARK: - Sign PDF

struct SignPDFView: View {
    @EnvironmentObject private var documentManager: DocumentManager
    let autoPresentPicker: Bool
    @StateObject private var signatureStore = SignatureStore()
    @StateObject private var pdfController = PDFSigningController()
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var showingSignatureSheet = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
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
                Button("Choose PDF") { showingPicker = true }
                    .padding(.horizontal)
                    .padding(.top, 6)
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
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
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
        let workItem = DispatchWorkItem {
            let base = baseTitle(for: document.title)
            let title = "\(base)_Signed.pdf"
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

            DispatchQueue.main.async {
                documentManager.addDocument(newDoc)
                isSaving = false
                alertMessage = "Signed PDF saved to Documents."
                showingAlert = true
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
    @State private var selectedIds: Set<UUID> = []
    @State private var showingPicker = false
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
    }

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
            let newDoc = makePDFDocument(title: title, data: data, sourceDocumentId: nil)

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
    let autoPresentPicker: Bool
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var ranges: [PageRangeInput] = [PageRangeInput()]
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
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
                let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)
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
    let autoPresentPicker: Bool
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [PDFPageItem] = []
    @State private var editMode: EditMode = .active
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
    }

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
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
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
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

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
    let autoPresentPicker: Bool
    @State private var selectedDocument: Document?
    @State private var showingPicker = false
    @State private var pageItems: [RotatePageItem] = []
    @State private var isSaving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var didAutoPresent = false

    init(autoPresentPicker: Bool = false) {
        self.autoPresentPicker = autoPresentPicker
    }

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
        .onAppear {
            guard autoPresentPicker, !didAutoPresent else { return }
            didAutoPresent = true
            DispatchQueue.main.async {
                showingPicker = true
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
            let newDoc = makePDFDocument(title: title, data: outData, sourceDocumentId: document.id)

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
