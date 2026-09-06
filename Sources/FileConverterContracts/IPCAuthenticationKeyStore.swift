import Foundation
import Security

/// Shared request-authentication key storage used by the host and Finder
/// extension. Keychain access is preferred; a tightly permissioned file in the
/// configured shared container keeps local development artifacts functional
/// when they do not carry a provisioned keychain access-group entitlement.
public enum IPCAuthenticationKeyStore {
    private static let service = "io.fileconverter.ipc.authentication"
    private static let keyLength = 32
    private static let creationLock = NSLock()

    public static func ensureKey(configuration: IPCConfiguration) throws -> Data {
        creationLock.lock()
        defer { creationLock.unlock() }

        // The shared-container copy is authoritative whenever it exists. The
        // Finder extension can always read that file when its local IPC
        // entitlement is present, whereas a locally signed host may be able
        // to use Keychain while the extension is not.
        if let existing = try loadFileKey(configuration: configuration) {
            return existing
        }

        let key: Data
        do {
            if let existing = try loadKeychainKey(configuration: configuration) {
                key = existing
            } else {
                let generated = try makeRandomKey()
                var query = keychainQuery(configuration: configuration)
                query[kSecValueData as String] = generated
                query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                query[kSecUseDataProtectionKeychain as String] = true

                let status = SecItemAdd(query as CFDictionary, nil)
                if status == errSecSuccess {
                    key = generated
                } else if status == errSecDuplicateItem,
                          let existing = try loadKeychainKey(configuration: configuration) {
                    key = existing
                } else {
                    throw IPCAuthenticationKeyStoreError.keychainReadFailed(status)
                }
            }
        } catch {
            // Local builds without a provisioned access group are expected to
            // reach the shared-container fallback below.
            key = try makeRandomKey()
        }

        // Always materialize the key in the shared request container. This
        // makes a host that can access Keychain interoperable with an
        // extension that can only use the local shared path.
        try writeFileKey(key, configuration: configuration)
        return key
    }

    public static func loadKey(configuration: IPCConfiguration) throws -> Data? {
        if let key = try loadFileKey(configuration: configuration) {
            return key
        }

        do {
            if let key = try loadKeychainKey(configuration: configuration) {
                return key
            }
        } catch {
            if configuration.sharedContainerURL() == nil {
                throw error
            }
        }
        return nil
    }

    private static func loadKeychainKey(configuration: IPCConfiguration) throws -> Data? {
        var query = keychainQuery(configuration: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseDataProtectionKeychain as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw IPCAuthenticationKeyStoreError.keychainReadFailed(status)
        }
        try validateKey(data)
        return data
    }

    private static func writeFileKey(_ key: Data, configuration: IPCConfiguration) throws {
        try validateKey(key)
        guard let keyURL = keyFileURL(configuration: configuration) else {
            throw IPCAuthenticationKeyStoreError.sharedContainerUnavailable(configuration.appGroupID)
        }

        let directory = keyURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try key.write(to: keyURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    }

    private static func loadFileKey(configuration: IPCConfiguration) throws -> Data? {
        guard let keyURL = keyFileURL(configuration: configuration) else {
            return nil
        }
        guard FileManager.default.fileExists(atPath: keyURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: keyURL, options: .mappedIfSafe)
        try validateKey(data)
        return data
    }

    private static func keyFileURL(configuration: IPCConfiguration) -> URL? {
        configuration.sharedContainerURL()?
            .appendingPathComponent("FileConverter", isDirectory: true)
            .appendingPathComponent("IPC", isDirectory: true)
            .appendingPathComponent("authentication-\(configuration.edition.rawValue).key")
    }

    private static func keychainQuery(configuration: IPCConfiguration) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: configuration.edition.rawValue,
            kSecAttrAccessGroup as String: configuration.keychainAccessGroup
        ]
    }

    private static func makeRandomKey() throws -> Data {
        var key = Data(count: keyLength)
        let status = key.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
        }
        guard status == errSecSuccess else {
            throw IPCAuthenticationKeyStoreError.keyGenerationFailed(status)
        }
        return key
    }

    private static func validateKey(_ key: Data) throws {
        guard key.count == keyLength else {
            throw IPCAuthenticationKeyStoreError.invalidStoredKey
        }
    }
}

public enum IPCAuthenticationKeyStoreError: LocalizedError, Sendable {
    case keyGenerationFailed(OSStatus)
    case keychainReadFailed(OSStatus)
    case sharedContainerUnavailable(String)
    case invalidStoredKey

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Could not generate the Finder request authentication key."
        case .keychainReadFailed:
            return "Could not read the Finder request authentication key."
        case .sharedContainerUnavailable:
            return "The shared Finder integration container is unavailable."
        case .invalidStoredKey:
            return "The stored Finder request authentication key is invalid."
        }
    }
}
