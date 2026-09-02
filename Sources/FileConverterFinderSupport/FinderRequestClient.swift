import FileConverterContracts
import Foundation
import Security

public enum FinderRequestClient {
    public static func isReady() -> Bool {
        do {
            let configuration = try IPCConfiguration.current()
            guard try loadKey(configuration: configuration) != nil,
                  configuration.sharedContainerURL() != nil else {
                return false
            }
            return true
        } catch {
            return false
        }
    }

    public static func send(_ request: ConversionRequest) throws {
        let configuration = try IPCConfiguration.current()
        try request.validate(expectedEdition: configuration.edition)
        guard let key = try loadKey(configuration: configuration) else {
            throw FinderSupportError.hostSetupRequired
        }

        let envelope = try ConversionRequestAuthenticator.authenticate(request, keyData: key)
        let data = try ConversionRequestAuthenticator.encoder().encode(envelope)
        guard data.count <= ConversionRequestLimits.production.maximumEnvelopeSize else {
            throw FinderSupportError.requestTooLarge
        }

        guard let container = configuration.sharedContainerURL() else {
            throw FinderSupportError.appGroupUnavailable(configuration.appGroupID)
        }
        let pending = container
            .appendingPathComponent("Requests", isDirectory: true)
            .appendingPathComponent("Pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)

        let timestamp = Int(request.requestedAt.timeIntervalSince1970 * 1_000)
        let requestFile = pending.appendingPathComponent("\(timestamp)-\(request.id.uuidString).json")
        try data.write(to: requestFile, options: [.atomic, .completeFileProtection])

        let name = CFNotificationName(configuration.conversionRequestNotificationName as CFString)
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            name,
            nil,
            nil,
            true
        )
    }

    private static func loadKey(configuration: IPCConfiguration) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "io.fileconverter.ipc.authentication",
            kSecAttrAccount as String: configuration.edition.rawValue,
            kSecAttrAccessGroup as String: configuration.keychainAccessGroup,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true
        ]

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FinderRequestClientError.keychainReadFailed(status)
        }
        return data
    }
}

enum FinderRequestClientError: Error, LocalizedError {
    case keychainReadFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .keychainReadFailed(let status):
            return "Could not read the Finder request key (\(status))."
        }
    }
}
