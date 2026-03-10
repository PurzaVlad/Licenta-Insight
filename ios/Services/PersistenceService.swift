import Foundation
import OSLog
import CryptoKit
import Security

/// Legacy monolith — kept for migration decoding only. New code uses PersistedIndex + per-doc files.
struct PersistedState: Codable {
    var documents: [Document]
    var folders: [DocumentFolder]
    var prefersGridLayout: Bool
    var conversations: [PersistedConversation]

    // Custom decoder for backward compatibility with files that lack conversations
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        documents = try container.decode([Document].self, forKey: .documents)
        folders = try container.decodeIfPresent([DocumentFolder].self, forKey: .folders) ?? []
        prefersGridLayout = try container.decodeIfPresent(Bool.self, forKey: .prefersGridLayout) ?? false
        conversations = try container.decodeIfPresent([PersistedConversation].self, forKey: .conversations) ?? []
    }

    init(documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool, conversations: [PersistedConversation] = []) {
        self.documents = documents
        self.folders = folders
        self.prefersGridLayout = prefersGridLayout
        self.conversations = conversations
    }
}

/// New fragmented index — stores document ID ordering + folders + layout preference.
/// Each document's content lives in a separate encrypted `documents/<uuid>.json` file.
struct PersistedIndex: Codable {
    var documentIds: [String]   // UUID strings; preserves display order
    var folders: [DocumentFolder]
    var prefersGridLayout: Bool
}

class PersistenceService {
    static let shared = PersistenceService()

    private let fileManager = FileManager.default
    private let documentsFileName = AppConstants.FileNames.savedDocumentsJSON
    private let legacyUserDefaultsKey = "SavedDocuments_v2" // For migration
    private let legacyEncryptedMagic = Data("ENC1".utf8)
    private let envelopeMagic = Data("IDEN".utf8)
    private let envelopeVersion: UInt8 = 1
    private let algorithmAESGCM: UInt8 = 1
    private let keychainService = "com.insight.app.persistence"
    private let keychainAccountPrefix = "documents_encryption_key_"
    private let aadBaseContext = "\(AppConstants.FileNames.savedDocumentsJSON)|v1"   // legacy — used for old file migration
    private let aadIndex = "index.json|v1"
    private let aadDocument = "document.json|v1"
    private let aadConversations = "conversations.json|v1"

    // Per-user namespace — set via configure(userID:) on sign-in
    private(set) var userID: String = "anonymous"

    // User-scoped computed keys
    private var lastAccessedKey: String { "\(AppConstants.UserDefaultsKeys.lastAccessedMap)_\(userID)" }
    private var keychainCurrentKeyIdAccount: String { "\(userID)_documents_encryption_current_key_id" }

    private init() {}

    func configure(userID: String) {
        self.userID = userID
    }

    // MARK: - Document Persistence

