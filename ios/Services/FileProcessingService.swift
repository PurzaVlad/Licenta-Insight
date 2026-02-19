import Foundation
import UIKit
import PDFKit
import QuickLookThumbnailing
import SSZipArchive
import OSLog

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
        AppLogger.fileProcessing.info("Processing \(url.lastPathComponent)")

        // Try to start accessing security scoped resource
        let didStartAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didStartAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }

        let fileExtension = url.pathExtension.lowercased()
        AppLogger.fileProcessing.info("File type: \(fileExtension)")

        var content = ""
        var ocrPages: [OCRPage]? = nil
        var documentType: Document.DocumentType = .text

        // Extract content based on file type
        switch fileExtension {
        case "pdf":
            content = extractTextFromPDF(url: url)
            // Detect scanned PDF: PDFKit returned almost no text → fall back to Vision OCR
            if content.trimmingCharacters(in: .whitespacesAndNewlines).count < 200 {
                let result = extractTextFromPresentationViaOCR(url: url)
                if !result.text.isEmpty {
                    content = result.text
                    ocrPages = result.pages
                }
            }
            documentType = .pdf
        case "txt", "rtf":
            content = extractTextFromTXT(url: url)
            documentType = .text
        case "jpg", "jpeg", "png", "heic":
            let result = extractTextFromPresentationViaOCR(url: url)
            content = result.text.isEmpty ? "No text found in image." : result.text
            ocrPages = result.pages
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
            content = extractTextFromSpreadsheetViaOCR(url: url)
            documentType = .xlsx
        default:
            throw FileProcessingError.unsupportedFormat(fileExtension)
        }

        AppLogger.fileProcessing.info("Content extracted (\(content.count) chars)")

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
            AppLogger.fileProcessing.info("Read \(fileData.count) bytes")

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
            AppLogger.fileProcessing.error("Could not read file data: \(error.localizedDescription)")
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
        AppLogger.fileProcessing.info("Extracting Word document")
        let ext = url.pathExtension.lowercased()

        // Preferred: Parse DOCX XML and extract <w:t> text nodes
        if ext == "docx" {
            let parsed = extractTextFromDOCXArchive(url: url)
            let cleaned = formatExtractedText(parsed)
            if !cleaned.isEmpty && !looksLikeXML(cleaned) {
                AppLogger.fileProcessing.info("Using DOCX parsed text (\(cleaned.count) chars)")
                return cleaned
            }
        }

        // Fallback: OCR a rendered thumbnail
        if let ocrText = extractTextFromDOCXViaOCR(url: url), !ocrText.isEmpty, !ocrText.contains("OCR failed") {
            AppLogger.fileProcessing.info("Using OCR text (\(ocrText.count) chars)")
            return formatExtractedText(ocrText)
        }

        // Last resort placeholder
        AppLogger.fileProcessing.info("No readable text extracted")
        return "Imported Word document. Text extraction is limited on this file."
    }

    private func extractTextFromDOCXArchive(url: URL) -> String {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("docx_extract_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true) } catch {
            AppLogger.fileProcessing.error("Failed to create temp directory for DOCX extraction")
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
                AppLogger.fileProcessing.error("DOCX unzip failed: \(unzipError.localizedDescription)")
            }
            cleanupTempDir(tempDir)
            return ""
        }

        let docXML = tempDir.appendingPathComponent("word/document.xml")
        let xmlData: Data
        do {
            xmlData = try Data(contentsOf: docXML)
        } catch {
            AppLogger.fileProcessing.error("DOCX document.xml missing or unreadable: \(error.localizedDescription)")
            cleanupTempDir(tempDir)
            return ""
        }
        guard let xml = String(data: xmlData, encoding: .utf8) else {
            AppLogger.fileProcessing.error("DOCX document.xml not valid UTF-8")
            cleanupTempDir(tempDir)
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
            AppLogger.fileProcessing.error("DOCX regex extraction failed: \(error.localizedDescription)")
        }

        if body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let cleaned = extractTextFromXMLContent(xml)
            if !cleaned.isEmpty { body = cleaned }
        }

        cleanupTempDir(tempDir)
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
            cleanupTempDir(tempDir)
            return ""
        }

        let slidesDir = tempDir.appendingPathComponent("ppt/slides", isDirectory: true)
        let fm = FileManager.default
        let files: [URL]
        do {
            files = try fm.contentsOfDirectory(at: slidesDir, includingPropertiesForKeys: nil)
        } catch {
            AppLogger.fileProcessing.error("PPTX slides directory listing failed: \(error.localizedDescription)")
            cleanupTempDir(tempDir)
            return ""
        }

        let slideFiles = files
            .filter { $0.lastPathComponent.lowercased().hasPrefix("slide") && $0.pathExtension.lowercased() == "xml" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        if slideFiles.isEmpty {
            cleanupTempDir(tempDir)
            return ""
        }

        var collected: [String] = []
        for slideURL in slideFiles {
            let xmlData: Data
            do {
                xmlData = try Data(contentsOf: slideURL)
            } catch {
                AppLogger.fileProcessing.warning("Failed to read PPTX slide \(slideURL.lastPathComponent): \(error.localizedDescription)")
                continue
            }
            guard let xml = String(data: xmlData, encoding: .utf8) else { continue }

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
                AppLogger.fileProcessing.error("PPTX slide regex failed: \(error.localizedDescription)")
            }

            let cleaned = formatExtractedText(body)
            if !cleaned.isEmpty {
                collected.append(cleaned)
            }
        }

        cleanupTempDir(tempDir)
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
                AppLogger.fileProcessing.error("Thumbnail generation error: \(error.localizedDescription)")
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
        var result = text
        result = result.replacingOccurrences(of: "[\\x00-\\x08\\x0B\\x0C\\x0E-\\x1F\\x7F]", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&apos;", with: "'")
        result = result.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
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
        case .pdf, .docx, .ppt, .pptx, .xls, .xlsx, .image, .text, .scanned:
            return true
        case .zip:
            return false
        }
    }

    static func truncateText(_ text: String, maxChars: Int) -> String {
        if text.count <= maxChars { return text }
        return String(text.prefix(maxChars))
    }

    private func cleanupTempDir(_ dir: URL) {
        do {
            try FileManager.default.removeItem(at: dir)
        } catch {
            AppLogger.fileProcessing.warning("Failed to clean up temp directory: \(error.localizedDescription)")
        }
    }
}
