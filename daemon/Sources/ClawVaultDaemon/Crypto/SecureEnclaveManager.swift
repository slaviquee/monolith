import CryptoKit
import Foundation
import Security

/// Manages two Secure Enclave P-256 keys: signing (no user presence) and admin (Touch ID required).
actor SecureEnclaveManager {
    private var signingKey: SecureEnclave.P256.Signing.PrivateKey?
    private var adminKey: SecureEnclave.P256.Signing.PrivateKey?

    private let signingKeyTag = "com.clawvault.signing"
    private let adminKeyTag = "com.clawvault.admin"

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
        // Try to load existing key
        if let existing = try? loadKey(tag: signingKeyTag, requiresAuth: false) {
            return existing
        }

        // Create new signing key — no .userPresence (signs silently for routine ops)
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
            try storeKey(key, tag: signingKeyTag)
            return key
        } catch {
            throw KeyError.keyGenerationFailed(error.localizedDescription)
        }
    }

    private func loadOrCreateAdminKey() throws -> SecureEnclave.P256.Signing.PrivateKey {
        // Try to load existing key
        if let existing = try? loadKey(tag: adminKeyTag, requiresAuth: true) {
            return existing
        }

        // Create admin key — requires Touch ID for each use
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
            try storeKey(key, tag: adminKeyTag)
            return key
        } catch {
            throw KeyError.keyGenerationFailed(error.localizedDescription)
        }
    }

    private func loadKey(tag: String, requiresAuth: Bool) throws -> SecureEnclave.P256.Signing.PrivateKey {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw KeyError.keyNotFound
        }

        let secKey = item as! SecKey
        let keyData = try SecureEnclave.P256.Signing.PrivateKey.init(dataRepresentation: secKeyToData(secKey))
        return keyData
    }

    private func storeKey(_ key: SecureEnclave.P256.Signing.PrivateKey, tag: String) throws {
        // Store the key's data representation in the keychain
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag.data(using: .utf8)!,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: key.dataRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else {
            throw KeyError.keyGenerationFailed("Keychain store failed: \(status)")
        }
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

    private func secKeyToData(_ secKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCopyExternalRepresentation(secKey, &error) as Data? else {
            throw KeyError.keyNotFound
        }
        return data
    }
}
