import Foundation

enum ValidationError: LocalizedError {
    case fileTooLarge(size: Int, max: Int)
    case unsupportedFormat(String)
    case invalidPath(String)
    case fileAttributeError(Error)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size, let max):
            let sizeMB = Double(size) / 1_000_000.0
            let maxMB = Double(max) / 1_000_000.0
            return "File too large (\(String(format: "%.1f", sizeMB))MB, max \(String(format: "%.1f", maxMB))MB)"
        case .unsupportedFormat(let ext):
            return "Unsupported file type: .\(ext)"
        case .invalidPath(let reason):
            return "Invalid path: \(reason)"
        case .fileAttributeError(let error):
            return "Could not check file attributes: \(error.localizedDescription)"
        }
    }
}

class ValidationService {
    static let shared = ValidationService()

    // Configuration
    private let maxFileSizeBytes = 50_000_000 // 50MB

    private let supportedExtensions: Set<String> = [
        "pdf", "docx", "doc", "txt", "rtf",
        "jpg", "jpeg", "png", "heic", "gif",
        "pptx", "ppt", "xls", "xlsx",
        "json", "xml", "zip"
    ]

    private init() {}

    /// Validates a file from the shared inbox
    func validateFile(_ url: URL) throws {
        // Check for path traversal attempts
        if url.path.contains("..") {
            throw ValidationError.invalidPath("path traversal detected")
        }

        // Check file size
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            if let size = attrs[.size] as? Int {
                if size > maxFileSizeBytes {
                    throw ValidationError.fileTooLarge(size: size, max: maxFileSizeBytes)
                }
            }
        } catch let error as ValidationError {
            throw error
        } catch {
            throw ValidationError.fileAttributeError(error)
        }

        // Whitelist allowed extensions
        let ext = url.pathExtension.lowercased()
        if !supportedExtensions.contains(ext) {
            throw ValidationError.unsupportedFormat(ext)
        }
    }

    /// Validates file size
    func validateFileSize(_ data: Data, maxSize: Int) throws {
        if data.count > maxSize {
            throw ValidationError.fileTooLarge(size: data.count, max: maxSize)
        }
    }

    /// Checks if a file extension is supported
    func isSupported(extension ext: String) -> Bool {
        return supportedExtensions.contains(ext.lowercased())
    }

    /// Sanitizes a filename by removing dangerous characters
    func sanitizeFilename(_ name: String) -> String {
        var sanitized = name
        // Remove path separators
        sanitized = sanitized.replacingOccurrences(of: "/", with: "_")
        sanitized = sanitized.replacingOccurrences(of: "\\", with: "_")
        // Remove parent directory references
        sanitized = sanitized.replacingOccurrences(of: "..", with: "_")
        // Remove null bytes
        sanitized = sanitized.replacingOccurrences(of: "\0", with: "")
        return sanitized
    }
}
