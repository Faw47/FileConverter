import FileConverterContracts
import Foundation
import Security

enum IPCKeyStore {
    private static let service = "io.fileconverter.ipc.authentication"

    static func ensureKey(configuration: IPCConfiguration) throws -> Data {
        if let existing = try loadKey(configuration: configuration) {
            return existing
        }

        var key = Data(count: 32)
        let randomStatus = key.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return errSecAllocate }
            return SecRandomCopyBytes(kSecRandomDefault, bytes.count, baseAddress)
        }
        guard randomStatus == errSecSuccess else {
            throw IPCKeyStoreError.keyGenerationFailed(randomStatus)
        }

        var query = baseQuery(configuration: configuration)
        query[kSecValueData as String] = key
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        query[kSecUseDataProtectionKeychain as String] = true

        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try loadKey(configuration: configuration) {
            return existing
        }
        guard status == errSecSuccess else {
            throw IPCKeyStoreError.writeFailed(status)
        }
        return key
    }

    static func loadKey(configuration: IPCConfiguration) throws -> Data? {
        var query = baseQuery(configuration: configuration)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseDataProtectionKeychain as String] = true

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw IPCKeyStoreError.readFailed(status)
        }
        return data
    }

    private static func baseQuery(configuration: IPCConfiguration) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: configuration.edition.rawValue,
            kSecAttrAccessGroup as String: configuration.keychainAccessGroup
        ]
    }
}

enum IPCKeyStoreError: LocalizedError {
    case keyGenerationFailed(OSStatus)
    case readFailed(OSStatus)
    case writeFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keyGenerationFailed(let status):
            return "Could not generate the Finder request key (\(status))."
        case .readFailed(let status):
            return "Could not read the Finder request key (\(status))."
        case .writeFailed(let status):
            return "Could not store the Finder request key (\(status))."
        }
    }
}
