import Foundation
import UIKit
import PDFKit
import QuickLook

struct ProcessedFileResult {
    let content: String
    let ocrPages: [OCRPage]?
    let documentType: Document.DocumentType
    let imageData: [Data]?
    let pdfData: Data?
    let originalFileData: Data?
}

class FileProcessingService {
    static let shared = FileProcessingService()

    private let ocrService = OCRService.shared
    private let maxOCRChars = AppConstants.Limits.maxOCRChars

    private init() {}

    // MARK: - Main Processing

    /// Processes a file at the given URL and returns extracted content and metadata
    func processFile(at url: URL) throws -> ProcessedFileResult {
        print("📄 FileProcessingService: Processing \(url.lastPathComponent)")

        // Try to start accessing security scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = url.pathExtension.lowercased()
        print("📄 FileProcessingService: File type: \(fileExtension)")

        var content = ""
        var ocrPages: [OCRPage]? = nil
        var documentType: Document.DocumentType = .text

        // Extract content based on file type
        switch fileExtension {
        case "pdf":
            content = extractTextFromPDF(url: url)
            documentType = .pdf
        case "txt", "rtf":
            content = extractTextFromTXT(url: url)
            documentType = .text
        case "jpg", "jpeg", "png", "heic":
            content = "Imported image file. OCR extraction is skipped for image documents."
            ocrPages = nil
            documentType = .image
        case "docx", "doc":
            content = extractTextFromWordDocument(url: url)
            documentType = .docx
        case "json":
            content = extractTextFromJSON(url: url)
            documentType = .text
        case "xml":
            content = extractTextFromXML(url: url)
            documentType = .text
        case "zip":
            content = "ZIP archive"
            documentType = .zip
        case "ppt":
            let result = extractTextFromPresentationViaOCR(url: url)
            content = result.text.isEmpty ? "PowerPoint document - text extraction is limited on this file." : result.text
            ocrPages = result.pages
            documentType = .ppt
        case "pptx":
            let parsed = extractTextFromPPTXArchive(url: url)
            if !parsed.isEmpty {
                content = parsed
                ocrPages = nil
            } else {
                let result = extractTextFromPresentationViaOCR(url: url)
                content = result.text.isEmpty ? "PowerPoint document - text extraction is limited on this file." : result.text
                ocrPages = result.pages
            }
            documentType = .pptx
        case "xls":
            content = extractTextFromSpreadsheetViaOCR(url: url)
            documentType = .xls
        case "xlsx":
            content = "Imported XLSX spreadsheet. OCR extraction is skipped for XLSX documents."
            documentType = .xlsx
        default:
            throw FileProcessingError.unsupportedFormat(fileExtension)
        }

        print("📄 FileProcessingService: Content extracted (\(content.count) chars)")

        // Truncate if too long
        if content.count > maxOCRChars {
            content = Self.truncateText(content, maxChars: maxOCRChars)
        }

        // Build pseudo-OCR pages if needed
        if ocrPages == nil && shouldAutoOCR(for: documentType) {
            ocrPages = ocrService.buildPseudoOCRPages(from: content)
        }

        // Read file data for preview
        var imageData: [Data]? = nil
        var pdfData: Data? = nil
        var originalFileData: Data? = nil

        do {
            let fileData = try Data(contentsOf: url)
            print("📄 FileProcessingService: Read \(fileData.count) bytes")

            // Always store original file data for QuickLook preview
            originalFileData = fileData

            switch fileExtension {
            case "pdf":
                pdfData = fileData
            case "jpg", "jpeg", "png", "heic", "gif", "bmp", "tiff":
                imageData = [fileData]
            default:
                break
            }
        } catch {
            print("⚠️ FileProcessingService: Could not read file data: \(error.localizedDescription)")
        }

        return ProcessedFileResult(
            content: content,
            ocrPages: ocrPages,
            documentType: documentType,
            imageData: imageData,
            pdfData: pdfData,
            originalFileData: originalFileData
        )
    }

    // MARK: - Text Extraction Methods

    private func extractTextFromPDF(url: URL) -> String {
        guard let pdfDocument = PDFDocument(url: url) else {
            return "Could not read PDF file"
        }

        var text = ""
        for pageIndex in 0..<pdfDocument.pageCount {
            if let page = pdfDocument.page(at: pageIndex) {
                text += page.string ?? ""
                text += "\n\n"
            }
        }

        return text.isEmpty ? "No text found in PDF" : text
    }