    /// Full save: writes each document to its own file + updates the index.
    /// Called for bulk operations (migration, vault reset).
    func saveDocuments(_ documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool) throws {
        do {
            for doc in documents {
                try saveDocument(doc)
            }
            try saveIndex(documentIds: documents.map(\.id), folders: folders, prefersGridLayout: prefersGridLayout)
            AppLogger.persistence.info("Saved \(documents.count) documents + \(folders.count) folders")
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    /// Saves a single document to its own encrypted `documents/<uuid>.json` file.
    func saveDocument(_ doc: Document) throws {
        do {
            let encoded = try JSONEncoder().encode(doc)
            let encrypted = try encrypt(encoded, context: aadDocument)
            let url = try documentURL(id: doc.id)
            try writeMetadataFile(encrypted, to: url)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    /// Saves the index file (document ID ordering + folders + layout preference).
    func saveIndex(documentIds: [UUID], folders: [DocumentFolder], prefersGridLayout: Bool) throws {
        do {
            let index = PersistedIndex(
                documentIds: documentIds.map { $0.uuidString },
                folders: folders,
                prefersGridLayout: prefersGridLayout
            )
            let encoded = try JSONEncoder().encode(index)
            let encrypted = try encrypt(encoded, context: aadIndex)
            let url = try indexURL()
            try writeMetadataFile(encrypted, to: url)
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    /// Deletes the per-document JSON file for a given document ID.
    func deleteDocumentFile(id: UUID) {
        if let url = try? documentURL(id: id) {
            try? fileManager.removeItem(at: url)
        }
    }

    // MARK: - Conversation Persistence

    /// Saves conversations directly to `conversations.json`.
    func saveConversations(_ conversations: [PersistedConversation]) throws {
        do {
            let encoded = try JSONEncoder().encode(conversations)
            let encrypted = try encrypt(encoded, context: aadConversations)
            let url = try conversationsURL()
            try writeMetadataFile(encrypted, to: url)
            AppLogger.persistence.debug("Saved \(conversations.count) conversations")
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    /// Loads conversations. Tries `conversations.json` first; falls back to legacy monolithic file.
    func loadConversations() throws -> [PersistedConversation] {
        // New format
        if let url = try? conversationsURL(),
           let data = try? Data(contentsOf: url), !data.isEmpty,
           let decrypted = try? decryptIfNeeded(data, context: aadConversations),
           let conversations = try? JSONDecoder().decode([PersistedConversation].self, from: decrypted) {
            return conversations
        }
        // Legacy fallback — read from old monolith
        let legacyURL = try getDocumentsFileURL()
        guard let data = try? Data(contentsOf: legacyURL), !data.isEmpty else { return [] }
        let decrypted = try decryptIfNeeded(data)
        let state = try JSONDecoder().decode(PersistedState.self, from: decrypted)
        return state.conversations
    }

    /// Loads documents. Tries fragmented format first; falls back to legacy monolithic file (with auto-migration).
    func loadDocuments() throws -> (documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool) {
        // Try new fragmented format
        if let index = try? loadIndex() {
            var documents: [Document] = []
            for uuidStr in index.documentIds {
                guard let id = UUID(uuidString: uuidStr) else { continue }
                if let doc = try? loadDocumentFile(id: id) {
                    documents.append(doc)
                } else {
                    AppLogger.persistence.warning("Missing document file for id \(uuidStr) — skipping")
                }
            }
            AppLogger.persistence.info("Loaded \(documents.count) documents + \(index.folders.count) folders (fragmented)")
            return (documents, index.folders, index.prefersGridLayout)
        }

        // Fall back to legacy single-file format (triggers migration)
        return try loadDocumentsLegacy()
    }

    // MARK: - Fragmented Format Helpers

    private func loadIndex() throws -> PersistedIndex {
        let url = try indexURL()
        let data = try Data(contentsOf: url)
        let decrypted = try decryptIfNeeded(data, context: aadIndex)
        return try JSONDecoder().decode(PersistedIndex.self, from: decrypted)
    }

    private func loadDocumentFile(id: UUID) throws -> Document {
        let url = try documentURL(id: id)
        let data = try Data(contentsOf: url)
        let decrypted = try decryptIfNeeded(data, context: aadDocument)
        return try JSONDecoder().decode(Document.self, from: decrypted)
    }

    /// Reads the old `SavedDocuments_v2.json` monolith and migrates to fragmented format.
    private func loadDocumentsLegacy() throws -> (documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool) {
        let url = try getDocumentsFileURL()

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if (error as NSError).domain == NSCocoaErrorDomain,
               (error as NSError).code == NSFileReadNoSuchFileError {
                data = Data()
            } else {
                AppLogger.persistence.error("Failed to read documents file: \(error.localizedDescription)")
                throw PersistenceError.loadFailedIO(error)
            }
        }

        if !data.isEmpty {
            let decodedData: Data
            do {
                decodedData = try decryptIfNeeded(data)
                maybeRotateKeyForMajorVersionBump(decryptedState: decodedData)
            } catch {
                AppLogger.persistence.error("Failed to decrypt documents file: \(error.localizedDescription)")
                throw PersistenceError.vaultUnavailable(error)
            }

            if let state = try? JSONDecoder().decode(PersistedState.self, from: decodedData) {
                warnIfMetadataFileLarge(currentBytes: data.count)
                AppLogger.persistence.info("Migrating \(state.documents.count) documents from legacy single-file format")
                try? migrateLegacyState(state)
                return (state.documents, state.folders, state.prefersGridLayout)
            }

            if let documents = try? JSONDecoder().decode([Document].self, from: decodedData) {
                AppLogger.persistence.info("Migrating legacy documents-only file (\(documents.count) docs)")
                try? migrateLegacyState(PersistedState(documents: documents, folders: [], prefersGridLayout: false))
                return (documents, [], false)
            }

            AppLogger.persistence.error("Failed to decode documents file in any format")
            throw PersistenceError.loadFailedDecoding(NSError(domain: "PersistenceService", code: -20, userInfo: [NSLocalizedDescriptionKey: "Failed to decode documents file in any known format"]))
        }

        // UserDefaults migration (very old format)
        if let udData = UserDefaults.standard.data(forKey: legacyUserDefaultsKey) {
            do {
                let documents = try JSONDecoder().decode([Document].self, from: udData)
                AppLogger.persistence.info("Migrated \(documents.count) documents from UserDefaults")
                UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
                try? migrateLegacyState(PersistedState(documents: documents, folders: [], prefersGridLayout: false))
                return (documents, [], false)
            } catch {
                throw PersistenceError.migrationFailed(error)
            }
        }

        AppLogger.persistence.info("No saved documents found, starting fresh")
        return ([], [], false)
    }

    /// Writes new-format files from a legacy `PersistedState` and deletes the old monolith.
    private func migrateLegacyState(_ state: PersistedState) throws {
        for doc in state.documents {
            try saveDocument(doc)
        }
        try saveIndex(documentIds: state.documents.map(\.id), folders: state.folders, prefersGridLayout: state.prefersGridLayout)
        if !state.conversations.isEmpty {
            try saveConversations(state.conversations)
        }
        // Remove old monolith
        let legacyURL = try getDocumentsFileURL()
        try? fileManager.removeItem(at: legacyURL)
        AppLogger.persistence.info("Migration to fragmented format complete — legacy file removed")
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

    /// Returns the URL for the legacy monolithic documents JSON file (kept for migration read path).
    func getDocumentsFileURL() throws -> URL {
        let appSupport = try getApplicationSupportDirectory()
        return appSupport.appendingPathComponent(documentsFileName)
    }

    /// Returns the URL for the fragmented index file.
    func indexURL() throws -> URL {
        return try getApplicationSupportDirectory().appendingPathComponent("index.json")
    }

    /// Returns (and creates) the directory that holds per-document JSON files.
    func documentsDirectoryURL() throws -> URL {
        let dir = try getApplicationSupportDirectory().appendingPathComponent("documents", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try fileManager.createDirectory(
                at: dir,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: SecurityProfile.current.metadataFileProtection]
            )
            try? (dir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        }
        return dir
    }

    /// Returns the URL for a single document's JSON file.
    func documentURL(id: UUID) throws -> URL {
        return try documentsDirectoryURL().appendingPathComponent("\(id.uuidString).json")
    }

    /// Returns the URL for the conversations JSON file.
    func conversationsURL() throws -> URL {
        return try getApplicationSupportDirectory().appendingPathComponent("conversations.json")
    }

    /// Returns the application support directory, creating it if needed
    func getApplicationSupportDirectory() throws -> URL {
        guard let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw PersistenceError.directoryNotFound
        }

        let insightDir = appSupport
            .appendingPathComponent("Insight", isDirectory: true)
            .appendingPathComponent(userID, isDirectory: true)

        if !fileManager.fileExists(atPath: insightDir.path) {
            do {
                try fileManager.createDirectory(
                    at: insightDir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: SecurityProfile.current.metadataFileProtection]
                )
            } catch {
                throw PersistenceError.saveFailedIO(error)
            }
        }
        try? (insightDir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

        return insightDir
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
                try fileManager.createDirectory(
                    at: inbox,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUnlessOpen]
                )
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

    // MARK: - Encryption

    private func encrypt(_ plaintext: Data) throws -> Data {
        let profile = SecurityProfile.current
        let currentKeyId = try loadOrCreateCurrentKeyId(accessibility: profile.keychainAccessibility)
        let key = try loadOrCreateEncryptionKey(keyId: currentKeyId, accessibility: profile.keychainAccessibility)
        let aad = makeAAD()
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw PersistenceError.saveFailedEncoding(NSError(domain: "PersistenceService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to build encrypted payload"]))
        }
        var out = Data()
        out.append(envelopeMagic)
        out.append(envelopeVersion)
        out.append(currentKeyId.uuidData)
        out.append(algorithmAESGCM)
        out.append(combined)
        return out
    }

    private func decryptIfNeeded(_ data: Data) throws -> Data {
        if data.starts(with: envelopeMagic) {
            guard data.count > envelopeMagic.count + 1 + 16 + 1 else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -10, userInfo: [NSLocalizedDescriptionKey: "Encrypted metadata envelope is truncated"]))
            }
            let versionOffset = envelopeMagic.count
            let version = data[versionOffset]
            guard version == envelopeVersion else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -11, userInfo: [NSLocalizedDescriptionKey: "Unsupported encrypted metadata version"]))
            }
            let keyIdStart = versionOffset + 1
            let keyIdData = data.subdata(in: keyIdStart..<(keyIdStart + 16))
            guard let keyId = UUID(data: keyIdData) else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -12, userInfo: [NSLocalizedDescriptionKey: "Invalid key identifier in metadata"]))
            }
            let algorithm = data[keyIdStart + 16]
            guard algorithm == algorithmAESGCM else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -13, userInfo: [NSLocalizedDescriptionKey: "Unsupported encryption algorithm"]))
            }
            let combined = data.dropFirst(keyIdStart + 17)
            let box = try AES.GCM.SealedBox(combined: combined)
            let key = try loadEncryptionKey(keyId: keyId)
            do {
                return try AES.GCM.open(box, using: key, authenticating: makeAAD())
            } catch {
                throw PersistenceError.vaultUnavailable(error)
            }
        }

        if data.starts(with: legacyEncryptedMagic) {
            let combined = data.dropFirst(legacyEncryptedMagic.count)
            let box = try AES.GCM.SealedBox(combined: combined)
            let key = try loadLegacyOrCurrentEncryptionKeyForMigration()
            do {
                return try AES.GCM.open(box, using: key)
            } catch {
                throw PersistenceError.vaultUnavailable(error)
            }
        }

        return data
    }

    private func loadOrCreateCurrentKeyId(accessibility: CFString) throws -> UUID {
        if let currentId = try loadCurrentKeyId() {
            return currentId
        }
        let newId = UUID()
        try storeCurrentKeyId(newId, accessibility: accessibility)
        return newId
    }

    private func loadCurrentKeyId() throws -> UUID? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainCurrentKeyIdAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data, let text = String(data: data, encoding: .utf8), let id = UUID(uuidString: text) {
            return id
        }
        if status != errSecSuccess && status != errSecItemNotFound {
            throw PersistenceError.loadFailedIO(NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        return nil
    }

    private func storeCurrentKeyId(_ keyId: UUID, accessibility: CFString) throws {
        let keyIdData = Data(keyId.uuidString.utf8)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainCurrentKeyIdAccount
        ]
        _ = SecItemDelete(query as CFDictionary)
        query[kSecValueData as String] = keyIdData
        query[kSecAttrAccessible as String] = accessibility
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw PersistenceError.saveFailedIO(NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)))
        }
    }

    private func keyAccountName(for keyId: UUID) -> String {
        "\(userID)_\(keychainAccountPrefix)\(keyId.uuidString.lowercased())"
    }

    private func loadEncryptionKey(keyId: UUID) throws -> SymmetricKey {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyAccountName(for: keyId),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw PersistenceError.vaultUnavailable(NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Encryption key missing for keyId \(keyId.uuidString)"]))
        }
        return SymmetricKey(data: data)
    }

    private func loadOrCreateEncryptionKey(keyId: UUID, accessibility: CFString) throws -> SymmetricKey {
        if let existing = try? loadEncryptionKey(keyId: keyId) {
            return existing
        }
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keyAccountName(for: keyId),
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: accessibility
        ]
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        if addStatus != errSecSuccess {
            throw PersistenceError.saveFailedIO(NSError(domain: NSOSStatusErrorDomain, code: Int(addStatus)))
        }
        return newKey
    }

    private func loadLegacyOrCurrentEncryptionKeyForMigration() throws -> SymmetricKey {
        if let currentId = try loadCurrentKeyId(), let key = try? loadEncryptionKey(keyId: currentId) {
            return key
        }

        // Legacy single-key fallback (read only)
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "documents_encryption_key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data, data.count == 32 else {
            throw PersistenceError.vaultUnavailable(NSError(domain: NSOSStatusErrorDomain, code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Legacy encryption key is unavailable"]))
        }
        return SymmetricKey(data: data)
    }

    private func makeAAD() -> Data {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        return Data("\(aadBaseContext)|\(bundle)".utf8)
    }

    private func makeAAD(context: String) -> Data {
        let bundle = Bundle.main.bundleIdentifier ?? "unknown.bundle"
        return Data("\(context)|\(bundle)".utf8)
    }

    /// Context-aware encrypt used for new fragmented files.
    private func encrypt(_ plaintext: Data, context: String) throws -> Data {
        let profile = SecurityProfile.current
        let currentKeyId = try loadOrCreateCurrentKeyId(accessibility: profile.keychainAccessibility)
        let key = try loadOrCreateEncryptionKey(keyId: currentKeyId, accessibility: profile.keychainAccessibility)
        let aad = makeAAD(context: context)
        let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: aad)
        guard let combined = sealed.combined else {
            throw PersistenceError.saveFailedEncoding(NSError(domain: "PersistenceService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to build encrypted payload"]))
        }
        var out = Data()
        out.append(envelopeMagic)
        out.append(envelopeVersion)
        out.append(currentKeyId.uuidData)
        out.append(algorithmAESGCM)
        out.append(combined)
        return out
    }

    /// Context-aware decrypt used for new fragmented files.
    private func decryptIfNeeded(_ data: Data, context: String) throws -> Data {
        if data.starts(with: envelopeMagic) {
            guard data.count > envelopeMagic.count + 1 + 16 + 1 else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -10, userInfo: [NSLocalizedDescriptionKey: "Encrypted metadata envelope is truncated"]))
            }
            let versionOffset = envelopeMagic.count
            let version = data[versionOffset]
            guard version == envelopeVersion else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -11, userInfo: [NSLocalizedDescriptionKey: "Unsupported encrypted metadata version"]))
            }
            let keyIdStart = versionOffset + 1
            let keyIdData = data.subdata(in: keyIdStart..<(keyIdStart + 16))
            guard let keyId = UUID(data: keyIdData) else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -12, userInfo: [NSLocalizedDescriptionKey: "Invalid key identifier in metadata"]))
            }
            let algorithm = data[keyIdStart + 16]
            guard algorithm == algorithmAESGCM else {
                throw PersistenceError.vaultUnavailable(NSError(domain: "PersistenceService", code: -13, userInfo: [NSLocalizedDescriptionKey: "Unsupported encryption algorithm"]))
            }
            let combined = data.dropFirst(keyIdStart + 17)
            let box = try AES.GCM.SealedBox(combined: combined)
            let key = try loadEncryptionKey(keyId: keyId)
            do {
                return try AES.GCM.open(box, using: key, authenticating: makeAAD(context: context))
            } catch {
                throw PersistenceError.vaultUnavailable(error)
            }
        }
        // Plaintext fallback (shouldn't happen for new files, but safe)
        return data
    }

    private func maybeRotateKeyForMajorVersionBump(decryptedState: Data) {
        let currentMajor = Self.currentMajorVersion()
        let last = UserDefaults.standard.integer(forKey: AppConstants.UserDefaultsKeys.lastKeyRotationMajorVersion)
        if last == 0 {
            UserDefaults.standard.set(currentMajor, forKey: AppConstants.UserDefaultsKeys.lastKeyRotationMajorVersion)
            return
        }
        guard currentMajor > last else { return }
        do {
            try rotateKeyAndReencrypt(decryptedState: decryptedState)
            UserDefaults.standard.set(currentMajor, forKey: AppConstants.UserDefaultsKeys.lastKeyRotationMajorVersion)
        } catch {
            AppLogger.persistence.error("Failed to rotate vault key for major version update: \(error.localizedDescription)")
        }
    }

    private func writeMetadataFile(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: SecurityProfile.current.metadataWriteOptions)
        try? (url as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)
        try? (url as NSURL).setResourceValue(SecurityProfile.current.metadataFileProtection, forKey: .fileProtectionKey)
    }

    private func warnIfMetadataFileLarge(currentBytes: Int) {
        let sizeMB = currentBytes / (1024 * 1024)
        if sizeMB >= AppConstants.Security.metadataSizeWarningMB {
            AppLogger.persistence.warning("Encrypted metadata file is \(sizeMB)MB. Consider migrating to chunked/blob storage.")
        }
    }

    private static func currentMajorVersion() -> Int {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1"
        let first = version.split(separator: ".").first ?? "1"
        return Int(first) ?? 1
    }

    func rotateKeyAndReencrypt(decryptedState: Data) throws {
        let profile = SecurityProfile.current
        let newId = UUID()
        _ = try loadOrCreateEncryptionKey(keyId: newId, accessibility: profile.keychainAccessibility)
        try storeCurrentKeyId(newId, accessibility: profile.keychainAccessibility)
        // Re-encrypt all fragmented files with the new key
        try rotateAllFragmentedFiles()
        // Also handle legacy file if it still exists (during migration window)
        let legacyURL = try getDocumentsFileURL()
        if fileManager.fileExists(atPath: legacyURL.path) {
            let encrypted = try encrypt(decryptedState)
            try writeMetadataFile(encrypted, to: legacyURL)
        }
    }

    /// Re-encrypts all per-document files, index, and conversations with the current key.
    func rotateAllFragmentedFiles() throws {
        // Index
        if let idxURL = try? indexURL(),
           let data = try? Data(contentsOf: idxURL), !data.isEmpty,
           let decrypted = try? decryptIfNeeded(data, context: aadIndex) {
            let reencrypted = try encrypt(decrypted, context: aadIndex)
            try writeMetadataFile(reencrypted, to: idxURL)
        }
        // Per-document files
        if let docsDir = try? documentsDirectoryURL(),
           let files = try? fileManager.contentsOfDirectory(at: docsDir, includingPropertiesForKeys: nil) {
            for fileURL in files where fileURL.pathExtension == "json" {
                guard let data = try? Data(contentsOf: fileURL), !data.isEmpty,
                      let decrypted = try? decryptIfNeeded(data, context: aadDocument) else { continue }
                let reencrypted = try encrypt(decrypted, context: aadDocument)
                try writeMetadataFile(reencrypted, to: fileURL)
            }
        }
        // Conversations
        if let convsURL = try? conversationsURL(),
           let data = try? Data(contentsOf: convsURL), !data.isEmpty,
           let decrypted = try? decryptIfNeeded(data, context: aadConversations) {
            let reencrypted = try encrypt(decrypted, context: aadConversations)
            try writeMetadataFile(reencrypted, to: convsURL)
        }
    }

    func resetLocalVault() throws {
        // Remove fragmented format files
        if let indexURL = try? indexURL() {
            try? fileManager.removeItem(at: indexURL)
        }
        if let docsDir = try? documentsDirectoryURL() {
            try? fileManager.removeItem(at: docsDir)
        }
        if let convsURL = try? conversationsURL() {
            try? fileManager.removeItem(at: convsURL)
        }
        // Remove legacy monolith
        let legacyURL = try getDocumentsFileURL()
        if fileManager.fileExists(atPath: legacyURL.path) {
            try fileManager.removeItem(at: legacyURL)
        }
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaultsKeys.lastKeyRotationMajorVersion)
        deleteAllVaultKeys()
    }

    func applyCurrentSecurityProfile() {
        do {
            // Apply to all fragmented files
            try rotateAllFragmentedFiles()
            // Also handle legacy file if still present
            let url = try getDocumentsFileURL()
            if fileManager.fileExists(atPath: url.path) {
                let payload = try Data(contentsOf: url)
                if !payload.isEmpty {
                    let decrypted = try decryptIfNeeded(payload)
                    try rotateKeyAndReencrypt(decryptedState: decrypted)
                }
            }
        } catch {
            AppLogger.persistence.error("Failed to apply security profile: \(error.localizedDescription)")
        }
    }

    private func deleteAllVaultKeys() {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return }
        guard let items = result as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String else { continue }
            if account == keychainCurrentKeyIdAccount || account.hasPrefix("\(userID)_\(keychainAccountPrefix)") || account == "documents_encryption_key" {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: keychainService,
                    kSecAttrAccount as String: account
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
    }

