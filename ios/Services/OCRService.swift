import Foundation
import UIKit
import Vision
import PDFKit

class OCRService {
    static let shared = OCRService()

    private let maxImageDimension = AppConstants.Limits.maxOCRImageDimension

    private init() {}

    // MARK: - OCR Processing

    /// Performs OCR on an image and returns structured OCR data
    func performOCR(on image: UIImage, pageIndex: Int) -> (text: String, page: OCRPage) {
        guard let processedImage = preprocessImage(image),
              let cgImage = processedImage.cgImage else {
            print("⚠️ OCRService: Failed to process image")
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
                let observations = results.compactMap { result -> (String, CGRect, Double)? in
                    guard let top = result.topCandidates(1).first else { return nil }
                    return (top.string, result.boundingBox, Double(top.confidence))
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
            } else {
                print("⚠️ OCRService: No results returned")
            }
        } catch {
            print("❌ OCRService: \(error.localizedDescription)")
            recognizedText = "OCR failed: \(error.localizedDescription)"
        }

        let cleaned = recognizedText.isEmpty ? "No text found in image" : recognizedText
        return (cleaned, OCRPage(pageIndex: pageIndex, blocks: blocks))
    }

    /// Builds structured, formatted text from OCR pages
    func buildStructuredText(from pages: [OCRPage], includePageLabels: Bool) -> String {
        guard !pages.isEmpty else { return "" }

        func paragraphize(_ lines: [(text: String, y: Double)]) -> String {
            var output: [String] = []
            var lastY: Double? = nil

            for line in lines {
                if let last = lastY, abs(line.y - last) > 0.04 {
                    output.append("")
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

    /// Preprocesses an image for OCR by resizing if needed
    func preprocessImage(_ image: UIImage, maxDimension: CGFloat? = nil) -> UIImage? {
        guard image.cgImage != nil else { return nil }

        let targetSize = maxDimension ?? self.maxImageDimension
        let imageSize = image.size
        let maxDim = max(imageSize.width, imageSize.height)

        if maxDim > targetSize {
            let scale = targetSize / maxDim
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

    /// Builds OCR pages from data (for images or PDFs)
    func buildVisionOCRPages(from data: Data, type: Document.DocumentType) -> [OCRPage]? {
        switch type {
        case .image, .scanned:
            guard let image = UIImage(data: data) else { return nil }
            let result = performOCR(on: image, pageIndex: 0)
            return [result.page]
        case .pdf:
            guard let pdf = PDFDocument(data: data) else { return nil }
            var pages: [OCRPage] = []
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index),
                      let image = renderPDFPageForOCR(page) else { continue }
                let result = performOCR(on: image, pageIndex: index)
                pages.append(result.page)
            }
            return pages.isEmpty ? nil : pages
        default:
            return nil
        }
    }

    /// Renders a PDF page as an image for OCR processing
    private func renderPDFPageForOCR(_ page: PDFPage) -> UIImage? {
        let pageRect = page.bounds(for: .mediaBox)
        if pageRect.width <= 0 || pageRect.height <= 0 { return nil }

        let targetMax: CGFloat = 2200
        let maxDim = max(pageRect.width, pageRect.height)
        let scale = maxDim > targetMax ? (targetMax / maxDim) : min(2.0, targetMax / maxDim)
        let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

        UIGraphicsBeginImageContextWithOptions(size, true, 1.0)
        guard let context = UIGraphicsGetCurrentContext() else { return nil }

        context.setFillColor(UIColor.white.cgColor)
        context.fill(CGRect(origin: .zero, size: size))
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: scale, y: -scale)
        page.draw(with: .mediaBox, to: context)

        let image = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return image
    }

    /// Creates pseudo-OCR pages from plain text (for text files)
    func buildPseudoOCRPages(from text: String, pageSize: Int = 2000) -> [OCRPage] {
        let lines = text.components(separatedBy: .newlines)
        var pages: [OCRPage] = []
        var currentPageIndex = 0
        var currentPageLines: [String] = []
        var currentCharCount = 0

        for line in lines {
            let lineLength = line.count + 1 // +1 for newline

            if currentCharCount + lineLength > pageSize && !currentPageLines.isEmpty {
                // Create page from current lines
                let pageText = currentPageLines.joined(separator: "\n")
                let blocks = [OCRBlock(
                    text: pageText,
                    confidence: 1.0,
                    bbox: OCRBoundingBox(x: 0, y: 0, width: 1, height: 1),
                    order: 0
                )]
                pages.append(OCRPage(pageIndex: currentPageIndex, blocks: blocks))

                // Start new page
                currentPageIndex += 1
                currentPageLines = [line]
                currentCharCount = lineLength
            } else {
                currentPageLines.append(line)
                currentCharCount += lineLength
            }
        }

        // Add final page if there are remaining lines
        if !currentPageLines.isEmpty {
            let pageText = currentPageLines.joined(separator: "\n")
            let blocks = [OCRBlock(
                text: pageText,
                confidence: 1.0,
                bbox: OCRBoundingBox(x: 0, y: 0, width: 1, height: 1),
                order: 0
            )]
            pages.append(OCRPage(pageIndex: currentPageIndex, blocks: blocks))
        }

        return pages
    }

    /// Extracts text from an image file
    func extractTextFromImage(at url: URL) -> (text: String, pages: [OCRPage]?) {
        guard let image = UIImage(contentsOfFile: url.path) else {
            return ("Could not load image", nil)
        }
        let result = performOCR(on: image, pageIndex: 0)
        let structured = buildStructuredText(from: [result.page], includePageLabels: false)
        return (structured.isEmpty ? result.text : structured, [result.page])
    }
}
