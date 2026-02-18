import Foundation
import OSLog

struct PersistedState: Codable {
    var documents: [Document]
    var folders: [DocumentFolder]
    var prefersGridLayout: Bool
}

class PersistenceService {
    static let shared = PersistenceService()

    private let fileManager = FileManager.default
    private let documentsFileName = AppConstants.FileNames.savedDocumentsJSON
    private let lastAccessedKey = AppConstants.UserDefaultsKeys.lastAccessedMap
    private let legacyUserDefaultsKey = "SavedDocuments_v2" // For migration

    private init() {}

    // MARK: - Document Persistence

    /// Saves documents and folders to disk
    func saveDocuments(_ documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool) throws {
        do {
            let state = PersistedState(
                documents: documents,
                folders: folders,
                prefersGridLayout: prefersGridLayout
            )
            let encoded = try JSONEncoder().encode(state)
            let url = try getDocumentsFileURL()
            try encoded.write(to: url, options: [.atomic])
            AppLogger.persistence.info("Saved \(documents.count) documents + \(folders.count) folders")
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    /// Loads documents and folders from disk, with migration support
    func loadDocuments() throws -> (documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool) {
        let url = try getDocumentsFileURL()

        // Try loading from file (current format)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                // File doesn't exist yet — fall through to migration/empty state
                data = Data()
            } else {
                AppLogger.persistence.error("Failed to read documents file: \(error.localizedDescription)")
                throw PersistenceError.loadFailedIO(error)
            }
        }

        if !data.isEmpty {
            // Try new PersistedState format
            do {
                let state = try JSONDecoder().decode(PersistedState.self, from: data)
                AppLogger.persistence.info("Loaded \(state.documents.count) documents + \(state.folders.count) folders")
                return (state.documents, state.folders, state.prefersGridLayout)
            } catch {
                AppLogger.persistence.debug("Not PersistedState format, trying legacy: \(error.localizedDescription)")
            }

            // Try legacy documents-only format
            do {
                let documents = try JSONDecoder().decode([Document].self, from: data)
                AppLogger.persistence.info("Migrated legacy documents-only file (\(documents.count) docs)")
                return (documents, [], false)
            } catch {
                AppLogger.persistence.error("Failed to decode documents file in any format: \(error.localizedDescription)")
                throw PersistenceError.loadFailedDecoding(error)
            }
        }

        // Migration: Check UserDefaults (very old format)
        if let data = UserDefaults.standard.data(forKey: legacyUserDefaultsKey) {
            do {
                let documents = try JSONDecoder().decode([Document].self, from: data)
                AppLogger.persistence.info("Migrated \(documents.count) documents from UserDefaults")
                // Clean up old storage after successful migration
                UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
                return (documents, [], false)
            } catch {
                throw PersistenceError.migrationFailed(error)
            }
        }

        // No saved data found - return empty state
        AppLogger.persistence.info("No saved documents found, starting fresh")
        return ([], [], false)
    }

    // MARK: - Last Accessed Map

    /// Saves the last accessed map to UserDefaults
    func saveLastAccessedMap(_ map: [UUID: Date]) throws {
        let raw = Dictionary(uniqueKeysWithValues: map.map { ($0.key.uuidString, $0.value) })
        do {
            let data = try JSONEncoder().encode(raw)
            UserDefaults.standard.set(data, forKey: lastAccessedKey)
        } catch {
            throw PersistenceError.saveFailedEncoding(error)
        }
    }

    /// Loads the last accessed map from UserDefaults
    func loadLastAccessedMap() throws -> [UUID: Date] {
        guard let data = UserDefaults.standard.data(forKey: lastAccessedKey) else {
            return [:]
        }

        do {
            let raw = try JSONDecoder().decode([String: Date].self, from: data)
            var map: [UUID: Date] = [:]
            for (key, value) in raw {
                if let id = UUID(uuidString: key) {
                    map[id] = value
                }
            }
            return map
        } catch {
            throw PersistenceError.loadFailedDecoding(error)
        }
    }

    // MARK: - Directory Management

    /// Returns the URL for the documents JSON file
    func getDocumentsFileURL() throws -> URL {
        let appSupport = try getApplicationSupportDirectory()
        return appSupport.appendingPathComponent(documentsFileName)
    }

    /// Returns the application support directory, creating it if needed
    func getApplicationSupportDirectory() throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PersistenceError.directoryNotFound
        }

        let identityDir = appSupport.appendingPathComponent("Identity", isDirectory: true)

        if !fileManager.fileExists(atPath: identityDir.path) {
            do {
                try fileManager.createDirectory(at: identityDir, withIntermediateDirectories: true)
            } catch {
                throw PersistenceError.saveFailedIO(error)
            }
        }

        return identityDir
    }

    /// Returns the shared inbox URL (app group container)
    func getSharedInboxURL(createIfMissing: Bool = false) -> URL? {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.AppGroup.identifier
        ) else {
            return nil
        }

        let inbox = container.appendingPathComponent(AppConstants.AppGroup.sharedInboxFolder, isDirectory: true)

        if createIfMissing && !fileManager.fileExists(atPath: inbox.path) {
            do {
                try fileManager.createDirectory(at: inbox, withIntermediateDirectories: true)
            } catch {
                AppLogger.persistence.error("Failed to create shared inbox directory: \(error.localizedDescription)")
            }
        }

        return inbox
    }

    /// Checks if a file exists at the given URL
    func fileExists(at url: URL) -> Bool {
        return fileManager.fileExists(atPath: url.path)
    }

    /// Deletes a file at the given URL
    func deleteFile(at url: URL) throws {
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }
}