    private func extractTextFromTXT(url: URL) -> String {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            return content
        } catch {
            return "Could not read text file: \(error.localizedDescription)"
        }
    }

    private func extractTextFromWordDocument(url: URL) -> String {
        print("📄 FileProcessingService: Extracting Word document")
        let ext = url.pathExtension.lowercased()

        // Preferred: Parse DOCX XML and extract <w:t> text nodes
        if ext == "docx" {
            let parsed = extractTextFromDOCXArchive(url: url)
            let cleaned = formatExtractedText(parsed)
            if !cleaned.isEmpty && !looksLikeXML(cleaned) {
                print("📄 FileProcessingService: Using DOCX parsed text (\(cleaned.count) chars)")
                return cleaned
            }
        }

        // Fallback: OCR a rendered thumbnail
        if let ocrText = extractTextFromDOCXViaOCR(url: url), !ocrText.isEmpty, !ocrText.contains("OCR failed") {
            print("📄 FileProcessingService: Using OCR text (\(ocrText.count) chars)")
            return formatExtractedText(ocrText)
        }

        // Last resort placeholder
        print("📄 FileProcessingService: No readable text extracted")
        return "Imported Word document. Text extraction is limited on this file."
    }

    private func extractTextFromDOCXArchive(url: URL) -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_extract_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {
            print("⚠️ FileProcessingService: Failed to create temp dir")
            return ""
        }

        var unzipError: NSError?
        let ok = SSZipArchive.unzipFile(atPath: url.path,
                                       toDestination: tempDir.path,
                                       preserveAttributes: false,
                                       overwrite: true,
                                       password: nil,
                                       error: &unzipError,
                                       delegate: nil)
        if !ok {
            if let unzipError = unzipError {
                print("⚠️ FileProcessingService: Unzip failed: \(unzipError.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        let docXML = tempDir.appendingPathComponent("word/document.xml")
        guard let xmlData = try? Data(contentsOf: docXML), let xml = String(data: xmlData, encoding: .utf8) else {
            print("⚠️ FileProcessingService: document.xml missing")
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        var body = ""
        do {
            let re = try NSRegularExpression(pattern: "<w:t[^>]*>(.*?)</w:t>", options: [.dotMatchesLineSeparators])
            let ns = xml as NSString
            let matches = re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
            for m in matches {
                if m.numberOfRanges >= 2 {
                    let t = ns.substring(with: m.range(at: 1))
                        .replacingOccurrences(of: "&amp;", with: "&")
                        .replacingOccurrences(of: "&lt;", with: "<")
                        .replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&quot;", with: "\"")
                        .replacingOccurrences(of: "&apos;", with: "'")
                    body += t
                }
            }
        } catch {
            print("⚠️ FileProcessingService: Regex failed")
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = extractTextFromXMLContent(xml)
            if !cleaned.isEmpty { body = cleaned }
        }

        try? FileManager.default.removeItem(at: tempDir)
        return formatExtractedText(body)
    }

    private func extractTextFromPPTXArchive(url: URL) -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pptx_extract_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {
            return ""
        }

        var unzipError: NSError?
        let ok = SSZipArchive.unzipFile(atPath: url.path,
                                       toDestination: tempDir.path,
                                       preserveAttributes: false,
                                       overwrite: true,
                                       password: nil,
                                       error: &unzipError,
                                       delegate: nil)
        if !ok {
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        let slidesDir = tempDir.appendingPathComponent("ppt/slides", isDirectory: true)
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil) else {
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        let slideFiles = files
            .filter { $0.lastPathComponent.lowercased().hasPrefix("slide") && $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if slideFiles.isEmpty {
            try? FileManager.default.removeItem(at: tempDir)
            return ""
        }

        var collected: [String] = []
        for slideURL in slideFiles {
            guard let xmlData = try? Data(contentsOf: slideURL),
                  let xml = String(data: xmlData, encoding: .utf8) else { continue }

            var body = ""
            do {
                let re = try NSRegularExpression(pattern: "<a:t[^>]*>(.*?)</a:t>", options: [.dotMatchesLineSeparators])
                let ns = xml as NSString
                let matches = re.matches(in: xml, range: NSRange(location: 0, length: ns.length))
                for m in matches {
                    if m.numberOfRanges >= 2 {
                        let t = ns.substring(with: m.range(at: 1))
                            .replacingOccurrences(of: "&amp;", with: "&")
                            .replacingOccurrences(of: "&lt;", with: "<")
                            .replacingOccurrences(of: "&gt;", with: ">")
                            .replacingOccurrences(of: "&quot;", with: "\"")
                            .replacingOccurrences(of: "&apos;", with: "'")
                        body += t + " "
                    }
                }
            } catch {
                print("⚠️ FileProcessingService: PPTX regex failed")
            }

            let cleaned = formatExtractedText(body)
            if !cleaned.isEmpty {
                collected.append(cleaned)
            }
        }

        try? FileManager.default.removeItem(at: tempDir)
        return collected.joined(separator: "\n\n")
    }

    private func extractTextFromJSON(url: URL) -> String {
        do {
            let jsonString = try String(contentsOf: url, encoding: .utf8)

            // Try to pretty-print the JSON
            if let jsonData = jsonString.data(using: .utf8),
               let jsonObject = try? JSONSerialization.jsonObject(with: jsonData, options: []),
               let prettyJsonData = try? JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted]),
               let prettyJsonString = String(data: prettyJsonData, encoding: .utf8) {
                return prettyJsonString
            }

            return jsonString
        } catch {
            return "Could not read JSON file: \(error.localizedDescription)"
        }
    }

    private func extractTextFromXML(url: URL) -> String {
        do {
            let xmlString = try String(contentsOf: url, encoding: .utf8)
            return xmlString.isEmpty ? "No content found in XML file" : xmlString
        } catch {
            return "Could not read XML file: \(error.localizedDescription)"
        }
    }

    // MARK: - OCR-based Extraction

    private func extractTextFromDOCXViaOCR(url: URL) -> String? {
        if let img = generateThumbnail(url: url) {
            let result = ocrService.performOCR(on: img, pageIndex: 0)
            return result.text
        }
        return nil
    }

    private func extractTextFromSpreadsheetViaOCR(url: URL) -> String {
        if let img = generateThumbnail(url: url) {
            let result = ocrService.performOCR(on: img, pageIndex: 0)
            if !result.text.isEmpty && !result.text.contains("OCR failed") {
                return formatExtractedText(result.text)
            }
        }
        return "Imported spreadsheet. Text extraction is limited on this file."
    }

    private func extractTextFromPresentationViaOCR(url: URL) -> (text: String, pages: [OCRPage]?) {
        if let img = generateThumbnail(url: url) {
            let result = ocrService.performOCR(on: img, pageIndex: 0)
            if !result.text.isEmpty && !result.text.contains("OCR failed") {
                return (formatExtractedText(result.text), [result.page])
            }
        }
        return ("", nil)
    }

    private func generateThumbnail(url: URL, size: CGSize = CGSize(width: 2048, height: 2048)) -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url,
                                                   size: size,
                                                   scale: UIScreen.main.scale,
                                                   representationTypes: .thumbnail)
        let generator = QLThumbnailGenerator.shared
        let semaphore = DispatchSemaphore(value: 0)
        var image: UIImage?
        generator.generateBestRepresentation(for: request) { rep, error in
            if let rep = rep {
                image = rep.uiImage
            } else if let error = error {
                print("⚠️ FileProcessingService: Thumbnail error: \(error.localizedDescription)")
            }
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return image
    }

    // MARK: - Helper Methods

    private func extractTextFromXMLContent(_ xmlContent: String) -> String {
        var extractedText = ""

        let patterns = [
            "<w:t[^>]*>([^<]+)</w:t>",
            "<text[^>]*>([^<]+)</text>",
            ">([A-Za-z][^<]{10,})<",
            "([A-Za-z][A-Za-z0-9\\s.,!?;:()\\[\\]\"'-]{20,})"
        ]

        for pattern in patterns {
            do {
                let regex = try NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
                let matches = regex.matches(in: xmlContent, options: [], range: NSRange(xmlContent.startIndex..., in: xmlContent))

                for match in matches {
                    if match.numberOfRanges > 1 {
                        let range = match.range(at: 1)
                        if let swiftRange = Range(range, in: xmlContent) {
                            let matchedText = String(xmlContent[swiftRange]).trimmingCharacters(in: .whitespacesAndNewlines)

                            if !matchedText.isEmpty &&
                               !matchedText.contains("<?xml") &&
                               !matchedText.contains("PK!") &&
                               !matchedText.contains("<") &&
                               !matchedText.contains("xmlns") &&
                               matchedText.count > 10 {
                                extractedText += matchedText + " "
                            }
                        }
                    }
                }

                if extractedText.count > 100 {
                    break
                }
            } catch {
                continue
            }
        }

        return extractedText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func formatExtractedText(_ text: String) -> String {
        return text
            .replacingOccurrences(of: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func looksLikeXML(_ s: String) -> Bool {
        if s.contains("<?xml") { return true }
        if s.contains("<w:") || s.contains("</w:") || s.contains("<w:t") { return true }
        if s.contains("xmlns") { return true }
        if s.contains("PK!") { return true }
        let ltCount = s.filter { $0 == "<" }.count
        let gtCount = s.filter { $0 == ">" }.count
        return ltCount > 5 && gtCount > 5
    }

    private func shouldAutoOCR(for type: Document.DocumentType) -> Bool {
        switch type {
        case .pdf, .docx, .ppt, .pptx, .xls, .text, .scanned:
            return true
        case .xlsx, .image, .zip:
            return false
        }
    }

    static func truncateText(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars))
    }
}
