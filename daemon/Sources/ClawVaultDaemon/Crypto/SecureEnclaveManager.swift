import CryptoKit
import Foundation
import Security

/// Manages two Secure Enclave P-256 keys: signing (no user presence) and admin (Touch ID required).
actor SecureEnclaveManager {
    private var signingKey: SecureEnclave.P256.Signing.PrivateKey?
    private var adminKey: SecureEnclave.P256.Signing.PrivateKey?
    private let keychainService = "com.clawvault.secureenclave.keys"
    private let signingAccount = "signing"
    private let adminAccount = "admin"
    private let legacySigningTag = "com.clawvault.signing"
    private let legacyAdminTag = "com.clawvault.admin"
    private let legacySigningKeyPath = DaemonConfig.configDir.appendingPathComponent("se-signing.key")
    private let legacyAdminKeyPath = DaemonConfig.configDir.appendingPathComponent("se-admin.key")

    enum KeyError: Error {
        case secureEnclaveNotAvailable
        case keyGenerationFailed(String)
        case keyNotFound
        case signingFailed(String)
        case accessControlCreationFailed
    }

    /// Generate or load the two Secure Enclave keys.
    func initialize() throws {
        guard SecureEnclave.isAvailable else {
            throw KeyError.secureEnclaveNotAvailable
        }

        signingKey = try loadOrCreateSigningKey()
        adminKey = try loadOrCreateAdminKey()
    }

    /// Get the signing key's public key as (x, y) coordinates (32 bytes each).
    func signingPublicKey() throws -> (x: Data, y: Data) {
        guard let key = signingKey else { throw KeyError.keyNotFound }
        return extractCoordinates(from: key.publicKey)
    }

    /// Get the admin key's public key as (x, y) coordinates.
    func adminPublicKey() throws -> (x: Data, y: Data) {
        guard let key = adminKey else { throw KeyError.keyNotFound }
        return extractCoordinates(from: key.publicKey)
    }

    /// Sign data with the signing key (no Touch ID).
    func sign(_ data: Data) throws -> Data {
        guard let key = signingKey else { throw KeyError.keyNotFound }
        do {
            let signature = try key.signature(for: data)
            return signature.rawRepresentation
        } catch {
            throw KeyError.signingFailed(error.localizedDescription)
        }
    }

    /// Get the raw SE signing key for config integrity signing.
    /// The returned key can sign config data without user interaction.
    func signingKeyForConfig() throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let key = signingKey else { throw KeyError.keyNotFound }
        return key
    }

    /// Sign data with the admin key (requires Touch ID).
    func adminSign(_ data: Data) throws -> Data {
        guard let key = adminKey else { throw KeyError.keyNotFound }
        do {
            let signature = try key.signature(for: data)
            return signature.rawRepresentation
        } catch {
            throw KeyError.signingFailed(error.localizedDescription)
        }
    }

    // MARK: - Private

    private func loadOrCreateSigningKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        // Preferred source: generic-password keychain item containing SE key reference bytes.
        if let existing = try? loadKeyFromKeychain(account: signingAccount) {
            return existing
        }

        // Migration path for previous dev/prototype storage formats.
        if let migrated = try? migrateLegacyTaggedKey(tag: legacySigningTag, account: signingAccount) {
            return migrated
        }
        if let migrated = try? migrateLegacyFileKey(path: legacySigningKeyPath, account: signingAccount) {
            return migrated
        }

        // Fail closed if this looks like an existing install. Regenerating the signing key would
        // break wallet identity and config signature integrity.
        if hasExistingInstallState() {
            throw KeyError.keyNotFound
        }

        // First run: create signing key without user presence.
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            nil
        ) else {
            throw KeyError.accessControlCreationFailed
        }

        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: accessControl
            )
            try storeKeyInKeychain(key, account: signingAccount)
            return key
        } catch {
            throw KeyError.keyGenerationFailed(error.localizedDescription)
        }
    }

    private func loadOrCreateAdminKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        if let existing = try? loadKeyFromKeychain(account: adminAccount) {
            return existing
        }

        if let migrated = try? migrateLegacyTaggedKey(tag: legacyAdminTag, account: adminAccount) {
            return migrated
        }
        if let migrated = try? migrateLegacyFileKey(path: legacyAdminKeyPath, account: adminAccount) {
            return migrated
        }

        // Admin key is local-policy only, safe to create if missing.
        guard let accessControl = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            [.privateKeyUsage, .userPresence],
            nil
        ) else {
            throw KeyError.accessControlCreationFailed
        }

        do {
            let key = try SecureEnclave.P256.Signing.PrivateKey(
                accessControl: accessControl
            )
            try storeKeyInKeychain(key, account: adminAccount)
            return key
        } catch {
            throw KeyError.keyGenerationFailed(error.localizedDescription)
        }
    }

    private func hasExistingInstallState() -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: DaemonConfig.configPath.path)
            || fm.fileExists(atPath: DaemonConfig.configSigPath.path)
    }

    private func loadKeyFromKeychain(account: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeyError.keyNotFound
        }

        guard let data = item as? Data else {
            throw KeyError.keyNotFound
        }

        do {
            return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        } catch {
            throw KeyError.keyNotFound
        }
    }

    private func storeKeyInKeychain(_ key: SecureEnclave.P256.Signing.PrivateKey, account: String) throws {
        let data = key.dataRepresentation

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            kSecValueData as String: data,
        ]

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus != errSecDuplicateItem {
            throw KeyError.keyGenerationFailed("Keychain add failed: \(addStatus)")
        }

        let updateQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: account,
        ]
        let updates: [String: Any] = [
            kSecValueData as String: data
        ]
        let updateStatus = SecItemUpdate(updateQuery as CFDictionary, updates as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeyError.keyGenerationFailed("Keychain update failed: \(updateStatus)")
        }
    }

    private func migrateLegacyFileKey(path: URL, account: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard FileManager.default.fileExists(atPath: path.path) else {
            throw KeyError.keyNotFound
        }

        let data = try Data(contentsOf: path)
        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        try storeKeyInKeychain(key, account: account)
        try? FileManager.default.removeItem(at: path)
        return key
    }

    private func migrateLegacyTaggedKey(tag: String, account: String) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let tagData = tag.data(using: .utf8) else {
            throw KeyError.keyNotFound
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tagData,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeyError.keyNotFound
        }

        let key = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: data)
        try storeKeyInKeychain(key, account: account)
        SecItemDelete(query as CFDictionary)
        return key
    }

    private func extractCoordinates(
        from publicKey: P256.Signing.PublicKey
    ) -> (x: Data, y: Data) {
        // CryptoKit P256 public key rawRepresentation is 64 bytes: x (32) || y (32)
        let raw = publicKey.rawRepresentation
        let x = raw.prefix(32)
        let y = raw.suffix(32)
        return (x: Data(x), y: Data(y))
    }
}
