import Foundation
import Darwin

public enum ProductEdition: String, Codable, Sendable {
    case native
    case extended
}

public struct IPCConfiguration: Equatable, Sendable {
    public let appGroupID: String
    public let edition: ProductEdition
    public let hostBundleIdentifier: String
    public let keychainAccessGroup: String
    public let urlScheme: String
    public let localSharedContainerPath: String?

    public init(
        appGroupID: String,
        edition: ProductEdition,
        hostBundleIdentifier: String,
        keychainAccessGroup: String,
        urlScheme: String,
        localSharedContainerPath: String? = nil
    ) {
        self.appGroupID = appGroupID
        self.edition = edition
        self.hostBundleIdentifier = hostBundleIdentifier
        self.keychainAccessGroup = keychainAccessGroup
        self.urlScheme = urlScheme
        self.localSharedContainerPath = localSharedContainerPath
    }

    public var conversionRequestNotificationName: String {
        "io.fileconverter.\(edition.rawValue).conversionRequestPending"
    }

    public var finderMenuSnapshotNotificationName: String {
        "io.fileconverter.\(edition.rawValue).finderMenuSnapshotChanged"
    }

    public func sharedContainerURL(fileManager: FileManager = .default) -> URL? {
        if let localSharedContainerPath, !localSharedContainerPath.isEmpty {
            let components = NSString(string: localSharedContainerPath).pathComponents
            guard localSharedContainerPath.hasPrefix("/"),
                  components.count > 1,
                  !components.contains(".."),
                  let userRecord = getpwuid(getuid()),
                  let homePath = userRecord.pointee.pw_dir else {
                return nil
            }
            return URL(fileURLWithPath: String(cString: homePath), isDirectory: true)
                .appendingPathComponent(String(localSharedContainerPath.dropFirst()), isDirectory: true)
        }
        return fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func current(bundle: Bundle = .main) throws -> IPCConfiguration {
        guard let appGroupID = bundle.object(forInfoDictionaryKey: "FileConverterAppGroup") as? String,
              !appGroupID.isEmpty,
              let editionValue = bundle.object(forInfoDictionaryKey: "FileConverterEdition") as? String,
              let edition = ProductEdition(rawValue: editionValue),
              let hostBundleIdentifier = bundle.object(forInfoDictionaryKey: "FileConverterHostBundleIdentifier") as? String,
              !hostBundleIdentifier.isEmpty,
              let keychainAccessGroup = bundle.object(forInfoDictionaryKey: "FileConverterKeychainAccessGroup") as? String,
              !keychainAccessGroup.isEmpty,
              !keychainAccessGroup.contains("$("),
              let urlScheme = bundle.object(forInfoDictionaryKey: "FileConverterURLScheme") as? String,
              !urlScheme.isEmpty else {
            throw IPCConfigurationError.missingBuildConfiguration
        }

        let localSharedContainerPath = bundle.object(
            forInfoDictionaryKey: "FileConverterLocalIPCPath"
        ) as? String

        return IPCConfiguration(
            appGroupID: appGroupID,
            edition: edition,
            hostBundleIdentifier: hostBundleIdentifier,
            keychainAccessGroup: keychainAccessGroup,
            urlScheme: urlScheme,
            localSharedContainerPath: localSharedContainerPath.flatMap { path in
                path.isEmpty || path.contains("$(") ? nil : path
            }
        )
    }
}

public enum IPCConfigurationError: LocalizedError, Sendable {
    case missingBuildConfiguration

    public var errorDescription: String? {
        "File Converter IPC is not configured for this product."
    }
}
