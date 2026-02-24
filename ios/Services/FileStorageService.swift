import Foundation
import OSLog

class FileStorageService {
    static let shared = FileStorageService()

    private let fileManager = FileManager.default
    private let baseDirectoryName = "DocumentFiles"
    private let ioQueue = DispatchQueue(label: "com.purzavlad.insight.fileStorage.io", qos: .utility)

    // NSCache auto-evicts under memory pressure
    private let imageCache = NSCache<NSString, NSArray>()
    private let pdfCache = NSCache<NSString, NSData>()
    private let originalCache = NSCache<NSString, NSData>()

    private init() {
        // Limit cache to ~100MB total
        imageCache.totalCostLimit = 50_000_000
        pdfCache.totalCostLimit = 30_000_000
        originalCache.totalCostLimit = 30_000_000
        setupBaseDirectory()
        ensureConvertedCacheDirectory()
        purgeConvertedCache()
    }

    /// Creates the base DocumentFiles directory on first launch and marks it
    /// as excluded from iCloud backup — these binaries can be re-imported.
    private func setupBaseDirectory() {
        let base = baseDirectoryURL()
        if !fileManager.fileExists(atPath: base.path) {
            try? fileManager.createDirectory(
                at: base,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
        }
        try? (base as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    // MARK: - Save

    func saveImageData(_ imageData: [Data], for documentId: UUID) throws {
        let dir = try documentDirectory(for: documentId)
        for (index, data) in imageData.enumerated() {
            let fileURL = dir.appendingPathComponent("image_\(index).dat")
            try writeProtectedFile(data, to: fileURL, protection: .completeUnlessOpen)
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
        try writeProtectedFile(data, to: fileURL, protection: .completeUnlessOpen)
        pdfCache.setObject(data as NSData, forKey: documentId.uuidString as NSString, cost: data.count)
    }

    func saveOriginalFileData(_ data: Data, for documentId: UUID) throws {
        let dir = try documentDirectory(for: documentId)
        let fileURL = dir.appendingPathComponent("original.dat")
        try writeProtectedFile(data, to: fileURL, protection: .completeUnlessOpen)
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
        ioQueue.sync {
            let dir = documentDirectoryURL(for: documentId)
            do {
                try fileManager.removeItem(at: dir)
            } catch {
                AppLogger.fileStorage.warning("Failed to delete data for \(documentId.uuidString): \(error.localizedDescription)")
            }
            evictCache(for: documentId)
        }
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

    // MARK: - Temp File Cleanup

    /// Removes share-temp files older than 24 hours from the system tmp directory.
    /// Call once on app startup to prevent accumulation from interrupted share operations.
    func cleanupShareTempFiles() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let contents = try? fileManager.contentsOfDirectory(
            at: tmpDir,
            includingPropertiesForKeys: [.contentModificationDateKey]
        ) else { return }
        let cutoff = Date().addingTimeInterval(-Double(AppConstants.Security.tempPreviewRetentionHours) * 3600)
        for url in contents {
            let name = url.lastPathComponent.lowercased()
            if !name.hasPrefix("preview_") { continue }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    /// Removes temp preview artifacts tied to a specific document.
    func cleanupTemporaryPreviewFiles(for documentId: UUID) {
        ioQueue.sync {
            let tmpDir = FileManager.default.temporaryDirectory
            guard let contents = try? fileManager.contentsOfDirectory(at: tmpDir, includingPropertiesForKeys: nil) else {
                return
            }
            let idString = documentId.uuidString.lowercased()
            for url in contents {
                let name = url.lastPathComponent.lowercased()
                if name.contains(idString) || name.hasPrefix("preview_\(idString)") {
                    try? fileManager.removeItem(at: url)
                }
            }
        }
    }

    /// Removes converted server cache files to avoid orphaned sensitive artifacts.
    func cleanupConvertedCache(documentId: UUID? = nil) {
        ioQueue.sync {
            let convertedDir = convertedDirectoryURL()
            guard fileManager.fileExists(atPath: convertedDir.path) else { return }
            guard let files = try? fileManager.contentsOfDirectory(at: convertedDir, includingPropertiesForKeys: nil) else { return }
            let idString = documentId?.uuidString.lowercased()
            for file in files {
                if let idString {
                    let lower = file.lastPathComponent.lowercased()
                    if lower.hasPrefix("converted_\(idString)_") {
                        try? fileManager.removeItem(at: file)
                    }
                } else {
                    try? fileManager.removeItem(at: file)
                }
            }
            purgeConvertedCache()
        }
    }

    func convertedOutputURL(for documentId: UUID, targetExtension: String) -> URL {
        let safeExt = targetExtension.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ext = safeExt.isEmpty ? "bin" : safeExt
        return convertedDirectoryURL().appendingPathComponent("converted_\(documentId.uuidString.lowercased())_\(ext).\(ext)")
    }

    func writeConvertedOutput(_ data: Data, documentId: UUID, targetExtension: String) throws -> URL {
        try ioQueue.sync {
            ensureConvertedCacheDirectory()
            let outputURL = convertedOutputURL(for: documentId, targetExtension: targetExtension)
            try writeProtectedFile(data, to: outputURL, protection: .completeUnlessOpen)
            try? (outputURL as NSURL).setResourceValue(Date(), forKey: .contentModificationDateKey)
            purgeConvertedCache()
            return outputURL
        }
    }

    func deleteAllArtifacts(for documentId: UUID) {
        deleteAllData(for: documentId)
        cleanupTemporaryPreviewFiles(for: documentId)
        cleanupConvertedCache(documentId: documentId)
    }

    func clearSensitiveStorage() {
        ioQueue.sync {
            if fileManager.fileExists(atPath: baseDirectoryURL().path) {
                try? fileManager.removeItem(at: baseDirectoryURL())
            }
            if fileManager.fileExists(atPath: convertedDirectoryURL().path) {
                try? fileManager.removeItem(at: convertedDirectoryURL())
            }
            clearAllCaches()
            setupBaseDirectory()
            ensureConvertedCacheDirectory()
        }
    }

    func applyCurrentSecurityProfile() {
        ioQueue.sync {
            let protection = SecurityProfile.current == .strict ? FileProtectionType.complete : FileProtectionType.completeUnlessOpen
            let base = baseDirectoryURL()
            if fileManager.fileExists(atPath: base.path),
               let items = try? fileManager.subpathsOfDirectory(atPath: base.path) {
                for rel in items {
                    let url = base.appendingPathComponent(rel)
                    try? (url as NSURL).setResourceValue(protection, forKey: .fileProtectionKey)
                }
            }
            let converted = convertedDirectoryURL()
            if fileManager.fileExists(atPath: converted.path),
               let files = try? fileManager.contentsOfDirectory(at: converted, includingPropertiesForKeys: nil) {
                for url in files {
                    try? (url as NSURL).setResourceValue(protection, forKey: .fileProtectionKey)
                }
            }
        }
    }

    // MARK: - Directory Helpers

    private func baseDirectoryURL() -> URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport
            .appendingPathComponent("Insight", isDirectory: true)
            .appendingPathComponent(baseDirectoryName, isDirectory: true)
    }

    private func convertedDirectoryURL() -> URL {
        let cachesDir = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return cachesDir.appendingPathComponent("Converted", isDirectory: true)
    }

    private func ensureConvertedCacheDirectory() {
        let convertedDir = convertedDirectoryURL()
        if !fileManager.fileExists(atPath: convertedDir.path) {
            try? fileManager.createDirectory(
                at: convertedDir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
        }
        try? (convertedDir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    private func documentDirectoryURL(for documentId: UUID) -> URL {
        baseDirectoryURL().appendingPathComponent(documentId.uuidString, isDirectory: true)
    }

    private func documentDirectory(for documentId: UUID) throws -> URL {
        let dir = documentDirectoryURL(for: documentId)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
            )
        }
        return dir
    }

    private func writeProtectedFile(_ data: Data, to url: URL, protection: FileProtectionType) throws {
        try data.write(to: url, options: [.atomic])
        try? (url as NSURL).setResourceValue(protection, forKey: .fileProtectionKey)
        try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
    }

    private func purgeConvertedCache() {
        let convertedDir = convertedDirectoryURL()
        guard let files = try? fileManager.contentsOfDirectory(
            at: convertedDir,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let cutoff = Date().addingTimeInterval(-Double(AppConstants.Security.convertedCacheRetentionDays) * 86400)
        var kept: [(url: URL, modified: Date, size: Int)] = []

        for url in files {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let modified = values?.contentModificationDate ?? .distantPast
            let size = values?.fileSize ?? 0
            if modified < cutoff {
                try? fileManager.removeItem(at: url)
                continue
            }
            kept.append((url, modified, size))
        }

        var total = kept.reduce(0) { $0 + $1.size }
        if total <= AppConstants.Security.convertedCacheMaxBytes { return }

        for item in kept.sorted(by: { $0.modified < $1.modified }) {
            try? fileManager.removeItem(at: item.url)
            total -= item.size
            if total <= AppConstants.Security.convertedCacheMaxBytes {
                break
            }
        }
    }
}