#if DEBUG
    func runSecuritySelfChecks() {
        do {
            let sample = Data("vault-self-check".utf8)
            let encrypted = try encrypt(sample)
            guard encrypted.starts(with: envelopeMagic) else {
                assertionFailure("Encrypted metadata envelope missing IDEN header")
                return
            }
            let roundTrip = try decryptIfNeeded(encrypted)
            assert(roundTrip == sample, "Vault round-trip encryption failed")

            let keyIdOffset = envelopeMagic.count + 1
            let keyIdData = encrypted.subdata(in: keyIdOffset..<(keyIdOffset + 16))
            if let keyId = UUID(data: keyIdData) {
                let combined = encrypted.dropFirst(keyIdOffset + 17)
                let box = try AES.GCM.SealedBox(combined: combined)
                let key = try loadEncryptionKey(keyId: keyId)
                do {
                    _ = try AES.GCM.open(box, using: key, authenticating: Data("wrong-aad".utf8))
                    assertionFailure("AAD mismatch should fail decryption")
                } catch { }
            }

            var tampered = encrypted
            if tampered.count > envelopeMagic.count {
                tampered[envelopeMagic.count] = 0x7F
                do {
                    _ = try decryptIfNeeded(tampered)
                    assertionFailure("Tampered envelope version should fail decryption")
                } catch { }
            }
        } catch {
            assertionFailure("Security self-check failed: \(error.localizedDescription)")
        }
    }
#endif
}

private extension UUID {
    var uuidData: Data {
        withUnsafeBytes(of: uuid) { Data($0) }
    }

    init?(data: Data) {
        guard data.count == 16 else { return nil }
        let uuid = data.withUnsafeBytes { raw -> uuid_t in
            let b = raw.bindMemory(to: UInt8.self)
            return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])
        }
        self.init(uuid: uuid)
    }
}
