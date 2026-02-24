import Foundation
import OSLog
import CryptoKit
import Security

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

class PersistenceService {
    static let shared = PersistenceService()

    private let fileManager = FileManager.default
    private let documentsFileName = AppConstants.FileNames.savedDocumentsJSON
    private let lastAccessedKey = AppConstants.UserDefaultsKeys.lastAccessedMap
    private let legacyUserDefaultsKey = "SavedDocuments_v2" // For migration
    private let legacyEncryptedMagic = Data("ENC1".utf8)
    private let envelopeMagic = Data("IDEN".utf8)
    private let envelopeVersion: UInt8 = 1
    private let algorithmAESGCM: UInt8 = 1
    private let keychainService = "com.identity.app.persistence"
    private let keychainAccountPrefix = "documents_encryption_key_"
    private let keychainCurrentKeyIdAccount = "documents_encryption_current_key_id"
    private let aadBaseContext = "\(AppConstants.FileNames.savedDocumentsJSON)|v1"

    private init() {}

    // MARK: - Document Persistence

    /// Saves documents and folders to disk (preserves existing conversations)
    func saveDocuments(_ documents: [Document], folders: [DocumentFolder], prefersGridLayout: Bool) throws {
        do {
            let existingConversations = (try? loadConversations()) ?? []
            let state = PersistedState(
                documents: documents,
                folders: folders,
                prefersGridLayout: prefersGridLayout,
                conversations: existingConversations
            )
            let encoded = try JSONEncoder().encode(state)
            let protectedData = try encrypt(encoded)
            let url = try getDocumentsFileURL()
            try writeMetadataFile(protectedData, to: url)
            AppLogger.persistence.info("Saved \(documents.count) documents + \(folders.count) folders")
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    // MARK: - Conversation Persistence

    /// Saves conversations to disk (preserves existing documents and folders)
    func saveConversations(_ conversations: [PersistedConversation]) throws {
        do {
            let url = try getDocumentsFileURL()
            var state: PersistedState
            if let data = try? Data(contentsOf: url), !data.isEmpty,
               let decrypted = try? decryptIfNeeded(data),
               let existing = try? JSONDecoder().decode(PersistedState.self, from: decrypted) {
                state = existing
            } else {
                state = PersistedState(documents: [], folders: [], prefersGridLayout: false)
            }
            state.conversations = conversations
            let encoded = try JSONEncoder().encode(state)
            let protectedData = try encrypt(encoded)
            try writeMetadataFile(protectedData, to: url)
            AppLogger.persistence.debug("Saved \(conversations.count) conversations")
        } catch let error as PersistenceError {
            throw error
        } catch {
            throw PersistenceError.saveFailedIO(error)
        }
    }

    /// Loads conversations from disk
    func loadConversations() throws -> [PersistedConversation] {
        let url = try getDocumentsFileURL()
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        let decrypted = try decryptIfNeeded(data)
        let state = try JSONDecoder().decode(PersistedState.self, from: decrypted)
        return state.conversations
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
            let decodedData: Data
            do {
                decodedData = try decryptIfNeeded(data)
                maybeRotateKeyForMajorVersionBump(decryptedState: decodedData)
            } catch {
                AppLogger.persistence.error("Failed to decrypt documents file: \(error.localizedDescription)")
                throw PersistenceError.vaultUnavailable(error)
            }

            // Try new PersistedState format
            do {
                let state = try JSONDecoder().decode(PersistedState.self, from: decodedData)
                warnIfMetadataFileLarge(currentBytes: data.count)
                AppLogger.persistence.info("Loaded \(state.documents.count) documents + \(state.folders.count) folders")
                return (state.documents, state.folders, state.prefersGridLayout)
            } catch {
                AppLogger.persistence.debug("Not PersistedState format, trying legacy: \(error.localizedDescription)")
            }

            // Try legacy documents-only format
            do {
                let documents = try JSONDecoder().decode([Document].self, from: decodedData)
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
                try fileManager.createDirectory(
                    at: identityDir,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: SecurityProfile.current.metadataFileProtection]
                )
            } catch {
                throw PersistenceError.saveFailedIO(error)
            }
        }
        try? (identityDir as NSURL).setResourceValue(true, forKey: .isExcludedFromBackupKey)

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
        "\(keychainAccountPrefix)\(keyId.uuidString.lowercased())"
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
        let encrypted = try encrypt(decryptedState)
        let url = try getDocumentsFileURL()
        try writeMetadataFile(encrypted, to: url)
    }

    func resetLocalVault() throws {
        let docsURL = try getDocumentsFileURL()
        if fileManager.fileExists(atPath: docsURL.path) {
            try fileManager.removeItem(at: docsURL)
        }
        UserDefaults.standard.removeObject(forKey: legacyUserDefaultsKey)
        UserDefaults.standard.removeObject(forKey: AppConstants.UserDefaultsKeys.lastKeyRotationMajorVersion)
        deleteAllVaultKeys()
    }

    func applyCurrentSecurityProfile() {
        do {
            let url = try getDocumentsFileURL()
            guard fileManager.fileExists(atPath: url.path) else { return }
            let payload = try Data(contentsOf: url)
            guard !payload.isEmpty else { return }
            let decrypted = try decryptIfNeeded(payload)
            try rotateKeyAndReencrypt(decryptedState: decrypted)
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
            if account == keychainCurrentKeyIdAccount || account.hasPrefix(keychainAccountPrefix) || account == "documents_encryption_key" {
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
