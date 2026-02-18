import Foundation
import OSLog

class FileStorageService {
    static let shared = FileStorageService()

    private let fileManager = FileManager.default
    private let baseDirectoryName = "DocumentFiles"

    // NSCache auto-evicts under memory pressure
    private let imageCache = NSCache<NSString, NSArray>()
    private let pdfCache = NSCache<NSString, NSData>()
    private let originalCache = NSCache<NSString, NSData>()

    private init() {
        // Limit cache to ~100MB total
        imageCache.totalCostLimit = 50_000_000
        pdfCache.totalCostLimit = 30_000_000
        originalCache.totalCostLimit = 30_000_000
    }

    // MARK: - Save

    func saveImageData(_ imageData: [Data], for documentId: UUID) throws {
        let dir = try documentDirectory(for: documentId)
        for (index, data) in imageData.enumerated() {
            let fileURL = dir.appendingPathComponent("image_\(index).dat")
            try data.write(to: fileURL, options: [.atomic])
        }
        // Remove stale image files beyond new count
        do {
            let existingFiles = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            for file in existingFiles where file.lastPathComponent.hasPrefix("image_") {
                let name = file.deletingPathExtension().lastPathComponent
                if let indexStr = name.split(separator: "_").last, let idx = Int(indexStr), idx >= imageData.count {
                    do {
                        try fileManager.removeItem(at: file)
                    } catch {
                        AppLogger.fileStorage.warning("Failed to remove stale image file \(file.lastPathComponent): \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            AppLogger.fileStorage.warning("Failed to list directory for stale image cleanup: \(error.localizedDescription)")
        }
        imageCache.setObject(imageData as NSArray, forKey: documentId.uuidString as NSString, cost: imageData.reduce(0) { $0 + $1.count })
    }

    func savePdfData(_ data: Data, for documentId: UUID) throws {
        let dir = try documentDirectory(for: documentId)
        let fileURL = dir.appendingPathComponent("pdf.dat")
        try data.write(to: fileURL, options: [.atomic])
        pdfCache.setObject(data as NSData, forKey: documentId.uuidString as NSString, cost: data.count)
    }

    func saveOriginalFileData(_ data: Data, for documentId: UUID) throws {
        let dir = try documentDirectory(for: documentId)
        let fileURL = dir.appendingPathComponent("original.dat")
        try data.write(to: fileURL, options: [.atomic])
        originalCache.setObject(data as NSData, forKey: documentId.uuidString as NSString, cost: data.count)
    }

    /// Saves all non-nil binary data for a document in one call
    func saveFileData(imageData: [Data]?, pdfData: Data?, originalFileData: Data?, for documentId: UUID) throws {
        if let imageData, !imageData.isEmpty {
            try saveImageData(imageData, for: documentId)
        }
        if let pdfData {
            try savePdfData(pdfData, for: documentId)
        }
        if let originalFileData {
            try saveOriginalFileData(originalFileData, for: documentId)
        }
    }

    // MARK: - Load

    func loadImageData(for documentId: UUID) -> [Data]? {
        let key = documentId.uuidString as NSString
        if let cached = imageCache.object(forKey: key) as? [Data] {
            return cached
        }

        let dir = documentDirectoryURL(for: documentId)
        guard fileManager.fileExists(atPath: dir.path) else { return nil }

        let files: [URL]
        do {
            files = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        } catch {
            AppLogger.fileStorage.error("Failed to list image directory for \(documentId.uuidString): \(error.localizedDescription)")
            return nil
        }

        let imageFiles = files
            .filter { $0.lastPathComponent.hasPrefix("image_") && $0.pathExtension == "dat" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        guard !imageFiles.isEmpty else { return nil }

        var result: [Data] = []
        for file in imageFiles {
            do {
                let data = try Data(contentsOf: file)
                result.append(data)
            } catch {
                AppLogger.fileStorage.error("Failed to read image file \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        guard !result.isEmpty else { return nil }
        imageCache.setObject(result as NSArray, forKey: key, cost: result.reduce(0) { $0 + $1.count })
        return result
    }

    func loadPdfData(for documentId: UUID) -> Data? {
        let key = documentId.uuidString as NSString
        if let cached = pdfCache.object(forKey: key) {
            return cached as Data
        }

        let fileURL = documentDirectoryURL(for: documentId).appendingPathComponent("pdf.dat")
        do {
            let data = try Data(contentsOf: fileURL)
            pdfCache.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        } catch {
            AppLogger.fileStorage.debug("No PDF data for \(documentId.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    func loadOriginalFileData(for documentId: UUID) -> Data? {
        let key = documentId.uuidString as NSString
        if let cached = originalCache.object(forKey: key) {
            return cached as Data
        }

        let fileURL = documentDirectoryURL(for: documentId).appendingPathComponent("original.dat")
        do {
            let data = try Data(contentsOf: fileURL)
            originalCache.setObject(data as NSData, forKey: key, cost: data.count)
            return data
        } catch {
            AppLogger.fileStorage.debug("No original data for \(documentId.uuidString): \(error.localizedDescription)")
            return nil
        }
    }

    /// Common fallback chain: original → pdf → first image
    func loadAnyFileData(for documentId: UUID) -> Data? {
        if let data = loadOriginalFileData(for: documentId) { return data }
        if let data = loadPdfData(for: documentId) { return data }
        if let images = loadImageData(for: documentId), let first = images.first { return first }
        return nil
    }

    // MARK: - Delete

    func deleteAllData(for documentId: UUID) {
        let dir = documentDirectoryURL(for: documentId)
        do {
            try fileManager.removeItem(at: dir)
        } catch {
            AppLogger.fileStorage.warning("Failed to delete data for \(documentId.uuidString): \(error.localizedDescription)")
        }
        evictCache(for: documentId)
    }

    // MARK: - Query

    func hasData(for documentId: UUID) -> Bool {
        let dir = documentDirectoryURL(for: documentId)
        return fileManager.fileExists(atPath: dir.path)
    }

    // MARK: - Cache Management

    func evictCache(for documentId: UUID) {
        let key = documentId.uuidString as NSString
        imageCache.removeObject(forKey: key)
        pdfCache.removeObject(forKey: key)
        originalCache.removeObject(forKey: key)
    }

    func clearAllCaches() {
        imageCache.removeAllObjects()
        pdfCache.removeAllObjects()
        originalCache.removeAllObjects()
    }

    // MARK: - Directory Helpers

    private func baseDirectoryURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Identity", isDirectory: true)
            .appendingPathComponent(baseDirectoryName, isDirectory: true)
    }

    private func documentDirectoryURL(for documentId: UUID) -> URL {
        baseDirectoryURL().appendingPathComponent(documentId.uuidString, isDirectory: true)
    }

    private func documentDirectory(for documentId: UUID) throws -> URL {
        let dir = documentDirectoryURL(for: documentId)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
