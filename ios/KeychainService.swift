import Foundation
import Security
import CryptoKit
import CommonCrypto

enum KeychainService {
    private static let service = "com.insight.app"
    private static let account = "appPasscode"
    private static let migrationKey = "passcodeHashMigrationComplete"

    // PBKDF2 configuration
    private static let saltSize = 32
    private static let hashIterations = 100_000

    static func passcodeExists() -> Bool {
        var query = baseQuery()
        query[kSecReturnData as String] = false

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        return status == errSecSuccess
    }

    static func setPasscode(_ passcode: String) -> Bool {
        let salt = generateSalt()
        guard let hash = hashPasscode(passcode, salt: salt) else {
            return false
        }

        let combined = salt + hash
        _ = SecItemDelete(baseQuery() as CFDictionary)

        var query = baseQuery()
        query[kSecValueData as String] = combined
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

        let status = SecItemAdd(query as CFDictionary, nil)

        if status == errSecSuccess {
            // Mark migration as complete
            UserDefaults.standard.set(true, forKey: migrationKey)
        }

        return status == errSecSuccess
    }

    static func verifyPasscode(_ passcode: String) -> Bool {
        // Check if migration is needed
        if !UserDefaults.standard.bool(forKey: migrationKey) {
            // Try to migrate old plaintext passcode
            if let oldPasscode = getOldPlaintextPasscode(), oldPasscode == passcode {
                // Re-save with hashing
                _ = setPasscode(passcode)
                return true
            }
        }

        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return false
        }

        // Extract salt and hash
        guard data.count >= saltSize else {
            return false
        }

        let salt = data.prefix(saltSize)
        let storedHash = data.suffix(from: saltSize)

        // Compute hash with provided passcode
        guard let computedHash = hashPasscode(passcode, salt: Data(salt)) else {
            return false
        }

        return computedHash == storedHash
    }

    static func deletePasscode() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        UserDefaults.standard.removeObject(forKey: migrationKey)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    // MARK: - Private Helper Methods

    private static func generateSalt() -> Data {
        var salt = Data(count: saltSize)
        _ = salt.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, saltSize, bytes.baseAddress!)
        }
        return salt
    }

    private static func hashPasscode(_ passcode: String, salt: Data) -> Data? {
        guard let passcodeData = passcode.data(using: .utf8) else {
            return nil
        }

        // Use PBKDF2 with HMAC-SHA256
        let hash = PBKDF2.deriveKey(
            password: passcodeData,
            salt: salt,
            iterations: hashIterations,
            keyLength: 32
        )

        return hash
    }

    private static func getOldPlaintextPasscode() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return nil
        }

        // If data is exactly 6 bytes and all ASCII digits, it's likely plaintext
        if data.count == 6, let plaintext = String(data: data, encoding: .utf8),
           plaintext.allSatisfy({ $0.isNumber }) {
            return plaintext
        }

        return nil
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

// MARK: - PBKDF2 Implementation

private enum PBKDF2 {
    static func deriveKey(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        var derivedKeyData = Data(repeating: 0, count: keyLength)
        let derivedCount = derivedKeyData.count

        let derivationStatus = derivedKeyData.withUnsafeMutableBytes { derivedKeyBytes in
            salt.withUnsafeBytes { saltBytes in
                password.withUnsafeBytes { passwordBytes in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        passwordBytes.baseAddress?.assumingMemoryBound(to: Int8.self),
                        password.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedKeyBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        derivedCount
                    )
                }
            }
        }

        return derivationStatus == kCCSuccess ? derivedKeyData : Data()
    }
}
