import Foundation

enum AppError: LocalizedError {
    case fileProcessing(FileProcessingError)
    case persistence(PersistenceError)
    case ocr(OCRError)
    case ai(AIError)
    case validation(ValidationError)

    var errorDescription: String? {
        switch self {
        case .fileProcessing(let error):
            return error.errorDescription
        case .persistence(let error):
            return error.errorDescription
        case .ocr(let error):
            return error.errorDescription
        case .ai(let error):
            return error.errorDescription
        case .validation(let error):
            return error.errorDescription
        }
    }
}

enum FileProcessingError: LocalizedError {
    case fileNotFound(URL)
    case unsupportedFormat(String)
    case corruptedFile(URL)
    case readPermissionDenied(URL)
    case extractionFailed(String)
    case archiveExtractionFailed(URL)

    var errorDescription: String? {
        switch self {
        case .fileNotFound(let url):
            return "File not found: \(url.lastPathComponent)"
        case .unsupportedFormat(let format):
            return "Unsupported file format: .\(format)"
        case .corruptedFile(let url):
            return "File appears to be corrupted: \(url.lastPathComponent)"
        case .readPermissionDenied(let url):
            return "Permission denied reading file: \(url.lastPathComponent)"
        case .extractionFailed(let reason):
            return "Text extraction failed: \(reason)"
        case .archiveExtractionFailed(let url):
            return "Failed to extract archive: \(url.lastPathComponent)"
        }
    }
}

enum PersistenceError: LocalizedError {
    case directoryNotFound
    case saveFailedEncoding(Error)
    case saveFailedIO(Error)
    case loadFailedDecoding(Error)
    case loadFailedIO(Error)
    case migrationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .directoryNotFound:
            return "Could not access application support directory"
        case .saveFailedEncoding(let error):
            return "Failed to encode data: \(error.localizedDescription)"
        case .saveFailedIO(let error):
            return "Failed to save data: \(error.localizedDescription)"
        case .loadFailedDecoding(let error):
            return "Failed to decode saved data: \(error.localizedDescription)"
        case .loadFailedIO(let error):
            return "Failed to load data: \(error.localizedDescription)"
        case .migrationFailed(let error):
            return "Data migration failed: \(error.localizedDescription)"
        }
    }
}

enum OCRError: LocalizedError {
    case imageProcessingFailed
    case visionRequestFailed(Error)
    case noTextRecognized
    case invalidImage

    var errorDescription: String? {
        switch self {
        case .imageProcessingFailed:
            return "Failed to process image for OCR"
        case .visionRequestFailed(let error):
            return "Vision OCR failed: \(error.localizedDescription)"
        case .noTextRecognized:
            return "No text recognized in image"
        case .invalidImage:
            return "Invalid or corrupted image"
        }
    }
}

enum AIError: LocalizedError {
    case modelNotReady
    case noJSListener
    case emptyPrompt
    case generationFailed(String?, String?)
    case invalidResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .modelNotReady:
            return "AI model is not ready"
        case .noJSListener:
            return "No AI listener available"
        case .emptyPrompt:
            return "Prompt cannot be empty"
        case .generationFailed(let code, let message):
            return "AI generation failed: \(code ?? "unknown") - \(message ?? "no message")"
        case .invalidResponse:
            return "Invalid AI response format"
        case .timeout:
            return "AI generation timed out"
        }
    }
}
